#[compute]
#version 450

// One window per stamp: ships get the stern ribbon plus the spray sheet just
// outside the forward hull; torpedo trails are ribbons only (speed01 = 0).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

struct Stamp {
    vec2 pos;
    vec2 fwd;
    vec2 stern;
    vec2 prev_stern;
    float half_len;
    float half_beam;
    float strength;     // < 0 marks short-lived (splash-class) foam
    float speed01;
    float ribbon_hw;
    float _pad0;
    float _pad1;
    float _pad2;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Stamps { Stamp stamps[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer WakeIndex { int wake_index[]; };
layout(set = 0, binding = 2, rg32f) uniform restrict image2DArray wake;

layout(push_constant, std430) uniform Params {
    float wake_world;
    int wake_grid;
    int wake_origin;
    int res;
    float time;
    float wake_life;
    int base;           // first stamp of this dispatch
    int half_window;    // window half-size in texels
} P;

// Negative strength marks short-lived splash foam (SPLASH_LIFE_FRAC of wake_life).
const float SPLASH_LIFE_FRAC = 0.2;
const float SPRAY_SETBACK = 0.4;   // fraction of half-length

float wake_fade(vec2 v) {
    float life = P.wake_life * (v.y < 0.0 ? SPLASH_LIFE_FRAC : 1.0);
    return abs(v.y) * pow(clamp(1.0 - (P.time - v.x) / life, 0.0, 1.0), 1.5);
}

void main() {
    Stamp s = stamps[P.base + int(gl_GlobalInvocationID.z)];
    float texel = P.wake_world / float(P.res);
    vec2 snapped = (floor(s.pos / texel) + 0.5) * texel;
    vec2 world = snapped + (vec2(gl_GlobalInvocationID.xy) - float(P.half_window)) * texel;

    vec2 seg = s.stern - s.prev_stern;
    float k = clamp(dot(world - s.prev_stern, seg) / max(dot(seg, seg), 1e-6), 0.0, 1.0);
    float d = length(world - (s.prev_stern + seg * k));
    // Falloff never narrower than the 4 m texel, or thin trails miss texel centres and dash.
    float hw = max(s.ribbon_hw, 0.75 * texel);
    float foam = (1.0 - smoothstep(0.4 * hw, hw, d)) * abs(s.strength);

    // Spray ellipse sits aft of the hull so it emerges from the sides behind the stem.
    vec2 r = world - (s.pos - s.fwd * s.half_len * SPRAY_SETBACK);
    vec2 u = vec2(dot(r, s.fwd), dot(r, vec2(-s.fwd.y, s.fwd.x))) / vec2(s.half_len, s.half_beam);
    float rq = length(u);
    float spray = smoothstep(1.0, 1.04, rq) * (1.0 - smoothstep(1.06, mix(1.12, 1.6, s.speed01), rq));
    foam = max(foam, spray * smoothstep(-0.2, 0.4, u.x) * s.speed01 * s.speed01 * 0.3);
    if (foam < 0.02) return;

    ivec2 cell = ivec2(floor(world / P.wake_world)) + P.wake_origin;
    if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(P.wake_grid)))) return;
    int slot = wake_index[cell.y * P.wake_grid + cell.x];
    if (slot < 0) return;
    ivec3 tc = ivec3(ivec2(fract(world / P.wake_world) * float(P.res)), slot);
    if (foam > wake_fade(imageLoad(wake, tc).rg)) imageStore(wake, tc, vec4(P.time, s.strength < 0.0 ? -foam : foam, 0.0, 0.0));
}
