#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict readonly image2DArray src;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2DArray dst;

struct Tile {
    vec2 origin;
    float _active;
    float _pad;
    vec2 stamp_uv;
    float strength;
    float radius;
};
layout(set = 0, binding = 2, std430) restrict readonly buffer Tiles {
    Tile tiles[];
};

layout(push_constant, std430) uniform Params {
    int res;
    float c2;
    float damp;
    float foam_decay;
} P;

float load_h(ivec2 c, int layer) {
    c = clamp(c, ivec2(0), ivec2(P.res - 1));
    return imageLoad(src, ivec3(c, layer)).r;
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

    float lap = load_h(c + ivec2(-1, 0), layer) + load_h(c + ivec2(1, 0), layer)
            + load_h(c + ivec2(0, -1), layer) + load_h(c + ivec2(0, 1), layer) - 4.0 * h;
    v = (v + P.c2 * lap) * P.damp;
    h = h + v;

    vec2 uv = (vec2(c) + 0.5) / float(P.res);
    float edge = smoothstep(0.0, 0.05, uv.x) * smoothstep(0.0, 0.05, 1.0 - uv.x)
            * smoothstep(0.0, 0.05, uv.y) * smoothstep(0.0, 0.05, 1.0 - uv.y);
    h *= edge;
    v *= edge;

    if (t.stamp_uv.x >= 0.0) {
        float d = distance(uv, t.stamp_uv);
        float g = exp(-(d * d) / max(t.radius * t.radius, 1e-5));
        v += g * t.strength;
        foam = max(foam, g);
    }
    foam *= P.foam_decay;

    imageStore(dst, ivec3(c, layer), vec4(h, v, foam, 1.0));
}
