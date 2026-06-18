#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict readonly image2DArray src;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2DArray dst;

// std430: 32 bytes
struct Tile {
    vec2 origin;
    float _active;
    float _pad;
    int n_xn;
    int n_xp;
    int n_zn;
    int n_zp;
};

// std430: 3×vec2 + 6×float = 48 bytes (one float pad for 8-byte stride alignment)
struct Ship {
    vec2 world_xz;
    vec2 prev_world_xz;
    vec2 forward;
    float half_len;
    float radius;
    float strength;
    float prev_fwd_x; // previous frame forward.x (was: speed)
    float prev_fwd_y; // previous frame forward.y (was: draft)
    float _pad;
};

layout(set = 0, binding = 2, std430) restrict readonly buffer Tiles {
    Tile tiles[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer Ships {
    Ship ships[];
};

// std430: 32 bytes
struct PointImpulse {
    vec2 world_xz; // world position
    float radius; // gaussian sigma in world units
    float strength; // positive = upward splash, negative = depression
    float foam; // foam amount [0..1]
    float _pad0;
    float _pad1;
    float _pad2;
};

layout(set = 0, binding = 4, std430) restrict readonly buffer Impulses {
    PointImpulse impulses[];
};

layout(push_constant, std430) uniform Params {
    int res;
    float c2;
    float damp;
    float foam_decay;
    int ship_count;
    float tile_world;
    float foam_diffuse;
    int impulse_count;
} P;

float load_h(ivec2 c, int layer, Tile t) {
    if (c.x < 0) return (t.n_xn < 0) ? 0.0 : imageLoad(src, ivec3(P.res - 1, c.y, t.n_xn)).r;
    if (c.x >= P.res) return (t.n_xp < 0) ? 0.0 : imageLoad(src, ivec3(0, c.y, t.n_xp)).r;
    if (c.y < 0) return (t.n_zn < 0) ? 0.0 : imageLoad(src, ivec3(c.x, P.res - 1, t.n_zn)).r;
    if (c.y >= P.res) return (t.n_zp < 0) ? 0.0 : imageLoad(src, ivec3(c.x, 0, t.n_zp)).r;
    return imageLoad(src, ivec3(c, layer)).r;
}

float load_foam(ivec2 c, int layer, Tile t) {
    if (c.x < 0) return (t.n_xn < 0) ? 0.0 : imageLoad(src, ivec3(P.res - 1, c.y, t.n_xn)).b;
    if (c.x >= P.res) return (t.n_xp < 0) ? 0.0 : imageLoad(src, ivec3(0, c.y, t.n_xp)).b;
    if (c.y < 0) return (t.n_zn < 0) ? 0.0 : imageLoad(src, ivec3(c.x, P.res - 1, t.n_zn)).b;
    if (c.y >= P.res) return (t.n_zp < 0) ? 0.0 : imageLoad(src, ivec3(c.x, 0, t.n_zp)).b;
    return imageLoad(src, ivec3(c, layer)).b;
}

float hull_profile(float nx, float ny) {
    return max(0.0, 1.0 - nx * nx - ny * ny);
}

void main() {
    int layer = int(gl_GlobalInvocationID.z);
    ivec2 c = ivec2(gl_GlobalInvocationID.xy);
    if (c.x >= P.res || c.y >= P.res) return;

    Tile t = tiles[layer];
    if (t._active < 0.5) return;

    vec4 s = imageLoad(src, ivec3(c, layer));
    float h = s.r;
    float v = s.g;
    float foam = s.b;

    float lap = load_h(c + ivec2(-1, 0), layer, t) + load_h(c + ivec2(1, 0), layer, t)
            + load_h(c + ivec2(0, -1), layer, t) + load_h(c + ivec2(0, 1), layer, t)
            - 4.0 * h;
    v = (v + P.c2 * lap) * P.damp;
    h = h + v;

    vec2 uv = (vec2(c) + 0.5) / float(P.res);
    float edge = ((t.n_xn < 0) ? smoothstep(0.0, 0.05, uv.x) : 1.0)
            * ((t.n_xp < 0) ? smoothstep(0.0, 0.05, 1.0 - uv.x) : 1.0)
            * ((t.n_zn < 0) ? smoothstep(0.0, 0.05, uv.y) : 1.0)
            * ((t.n_zp < 0) ? smoothstep(0.0, 0.05, 1.0 - uv.y) : 1.0);
    h *= edge;
    v *= edge;

    float foam_lap = load_foam(c + ivec2(-1, 0), layer, t) + load_foam(c + ivec2(1, 0), layer, t)
            + load_foam(c + ivec2(0, -1), layer, t) + load_foam(c + ivec2(0, 1), layer, t)
            - 4.0 * foam;
    foam = clamp(foam + P.foam_diffuse * foam_lap, 0.0, 1.0);

    vec2 world_pos = t.origin + uv * P.tile_world;

    for (int i = 0; i < P.ship_count; i++) {
        Ship ship = ships[i];
        vec2 perp = vec2(-ship.forward.y, ship.forward.x);
        vec2 prev_forward = vec2(ship.prev_fwd_x, ship.prev_fwd_y);
        vec2 prev_perp = vec2(-prev_forward.y, prev_forward.x);

        vec2 d = world_pos - ship.world_xz;
        vec2 d_prev = world_pos - ship.prev_world_xz;

        float lx = dot(d, ship.forward) / ship.half_len;
        float ly = dot(d, perp) / ship.radius;
        float lx_prev = dot(d_prev, prev_forward) / ship.half_len;
        float ly_prev = dot(d_prev, prev_perp) / ship.radius;

        // Scale dc injection by forward vs lateral velocity fraction.
        // Lateral drift sweeps the full hull side, inflating |dc| across many cells.
        // Reduce lateral contribution to ~25% of forward contribution.
        vec2 vel = ship.world_xz - ship.prev_world_xz;
        float vel_len = length(vel);
        float dir_scale = 1.0;
        if (vel_len > 0.0001) {
            float fwd_frac = abs(dot(vel, ship.forward)) / vel_len;
            float lat_frac = abs(dot(vel, perp)) / vel_len;
            dir_scale = fwd_frac + lat_frac * 0.2;
        }

        // 5-tap box blur of the hull profile in hull-space coordinates,
        // spanning one sim cell in each axis. This converts the staircase
        // ellipse boundary (hard per-cell step) into a smooth gradient so
        // that dc = hn - hp changes continuously rather than firing as a
        // single-cell impulse each time the bow enters a new grid cell.
        float s_fwd = P.tile_world / float(P.res) / ship.half_len;
        float s_lat = P.tile_world / float(P.res) / ship.radius;
        float hn = (hull_profile(lx, ly) * 2.0
                + hull_profile(lx + s_fwd, ly) + hull_profile(lx - s_fwd, ly)
                + hull_profile(lx, ly + s_lat) + hull_profile(lx, ly - s_lat)) / 6.0;
        float hp = (hull_profile(lx_prev, ly_prev) * 2.0
                + hull_profile(lx_prev + s_fwd, ly_prev) + hull_profile(lx_prev - s_fwd, ly_prev)
                + hull_profile(lx_prev, ly_prev + s_lat) + hull_profile(lx_prev, ly_prev - s_lat)) / 6.0;

        // Only the bow (positive) component of dc is injected as a wave source.
        // Stern recovery is handled naturally: the wave equation's Laplacian at
        // cells just released from h=0 reads positive h from the surrounding bow
        // waves, producing positive v that fills the wake void from the sides.
        // Injecting negative v at the stern would actively drive h downward,
        // creating a deep trough that takes far longer to recover than the ship
        // wake region physically should.
        float crossing = 1.0 - smoothstep(0.0, 0.1, min(hn, hp));
        float dc = hn - hp;
        if (dc < 0.0) {
            dc *= 0.1; // weaker stern effect to avoid long-lasting troughs
        }
        v += abs(dc) * ship.strength * crossing * dir_scale;
        if (dc < 0.0) {
            dc *= 20.0;
        }
        foam = max(foam, abs(v) * 2.0 + abs(dc) * 80.0 * dir_scale);

        // // // Drive the water surface to the ship's displacement depth inside the
        // // // hull.  The target is -draft at the keel, tapering to 0 at the
        // // // waterline edge via the hull profile.
        // // // The stored velocity mirrors the displacement depth: positive (upward)
        // // // and proportional to the local draft, so the water is spring-loaded
        // // // when the stern clears and rushes in immediately rather than waiting
        // // // for the Laplacian to build up from the boundary.
        float inside = smoothstep(0.0, 0.9, hn);
        h = mix(h, 0.0, inside);
        v = mix(v, 0.0, inside);

        // float speed_t = clamp(ship.speed * 6.0, 0.0, 1.0);

        // // Bow cutwater: Gaussian at the bow tip.
        // vec2 bow_world = ship.world_xz + ship.forward * ship.half_len;
        // float bow_g = exp(-dot(world_pos - bow_world, world_pos - bow_world)
        //             / (ship.radius * ship.radius));

        // // Hull waterline: narrow foam strip along the hull boundary ellipse.
        // // Uses normalised-coordinate radius so the strip follows the actual
        // // waterline perimeter rather than filling the interior (which produced
        // // the aura / false bow extension).  side_bias fades the strip to zero
        // // at the bow and stern tips to avoid a closed foam ring.
        // float r = length(vec2(lx, ly));
        // float edge = exp(-(r - 1.0) * (r - 1.0) / 0.01);
        // float side_bias = smoothstep(0.0, 0.3, abs(ly));

        // // foam = max(foam, clamp(edge * side_bias * speed_t * 0.7, 0.0, 1.0));
        // foam = max(foam, hn > 0.0 ? 1.0 : 0.0);
    }

    for (int i = 0; i < P.impulse_count; i++) {
        PointImpulse imp = impulses[i];
        vec2 d = world_pos - imp.world_xz;
        float g = exp(-dot(d, d) / (imp.radius * imp.radius));
        float g2 = exp(-dot(d, d) / max(pow(imp.radius * 0.05, 2.0), 1.0)); // foam radius is always 1 sim unit, independent of impulse radius
        float impulse = imp.strength * g2;
        if (impulse > 0.001) {
            v = imp.strength;
        }
        foam = max(foam, imp.foam * g);
    }

    foam *= P.foam_decay;

    imageStore(dst, ivec3(c, layer), vec4(h, v, foam, 1.0));
}
