#[compute]
#version 450

// ocean_compose.glsl
// Unpacks IFFT result (set A) into the two textures the spatial shader samples.
// Applies fftshift (-1)^(x+y), fills derivatives.ba with Jacobian diagonals,
// and accumulates whitecap foam into fft_foam.
//
//   buf0 -> (Dy, Dx)              displacement.rgb = (Dx, Dy, Dz)
//   buf1 -> (Dz, dDy/dx)         derivatives.rg   = (dDy/dx, dDy/dz)  slopes
//   buf2 -> (dDy/dz, 0)          derivatives.ba   = (dDx/dx, dDz/dz)  Jacobian
//   buf3 -> (dDx/dx, dDz/dz)
//
// Dispatch: ( N/16 , N/16 , cascade_count ), local_size (16,16,1).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rg32f) uniform restrict readonly image2DArray buf0;
layout(set = 0, binding = 1, rg32f) uniform restrict readonly image2DArray buf1;
layout(set = 0, binding = 2, rg32f) uniform restrict readonly image2DArray buf2;
layout(set = 0, binding = 3, rgba32f) uniform restrict writeonly image2DArray displacement;
layout(set = 0, binding = 4, rgba32f) uniform restrict writeonly image2DArray derivatives;
layout(set = 0, binding = 5, rg32f) uniform restrict readonly image2DArray buf3;
layout(set = 0, binding = 6, r32f) uniform restrict image2DArray fft_foam;

layout(push_constant, std430) uniform Push {
    float disp_scale;
    float slope_scale;
    float foam_bias;
    float foam_decay;
} pc;

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID);

    // fftshift: undo centered-k convention used in spectrum shaders
    float perm = (((id.x + id.y) & 1) == 0) ? 1.0 : -1.0;

    vec2 v0 = perm * imageLoad(buf0, id).rg; // (Dy, Dx)
    vec2 v1 = perm * imageLoad(buf1, id).rg; // (Dz, dDy/dx)
    vec2 v2 = perm * imageLoad(buf2, id).rg; // (dDy/dz, _)
    vec2 v3 = perm * imageLoad(buf3, id).rg; // (dDx/dx, dDz/dz)

    float Dy = v0.x, Dx = v0.y;
    float Dz = v1.x, sX = v1.y;
    float sZ = v2.x;
    float Jxx = v3.x, Jzz = v3.y;

    imageStore(displacement, id, vec4(Dx, Dy, Dz, 0.0) * pc.disp_scale);
    imageStore(derivatives, id, vec4(
            sX * pc.slope_scale,
            sZ * pc.slope_scale,
            Jxx,
            Jzz
        ));

    // Whitecap foam: generate where J = (1+Jxx)(1+Jzz) < foam_bias.
    // Accumulates over time and decays; in-place update (one texel per invocation).
    float J = (1.0 + Jxx) * (1.0 + Jzz);
    float foam_gen = clamp(pc.foam_bias - J, 0.0, 1.0);
    float old_foam = imageLoad(fft_foam, id).r;
    float new_foam = max(old_foam * pc.foam_decay, foam_gen);
    imageStore(fft_foam, id, vec4(new_foam, 0.0, 0.0, 0.0));
}
