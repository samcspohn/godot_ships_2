#[compute]
#version 450

// ocean_fft_butterfly.glsl
// One butterfly stage of the inverse FFT, applied to all 4 complex
// buffers at once. Ping-pongs between buffer set A and set B.
//
// Run order per cascade-batch:
//   for g in 0 .. 2*log2N-1:
//       direction = (g < log2N) ? 0 : 1
//       stage     = (g < log2N) ? g : g - log2N
//       pingpong  = g & 1          // 0: A->B, 1: B->A
// After 2*log2N stages the result is in set A (compose reads A).
//
// Dispatch: ( N/16 , N/16 , cascade_count ), local_size (16,16,1).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Set A
layout(set = 0, binding = 0, rg32f) uniform restrict image2DArray a0;
layout(set = 0, binding = 1, rg32f) uniform restrict image2DArray a1;
layout(set = 0, binding = 2, rg32f) uniform restrict image2DArray a2;
// Set B
layout(set = 0, binding = 3, rg32f) uniform restrict image2DArray b0;
layout(set = 0, binding = 4, rg32f) uniform restrict image2DArray b1;
layout(set = 0, binding = 5, rg32f) uniform restrict image2DArray b2;
// Butterfly table
layout(set = 0, binding = 6, rgba32f) uniform restrict readonly image2D butterfly_tex;
// Jacobian buffers
layout(set = 0, binding = 7, rg32f) uniform restrict image2DArray a3;
layout(set = 0, binding = 8, rg32f) uniform restrict image2DArray b3;

layout(push_constant, std430) uniform Push {
    int stage;
    int direction;
    int pingpong;
} pc;

vec2 cmul(vec2 a, vec2 b) {
    return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID);
    int layer = id.z;
    ivec2 xy = id.xy;

    int lane = (pc.direction == 0) ? xy.x : xy.y;
    vec4 data = imageLoad(butterfly_tex, ivec2(pc.stage, lane));
    vec2 w = data.xy;

    ivec2 top, bot;
    if (pc.direction == 0) {
        top = ivec2(int(data.z), xy.y);
        bot = ivec2(int(data.w), xy.y);
    } else {
        top = ivec2(xy.x, int(data.z));
        bot = ivec2(xy.x, int(data.w));
    }

    vec2 p, q, H;

    if (pc.pingpong == 0) {
        // read A, write B
        p = imageLoad(a0, ivec3(top, layer)).rg;
        q = imageLoad(a0, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(b0, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(a1, ivec3(top, layer)).rg;
        q = imageLoad(a1, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(b1, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(a2, ivec3(top, layer)).rg;
        q = imageLoad(a2, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(b2, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(a3, ivec3(top, layer)).rg;
        q = imageLoad(a3, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(b3, ivec3(xy, layer), vec4(H, 0.0, 0.0));
    } else {
        // read B, write A
        p = imageLoad(b0, ivec3(top, layer)).rg;
        q = imageLoad(b0, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(a0, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(b1, ivec3(top, layer)).rg;
        q = imageLoad(b1, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(a1, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(b2, ivec3(top, layer)).rg;
        q = imageLoad(b2, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(a2, ivec3(xy, layer), vec4(H, 0.0, 0.0));

        p = imageLoad(b3, ivec3(top, layer)).rg;
        q = imageLoad(b3, ivec3(bot, layer)).rg;
        H = p + cmul(w, q);
        imageStore(a3, ivec3(xy, layer), vec4(H, 0.0, 0.0));
    }
}
