#[compute]
#version 450

// Separable 1-D tent blur for the FFT whitecap foam texture.
// Run twice per frame as a separable 2-D blur:
//   pass H (dir=0): reads _foam       -> writes _foam_temp   (horizontal)
//   pass V (dir=1): reads _foam_temp  -> writes _foam_scratch (vertical)
//
// Radius 6, kernel width 13.  A tent filter of width N has a zero in its
// frequency response at k = 2*pi/N.  For cascade-0 (patch 2501 m,
// 512 texels => 4.88 m/texel) the dominant wave period at wind 10 m/s
// is ~56 m = ~11.5 texels; the foam Jacobian pattern is at half that
// period (~5.75 texels).  Width-13 zeros k = 2*pi/13, providing near-
// complete cancellation of stripes in that range.
//
// A cross blur can only suppress stripes by ~50 % because its off-axis
// taps sample the same stripe value and add rather than cancel.  The
// separable approach zeros the stripe frequency exactly.
//
// Dispatch: ( N/16, N/16, cascade_count ), local_size (16,16,1).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict readonly image2DArray src;
layout(set = 0, binding = 1, r32f) uniform restrict writeonly image2DArray dst;

layout(push_constant, std430) uniform Push {
    int n;
    int dir; // 0 = horizontal  1 = vertical
    int _p0;
    int _p1;
} pc;

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID);
    if (id.x >= pc.n || id.y >= pc.n) return;

    // Tent weights: centre 7, d=1 -> 6, d=2 -> 5, ..., d=6 -> 1.  Sum = 49.
    float s = imageLoad(src, id).r * 7.0;
    float w = 7.0;
    for (int d = 1; d <= 6; d++) {
        float wt = float(7 - d);
        ivec3 pa, pb;
        if (pc.dir == 0) {
            pa = ivec3((id.x + d + pc.n) % pc.n, id.y, id.z);
            pb = ivec3((id.x - d + pc.n) % pc.n, id.y, id.z);
        } else {
            pa = ivec3(id.x, (id.y + d + pc.n) % pc.n, id.z);
            pb = ivec3(id.x, (id.y - d + pc.n) % pc.n, id.z);
        }
        s += (imageLoad(src, pa).r + imageLoad(src, pb).r) * wt;
        w += 2.0 * wt;
    }
    imageStore(dst, id, vec4(s / w, 0.0, 0.0, 0.0));
}
