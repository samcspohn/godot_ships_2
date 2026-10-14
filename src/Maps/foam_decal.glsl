#[vertex]
#version 450

struct Decal {
    vec2 pos;
    float r0;
    float r1;
    float birth;
    float life;
    float grow;
    float rot;
    float strength;
    float bubbles;
    float fade_pow;
    float seed;
    vec4 hull;      // occluding centerline (stern xz, bow xz); zero = none
    float tile_a;   // pattern tile = churn_scale * tile_a + tile_b * current radius
    float tile_b;
    float blotch;   // 0 = none, 1 = per-decal blotches, 2 = world-aligned (overlapping trail decals agree), 3 = blotches alone, no fine pattern
    float whorl;    // 1 = swirled pattern (foam_tex.g), 0 = inverted churn (foam_tex.b)
    float opacity;  // alpha gain in the ocean shader, 1..3
    float fade_in;  // seconds
    float speed;    // m/s; > 0 overrides grow with a constant-speed front
    float _pad3;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Decals { Decal decals[]; };

layout(push_constant, std430) uniform Params {
    vec2 origin;    // world xz of the cascade's min corner
    float extent;
    float time;
    vec2 drift;     // m/s
    float churn_scale;
    float churn_edge;
} P;

layout(location = 0) out vec2 v_local;      // world offset from the decal centre
layout(location = 1) flat out int v_id;
layout(location = 2) flat out float v_radius;
layout(location = 3) out vec2 v_world;

void main() {
    Decal d = decals[gl_InstanceIndex];
    float age = P.time - d.birth;
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1) * 2.0 - 1.0;
    // grow > 0: easing time constant; grow < 0: accelerating growth reaching r1 at -grow seconds.
    float s = clamp(age / max(-d.grow, 1e-3), 0.0, 1.0);
    float k = d.grow < 0.0 ? (exp(3.0 * s) - 1.0) / (exp(3.0) - 1.0) : 1.0 - exp(-max(age, 0.0) / max(d.grow, 1e-3));
    float R = d.speed > 0.0 ? min(d.r0 + d.speed * max(age, 0.0), d.r1) : d.r0 + (d.r1 - d.r0) * k;
    vec2 c = d.pos + P.drift * age;
    vec2 ndc = ((c + corner * R) - P.origin) / P.extent * 2.0 - 1.0;
    bool dead = age < 0.0 || age >= d.life || d.life <= 0.0
            || any(greaterThan(abs((c - P.origin) / P.extent * 2.0 - 1.0), vec2(1.0 + 2.0 * R / P.extent)));
    gl_Position = dead ? vec4(2.0, 2.0, 2.0, 1.0) : vec4(ndc, 0.0, 1.0);
    v_local = corner * R;
    v_id = gl_InstanceIndex;
    v_radius = R;
    v_world = c + corner * R;
}

#[fragment]
#version 450

