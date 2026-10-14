#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict readonly image2D disp_src;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2D disp_dst;
layout(set = 0, binding = 2, rgba16f) uniform restrict readonly image2D deriv_src;
layout(set = 0, binding = 3, rgba16f) uniform restrict writeonly image2D deriv_dst;

layout(push_constant, std430) uniform Push {
    int size;
    int copy;
    int _p0;
    int _p1;
} pc;

void main() {
    ivec2 d = ivec2(gl_GlobalInvocationID.xy);
    if (d.x >= pc.size || d.y >= pc.size) return;
    if (pc.copy != 0) {
        imageStore(disp_dst, d, imageLoad(disp_src, d));
        imageStore(deriv_dst, d, imageLoad(deriv_src, d));
        return;
    }
    ivec2 s = d * 2;
    ivec2 x = ivec2(1, 0), y = ivec2(0, 1);
    imageStore(disp_dst, d, 0.25 * (imageLoad(disp_src, s) + imageLoad(disp_src, s + x)
            + imageLoad(disp_src, s + y) + imageLoad(disp_src, s + x + y)));
    imageStore(deriv_dst, d, 0.25 * (imageLoad(deriv_src, s) + imageLoad(deriv_src, s + x)
            + imageLoad(deriv_src, s + y) + imageLoad(deriv_src, s + x + y)));
}
