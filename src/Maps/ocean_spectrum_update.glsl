#[compute]
#version 450

// ocean_spectrum_update.glsl
// Per frame. Evolves h(k,t) and derives displacement/slope spectra,
// packing them into 3 complex rg32f buffers ready for IFFT.
// buf3 carries the diagonal Jacobian terms used for whitecap foam.
//
//   buf0 = h    + i*Dx        -> IFFT -> (Dy, Dx)
//   buf1 = Dz   + i*slopeX    -> IFFT -> (Dz, dDy/dx)
//   buf2 = slopeZ + i*0       -> IFFT -> (dDy/dz, 0)
//   buf3 = Jxx  + i*Jzz       -> IFFT -> (dDx/dx, dDz/dz)  Stokes convention

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std140) uniform OceanParams {
    vec4 patch_sizes;
    vec4 cutoff_low;
    vec4 cutoff_high;
    vec2 wind;
    float fetch;
    float gravity;
    float depth;
    float amplitude;
    float suppress;
    float _pad0;
    uint seed;
    int n;
    int cascade_count;
    int _pad1;
} P;

layout(set = 0, binding = 1, rgba32f) uniform restrict readonly image2DArray h0_tex;
layout(set = 0, binding = 2, rg32f) uniform restrict writeonly image2DArray buf0;
layout(set = 0, binding = 3, rg32f) uniform restrict writeonly image2DArray buf1;
layout(set = 0, binding = 4, rg32f) uniform restrict writeonly image2DArray buf2;
layout(set = 0, binding = 5, rg32f) uniform restrict writeonly image2DArray buf3;

layout(push_constant, std430) uniform Push {
    float time;
} pc;

const float TAU = 6.28318530717959;

vec2 cmul(vec2 a, vec2 b) {
    return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}
const vec2 I = vec2(0.0, 1.0);

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID);
    if (id.x >= P.n || id.y >= P.n || id.z >= P.cascade_count) return;

    int N = P.n;
    float L = P.patch_sizes[id.z];
    vec2 k = (TAU / L) * vec2(float(id.x - N / 2), float(id.y - N / 2));
    float kl = length(k);

    if (kl < 1e-6) {
        imageStore(buf0, id, vec4(0.0));
        imageStore(buf1, id, vec4(0.0));
        imageStore(buf2, id, vec4(0.0));
        imageStore(buf3, id, vec4(0.0));
        return;
    }

    vec4 h0d = imageLoad(h0_tex, id);
    vec2 h0 = h0d.rg;
    vec2 h0c = h0d.ba;

    float w = sqrt(P.gravity * kl * tanh(kl * P.depth));
    float cw = cos(w * pc.time);
    float sw = sin(w * pc.time);
    vec2 e = vec2(cw, sw);
    vec2 ec = vec2(cw, -sw);

    vec2 h = cmul(h0, e) + cmul(h0c, ec);
    vec2 khat = k / kl;

    // Displacement and slope spectra (Tessendorf, negated in vertex shader -> Stokes)
    vec2 Dx = cmul(vec2(0.0, -khat.x), h);
    vec2 Dz = cmul(vec2(0.0, -khat.y), h);
    vec2 sX = cmul(vec2(0.0, k.x), h);
    vec2 sZ = cmul(vec2(0.0, k.y), h);

    imageStore(buf0, id, vec4(h + cmul(I, Dx), 0.0, 0.0));
    imageStore(buf1, id, vec4(Dz + cmul(I, sX), 0.0, 0.0));
    imageStore(buf2, id, vec4(sZ, 0.0, 0.0));

    // Diagonal Jacobian (Stokes: sign negated vs Tessendorf so foam hits crests)
    // dDx/dx = -(khat.x^2 * kl) * h,   dDz/dz = -(khat.y^2 * kl) * h
    vec2 Jxx_s = -(khat.x * khat.x * kl) * h;
    vec2 Jzz_s = -(khat.y * khat.y * kl) * h;
    imageStore(buf3, id, vec4(Jxx_s + cmul(I, Jzz_s), 0.0, 0.0));
}
