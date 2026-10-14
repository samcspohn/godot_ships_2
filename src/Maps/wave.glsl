#[compute]
#version 450

// iWave: h' = A h - B h_prev - C K*(h + occ). K ≈ sqrt(-laplacian), least-squares
// fitted on a 13x13 stencil (|k| within ~10% for 0.3..2.5 rad/cell). Hull
// occupancy enters as surface pressure, so the water's rest state under a hull is
// -occ and a moving hull radiates Kelvin waves without injecting net volume.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rg16f) uniform restrict readonly image2DArray src;
layout(set = 0, binding = 1, rg16f) uniform restrict writeonly image2DArray dst;

struct Tile {
    vec2 origin;
    float used;
    float _pad;
    int nb[9];      // (dy + 1) * 3 + (dx + 1), centre = self
    int _pad1[3];
};

struct Ship {
    vec2 pos;
    vec2 prev_pos;
    vec2 fwd;
    vec2 prev_fwd;
    float half_len;
    float half_beam;
    float depth;    // draft * hull gain
    float _pad;
};

struct Impulse {
    vec2 pos;
    float sigma;
    float depth;
    float foam;
    float foam_sigma;
    float _pad1;
    float _pad2;
};

layout(set = 0, binding = 2, std430) restrict readonly buffer Tiles { Tile tiles[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Ships { Ship ships[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Impulses { Impulse impulses[]; };
// Per slot: x = ship bits, y/z = impulse bits 0-31/32-63 overlapping the tile.
layout(set = 0, binding = 5, std430) restrict readonly buffer Masks { uvec4 masks[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Active { int active_slots[]; };
layout(set = 0, binding = 7, std430) restrict buffer Energy { uint energy[]; };
layout(set = 0, binding = 8, r16f) uniform restrict writeonly image2DArray lod;
layout(set = 0, binding = 9, std430) restrict readonly buffer WakeIndex { int wake_index[]; };
layout(set = 0, binding = 10, rg32f) uniform restrict image2DArray wake;

layout(push_constant, std430) uniform Params {
    int res;
    float dx;
    float A;
    float B;
    float C;
    float sub_t0;
    float sub_t1;
    int apply_impulses;
    float tile_world;
    float time;
    float wake_life;
    float frame_dt;
    float sim_dt;
    float bow_gain;
    float gravity;
    float _pad4;
    float wake_world;
    int wake_grid;
    int wake_origin;
    float sponge_cells;
} P;

const int R = 6;
const int S = 16 + 2 * R;
const float KW[49] = float[49](
    1.9734197, -0.2028053, -0.0505527, 0.0099391, -0.0081186, 0.0058762, -0.0093465,
    -0.2028053, -0.1517307, -0.0054458, -0.0024949, -0.0031931, 0.0027954, -0.0057423,
    -0.0505527, -0.0054458, 0.0004486, -0.0002305, -0.0040312, 0.0049912, -0.0160450,
    0.0099391, -0.0024949, -0.0002305, -0.0070593, 0.0022692, -0.0004189, 0.0000000,
    -0.0081186, -0.0031931, -0.0040312, 0.0022692, 0.0068159, -0.0158649, 0.0000000,
    0.0058762, 0.0027954, 0.0049912, -0.0004189, -0.0158649, 0.0000000, 0.0000000,
    -0.0093465, -0.0057423, -0.0160450, 0.0000000, 0.0000000, 0.0000000, 0.0000000
);

shared float sh[S * S];   // h + occ
shared float so[S * S];   // occ
shared float red[256];
shared uint group_max;

float load_h(ivec2 c, Tile t) {
    ivec2 d = ivec2(c.x < 0 ? -1 : (c.x >= P.res ? 1 : 0), c.y < 0 ? -1 : (c.y >= P.res ? 1 : 0));
    int slot = t.nb[(d.y + 1) * 3 + d.x + 1];
    if (slot < 0) return 0.0;
    return imageLoad(src, ivec3(c - d * P.res, slot)).r;
}

vec2 lerp_dir(vec2 a, vec2 b, float t) {
    vec2 d = mix(a, b, t);
    float l = length(d);
    return (l > 1e-5) ? d / l : b;
}

const float BOW_ENTRY = 0.3;   // entry length as a fraction of half-length
const float BOW_FLARE = 1.5;   // larger = finer stem, faster flare near the shoulder

float hull_occ(vec2 world, uint bits, float tm) {
    float occ = 0.0;
    while (bits != 0u) {
        int si = findLSB(bits);
        bits &= bits - 1u;
        Ship s = ships[si];
        vec2 fwd = lerp_dir(s.prev_fwd, s.fwd, tm);
        vec2 r = world - mix(s.prev_pos, s.pos, tm);
        float ax = dot(r, fwd);
        float ay = dot(r, vec2(-fwd.y, fwd.x));
        float sig = max(s.half_beam * 0.45, 6.0);
        if (abs(ax) > s.half_len + 3.0 * sig || abs(ay) > s.half_beam + 3.0 * sig) continue;
        vec2 u = vec2(ax / s.half_len, ay / s.half_beam);
        if (abs(u.x) < 1.0) {
            // Waterline planform: hollow (concave) entry over the forward 40%, needle
            // fine at the stem and flaring exponentially into the midbody, Iowa/Yamato
            // style; run narrows to a 60% transom. Divergent waves come off the entry
            // flanks, so the beam profile follows the local half-width.
            float de = clamp((1.0 - u.x) / BOW_ENTRY, 0.0, 1.0);
            float wb = u.x > 1.0 - BOW_ENTRY ? (exp(BOW_FLARE * de) - 1.0) / (exp(BOW_FLARE) - 1.0)
                    : (u.x < -0.5 ? 1.0 - 0.8 * (-u.x - 0.5) : 1.0);
            float yy = u.y / max(wb, 0.05);
            if (abs(yy) < 1.0) {
                float fy = 1.0 - yy * yy;
                occ += s.depth * fy * fy * smoothstep(-1.0, -0.85, u.x);
            }
        }
        // Stagnation peak just ahead of the stem: a narrow raise that does not
        // overlap (and cancel) the entry depression behind it.
        float speed = length(s.pos - s.prev_pos) / P.frame_dt;
        float hump = min(speed * speed / (2.0 * P.gravity), s.depth * 2.0) * P.bow_gain;
        vec2 b = vec2(ax - s.half_len, ay) / sig;
        occ -= hump * exp(-dot(b, b));
    }
    return occ;
}

// Negative strength marks short-lived splash foam (SPLASH_LIFE_FRAC of wake_life).
const float SPLASH_LIFE_FRAC = 0.2;

float wake_fade(vec2 v) {
    float life = P.wake_life * (v.y < 0.0 ? SPLASH_LIFE_FRAC : 1.0);
    return abs(v.y) * pow(clamp(1.0 - (P.time - v.x) / life, 0.0, 1.0), 1.5);
}

void stamp_wake(vec2 world, float foam) {
    ivec2 cell = ivec2(floor(world / P.wake_world)) + P.wake_origin;
    if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(P.wake_grid)))) return;
    int slot = wake_index[cell.y * P.wake_grid + cell.x];
    if (slot < 0) return;
    ivec3 tc = ivec3(ivec2(fract(world / P.wake_world) * float(P.res)), slot);
    if (foam > wake_fade(imageLoad(wake, tc).rg)) imageStore(wake, tc, vec4(P.time, -foam, 0.0, 0.0));
}

void main() {
    int layer = active_slots[gl_WorkGroupID.z];
    Tile t = tiles[layer];
    ivec2 base = ivec2(gl_WorkGroupID.xy) * 16;
    ivec2 lid = ivec2(gl_LocalInvocationID.xy);
    uint li = gl_LocalInvocationIndex;

    if (li == 0u) group_max = 0u;
    uvec4 mask = masks[layer];
    float tm = 0.5 * (P.sub_t0 + P.sub_t1);
    for (uint i = li; i < uint(S * S); i += 256u) {
        ivec2 o = base + ivec2(int(i) % S, int(i) / S) - R;
        float occ = mask.x != 0u ? hull_occ(t.origin + (vec2(o) + 0.5) * P.dx, mask.x, tm) : 0.0;
        so[i] = occ;
        sh[i] = load_h(o, t) + occ;
    }
    barrier();

    ivec2 c = base + lid;
    int ci = (lid.y + R) * S + lid.x + R;
    float occ_c = so[ci];
    float h = sh[ci] - occ_c;
    float hp = imageLoad(src, ivec3(c, layer)).g;

    float conv = 0.0;
    for (int j = -R; j <= R; j++) {
        for (int i = -R; i <= R; i++) {
            float w = KW[abs(j) * 7 + abs(i)];
            if (w != 0.0) conv += w * sh[ci + j * S + i];
        }
    }
    float hn = P.A * h - P.B * hp - P.C * conv;

    vec2 world = t.origin + (vec2(c) + 0.5) * P.dx;
    float foam = 0.0;
    bool inside_hull = occ_c > 0.0;
    float shift = 0.0;

    if (P.apply_impulses != 0) {
        uvec2 imp_bits = mask.yz;
        while (imp_bits != uvec2(0u)) {
            int ii = imp_bits.x != 0u ? findLSB(imp_bits.x) : 32 + findLSB(imp_bits.y);
            if (imp_bits.x != 0u) imp_bits.x &= imp_bits.x - 1u; else imp_bits.y &= imp_bits.y - 1u;
            Impulse imp = impulses[ii];
            vec2 d = world - imp.pos;
            float rho2 = dot(d, d) / (imp.sigma * imp.sigma);
            float g = exp(-rho2);
            // Crater with raised rim: zero net volume, so no lingering hole.
            shift -= imp.depth * (1.0 - rho2) * g;
            foam = max(foam, imp.foam * exp(-dot(d, d) / (imp.foam_sigma * imp.foam_sigma)));
        }
    }

    // Impulses displace the surface without imparting velocity: shifting only the
    // new height would read as a kick that keeps accelerating every later step.
    hn += shift;
    h += shift;

    // Absorb at edges with no neighbour tile instead of reflecting.
    float edge_d = 1e6;
    if (t.nb[3] < 0) edge_d = min(edge_d, float(c.x));
    if (t.nb[5] < 0) edge_d = min(edge_d, float(P.res - 1 - c.x));
    if (t.nb[1] < 0) edge_d = min(edge_d, float(c.y));
    if (t.nb[7] < 0) edge_d = min(edge_d, float(P.res - 1 - c.y));
    float sponge = mix(0.9, 1.0, smoothstep(0.0, P.sponge_cells, edge_d));
    hn *= sponge;
    h *= sponge;

    imageStore(dst, ivec3(c, layer), vec4(hn, h, 0.0, 0.0));
    if (foam > 0.02 && !inside_hull) stamp_wake(world, foam);

    red[li] = hn;
    atomicMax(group_max, floatBitsToUint(abs(hn)));
    barrier();
    if (lid.x % 4 == 0 && lid.y % 4 == 0) {
        float sum = 0.0;
        for (int j = 0; j < 4; j++)
            for (int i = 0; i < 4; i++)
                sum += red[(lid.y + j) * 16 + lid.x + i];
        imageStore(lod, ivec3(c / 4, layer), vec4(sum / 16.0));
    }
    if (li == 0u) atomicMax(energy[layer], group_max);
}
