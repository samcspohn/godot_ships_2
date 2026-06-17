#[compute]
#version 450

// =====================================================================
// ocean_butterfly_precompute.glsl
// Builds the butterfly (twiddle + index) texture used by every IFFT stage.
// Run ONCE (depends only on N). Texture is (log2N wide) x (N tall).
//
// butterfly_tex (rgba32f image2D):
//   .xy = twiddle factor exp(+i 2π k/N)   (+sin -> inverse transform)
//   .z  = top input index
//   .w  = bottom input index
// Stage 0 stores bit-reversed indices (decimation-in-time).
// Dispatch: ( log2N , N/16 , 1 ),  local_size (1,16,1).
// =====================================================================

layout(local_size_x = 1, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict writeonly image2D butterfly_tex;

layout(push_constant, std430) uniform Push {
	int n;       // grid size N
	int log2n;
} pc;

const float TAU = 6.28318530717959;

int bitrev(int x, int bits) {
	int r = 0;
	for (int i = 0; i < bits; ++i) { r = (r << 1) | (x & 1); x >>= 1; }
	return r;
}

void main() {
	int stage = int(gl_GlobalInvocationID.x);   // 0 .. log2N-1
	int idx   = int(gl_GlobalInvocationID.y);   // 0 .. N-1
	if (stage >= pc.log2n || idx >= pc.n) return;

	float N = float(pc.n);
	float kk = mod(float(idx) * (N / exp2(float(stage + 1))), N);
	vec2 twiddle = vec2(cos(TAU * kk / N), sin(TAU * kk / N));   // +sin = inverse

	int span = 1 << stage;
	int top, bot;
	if ((idx & ((1 << (stage + 1)) - 1)) < span) { top = idx;        bot = idx + span; }
	else                                         { top = idx - span; bot = idx;        }

	if (stage == 0) { top = bitrev(top, pc.log2n); bot = bitrev(bot, pc.log2n); }

	imageStore(butterfly_tex, ivec2(stage, idx),
	           vec4(twiddle, float(top), float(bot)));
}
