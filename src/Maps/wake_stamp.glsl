#[compute]
#version 450

// Per ship, a 128x128 texel window around the hull: turbulent stern ribbon plus
// the spray sheet just outside the forward hull.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

struct Stamp {
    vec2 pos;
    vec2 fwd;
    vec2 stern;
    vec2 prev_stern;
    float half_len;
    float half_beam;
    float strength;
    float speed01;
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
    float _pad0;
    float _pad1;
} P;

// Negative strength marks short-lived splash foam (SPLASH_LIFE_FRAC of wake_life).
const float SPLASH_LIFE_FRAC = 0.2;

float wake_fade(vec2 v) {
    float life = P.wake_life * (v.y < 0.0 ? SPLASH_LIFE_FRAC : 1.0);
    return abs(v.y) * pow(clamp(1.0 - (P.time - v.x) / life, 0.0, 1.0), 1.5);
}

void main() {
    Stamp s = stamps[gl_GlobalInvocationID.z];
    float texel = P.wake_world / float(P.res);
    vec2 snapped = (floor(s.pos / texel) + 0.5) * texel;
    vec2 world = snapped + (vec2(gl_GlobalInvocationID.xy) - 64.0) * texel;

    vec2 seg = s.stern - s.prev_stern;
    float k = clamp(dot(world - s.prev_stern, seg) / max(dot(seg, seg), 1e-6), 0.0, 1.0);
    float d = length(world - (s.prev_stern + seg * k));
    float hw = s.half_beam * 1.7;
    float foam = (1.0 - smoothstep(0.0, hw, d)) * s.strength;

    vec2 r = world - s.pos;
    vec2 u = vec2(dot(r, s.fwd), dot(r, vec2(-s.fwd.y, s.fwd.x))) / vec2(s.half_len, s.half_beam);
    float rq = length(u);
    float spray = smoothstep(1.0, 1.04, rq) * (1.0 - smoothstep(1.04, 1.2, rq));
    foam = max(foam, spray * smoothstep(0.0, 0.5, u.x) * s.speed01 * 0.45);
    if (foam < 0.02) return;

    ivec2 cell = ivec2(floor(world / P.wake_world)) + P.wake_origin;
    if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(P.wake_grid)))) return;
    int slot = wake_index[cell.y * P.wake_grid + cell.x];
    if (slot < 0) return;
    ivec3 tc = ivec3(ivec2(fract(world / P.wake_world) * float(P.res)), slot);
    if (foam > wake_fade(imageLoad(wake, tc).rg)) imageStore(wake, tc, vec4(P.time, foam, 0.0, 0.0));
}