struct Decal {
    vec2 pos;
    float r0;
    float r1;
    float birth;
    float life;
    float grow;
    float rot;
    float strength;
    float bubbles;
    float fade_pow;
    float seed;
    vec4 hull;
    float tile_a;
    float tile_b;
    float blotch;   // 0 = none, 1 = per-decal blotches, 2 = world-aligned (overlapping trail decals agree), 3 = blotches alone, no fine pattern
    float whorl;    // 1 = swirled pattern (foam_tex.g), 0 = inverted churn (foam_tex.b)
    float opacity;  // alpha gain in the ocean shader, 1..3
    float fade_in;  // seconds
    float speed;
    float _pad3;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Decals { Decal decals[]; };
layout(set = 0, binding = 1) uniform sampler2D foam_tex;

layout(push_constant, std430) uniform Params {
    vec2 origin;
    float extent;
    float time;
    vec2 drift;
    float churn_scale;
    float churn_edge;
} P;

layout(location = 0) in vec2 v_local;
layout(location = 1) flat in int v_id;
layout(location = 2) flat in float v_radius;
layout(location = 3) in vec2 v_world;

layout(location = 0) out vec4 frag;

const float BLOTCH_TILE = 108.0;   // metres; ~18 m blotches
const float BLAST_BLOTCH_SCALE = 1.5;   // base layers only

float hull_shadow(vec2 o, vec2 p, vec4 hull) {
    vec2 a = hull.xy;
    vec2 ab = hull.zw - a;
    vec2 op = p - o;
    float denom = op.x * ab.y - op.y * ab.x;
    if (dot(ab, ab) < 1.0 || abs(denom) < 1e-4) return 0.0;
    vec2 ao = a - o;
    float t = (ao.x * ab.y - ao.y * ab.x) / denom;
    float s = (ao.x * op.y - ao.y * op.x) / denom;
    if (t <= 0.0 || t >= 1.0) return 0.0;
    return smoothstep(-0.05, 0.05, s) * (1.0 - smoothstep(0.95, 1.05, s));
}

void main() {
    Decal d = decals[v_id];
    float q2 = dot(v_local, v_local) / (v_radius * v_radius);
    if (q2 >= 1.0) discard;
    float t = clamp((P.time - d.birth) / d.life, 0.0, 1.0);
    float profile = (1.0 - q2) * (1.0 - q2);
    float vis = 1.0 - hull_shadow(vec2(0.0), v_local, vec4(d.hull.xy - d.pos, d.hull.zw - d.pos) * step(1e-3, dot(d.hull, d.hull)));
    float c = clamp(d.strength * profile * pow(1.0 - t, d.fade_pow) * vis, 0.0, 1.0);
    if (d.fade_in > 0.0) c *= smoothstep(0.0, d.fade_in, P.time - d.birth);
    float cs = cos(d.rot), sn = sin(d.rot);
    if (d.blotch > 0.0) {
        bool world = d.blotch > 1.5 && d.blotch < 2.5;
        vec2 bp = world ? v_world : mat2(vec2(cs, sn), vec2(-sn, cs)) * v_local + d.seed * 997.0;
        // Two unrelated scales/angles so the tile never repeats visibly; 1.39 restores the variance.
        float bt = BLOTCH_TILE * (d.blotch > 2.5 ? BLAST_BLOTCH_SCALE : 1.0);
        float n = (0.6 * texture(foam_tex, bp / bt).a
                + 0.4 * texture(foam_tex, mat2(vec2(0.47, 0.88), vec2(-0.88, 0.47)) * bp / (bt * 2.37) + 0.31).a
                - 0.5) * 2.0 * 1.39;
        if (d.blotch > 2.5) {
            // Smaller rotated copy on top, for detail inside the blotches.
            vec2 bs = mat2(vec2(-0.6, 0.8), vec2(-0.8, -0.6)) * bp / (BLOTCH_TILE * 0.525) + 0.57;
            n = n * 0.8 + (texture(foam_tex, bs).a - 0.5) * 2.0 * 0.6;
        }
        c = d.blotch > 2.5 ? sqrt(c) * smoothstep(-0.45, 0.55, n) : sqrt(c) * smoothstep(-0.35, 0.45, n);
    }
    float bub = d.bubbles * sqrt(profile * (1.0 - t)) * vis;

    // Own rotation and offset per decal so overlapping events layer distinct clumps;
    // a radius-tied tile makes the clumps spread with the decal.
    float tile = P.churn_scale * d.tile_a + d.tile_b * v_radius;
    vec2 uv = mat2(vec2(cs, sn), vec2(-sn, cs)) * v_local / tile + vec2(d.seed, fract(d.seed * 7.31));
    // Signed margin above the reveal threshold; the ocean shader cuts the edge per pixel.
    // Inverted churn: creases reveal first, so foam reads as a web.
    vec4 ft = texture(foam_tex, uv);
    float order = d.whorl > 0.5 ? ft.g : 1.0 - ft.b;
    float margin = c > 0.0 ? order - (1.0 + P.churn_edge - c * (1.0 + 2.0 * P.churn_edge)) : -1.0;
    // Blotch-only: no threshold, so the ocean shader's opacity tracks c and fades continuously.
    if (d.blotch > 2.5) margin = c > 0.0 ? P.churn_edge * (2.0 * c - 1.0) : -1.0;
    frag = vec4(margin * 0.5 + 0.5, bub, c > 0.0 ? (d.opacity - 1.0) * 0.5 : 0.0, 0.0);
}
