#[compute]
#version 450

// All log2N butterfly stages of one row (dir 0, A -> B) or column (dir 1, B -> A)
// in shared memory. One workgroup per line per cascade; N must equal 256.

#define N 256

layout(local_size_x = N, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rg32f) uniform restrict image2DArray a0;
layout(set = 0, binding = 1, rg32f) uniform restrict image2DArray a1;
layout(set = 0, binding = 2, rg32f) uniform restrict image2DArray a2;
layout(set = 0, binding = 3, rg32f) uniform restrict image2DArray a3;
layout(set = 0, binding = 4, rg32f) uniform restrict image2DArray b0;
layout(set = 0, binding = 5, rg32f) uniform restrict image2DArray b1;
layout(set = 0, binding = 6, rg32f) uniform restrict image2DArray b2;
layout(set = 0, binding = 7, rg32f) uniform restrict image2DArray b3;
layout(set = 0, binding = 8, rgba32f) uniform restrict readonly image2D butterfly_tex;

layout(push_constant, std430) uniform Push {
    int direction;
    int log2n;
    int _p0;
    int _p1;
} pc;

shared vec4 s01[2][N];
shared vec4 s23[2][N];

vec2 cmul(vec2 a, vec2 b) {
    return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

void main() {
    int lane = int(gl_LocalInvocationID.x);
    int line = int(gl_WorkGroupID.x);
    int layer = int(gl_WorkGroupID.z);
    ivec3 p = pc.direction == 0 ? ivec3(lane, line, layer) : ivec3(line, lane, layer);

    if (pc.direction == 0) {
        s01[0][lane] = vec4(imageLoad(a0, p).rg, imageLoad(a1, p).rg);
        s23[0][lane] = vec4(imageLoad(a2, p).rg, imageLoad(a3, p).rg);
    } else {
        s01[0][lane] = vec4(imageLoad(b0, p).rg, imageLoad(b1, p).rg);
        s23[0][lane] = vec4(imageLoad(b2, p).rg, imageLoad(b3, p).rg);
    }
    barrier();

    int src = 0;
    for (int stage = 0; stage < pc.log2n; stage++) {
        vec4 bf = imageLoad(butterfly_tex, ivec2(stage, lane));
        vec2 w = bf.xy;
        int top = int(bf.z), bot = int(bf.w);
        vec4 t01 = s01[src][top], q01 = s01[src][bot];
        vec4 t23 = s23[src][top], q23 = s23[src][bot];
        s01[1 - src][lane] = vec4(t01.xy + cmul(w, q01.xy), t01.zw + cmul(w, q01.zw));
        s23[1 - src][lane] = vec4(t23.xy + cmul(w, q23.xy), t23.zw + cmul(w, q23.zw));
        src = 1 - src;
        barrier();
    }

    vec4 r01 = s01[src][lane], r23 = s23[src][lane];
    if (pc.direction == 0) {
        imageStore(b0, p, vec4(r01.xy, 0.0, 0.0));
        imageStore(b1, p, vec4(r01.zw, 0.0, 0.0));
        imageStore(b2, p, vec4(r23.xy, 0.0, 0.0));
        imageStore(b3, p, vec4(r23.zw, 0.0, 0.0));
    } else {
        imageStore(a0, p, vec4(r01.xy, 0.0, 0.0));
        imageStore(a1, p, vec4(r01.zw, 0.0, 0.0));
        imageStore(a2, p, vec4(r23.xy, 0.0, 0.0));
        imageStore(a3, p, vec4(r23.zw, 0.0, 0.0));
    }
}
