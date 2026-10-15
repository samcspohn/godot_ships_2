#[compute]
#version 450

// =====================================================================
// ocean_spectrum_initial.glsl
// Computes h0(k) and conj(h0(-k)) once per sea-state change.
// One invocation per (texel, cascade). Cascade = gl_GlobalInvocationID.z.
//
// Output h0_tex (rgba32f image2DArray):
//   .rg = h0(k)              (complex)
//   .ba = conj(h0(-k))       (complex)  -> consumed by spectrum_update
// =====================================================================

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
    float wind_spread;
    vec2 swell;
    float swell_fetch;
    float swell_amount;
    float swell_spread;
    float wind_norm;
    float swell_norm;
    float _pad0;
    uint seed;
    int n;
    int cascade_count;
    int _pad1;
} P;

layout(set = 0, binding = 1, rgba32f) uniform restrict writeonly image2DArray h0_tex;

const float PI  = 3.14159265358979;
const float TAU = 6.28318530717959;

// --- PCG-style hash + Box-Muller Gaussian, deterministic per texel/cascade ---
uint hash_u(uint x) {
	x ^= x >> 16; x *= 0x7feb352dU;
	x ^= x >> 15; x *= 0x846ca68bU;
	x ^= x >> 16; return x;
}
uint seed3(ivec3 c, uint s) {
	return hash_u(uint(c.x) * 1973u + uint(c.y) * 9277u + uint(c.z) * 26699u + s);
}
float u01(uint h) { return float(h & 0x00FFFFFFu) / float(0x01000000); }
vec2 gaussian(ivec3 c, uint s) {
	uint h1 = seed3(c, s);
	uint h2 = seed3(c, s ^ 0x68bc21ebU);
	float u1 = max(u01(h1), 1e-7);
	float u2 = u01(h2);
	float mag = sqrt(-2.0 * log(u1));
	return vec2(mag * cos(TAU * u2), mag * sin(TAU * u2));
}

// Omnidirectional JONSWAP S(k); mirrored by OceanFFT._jonswap_k for the slope-variance table.
float jonswap_k(float kl, float U, float F, float gamma) {
	if (U < 1e-3) return 0.0;
	float g    = P.gravity;
	float om   = sqrt(g * kl);
	float om_p = 22.0 * pow((g * g) / (U * F), 1.0 / 3.0);
	float alpha = 0.076 * pow(g * F / (U * U), -0.22);
	float sigma = (om <= om_p) ? 0.07 : 0.09;
	float r     = exp(-((om - om_p) * (om - om_p)) / (2.0 * sigma * sigma * om_p * om_p));
	float S_om  = alpha * g * g / pow(om, 5.0) * exp(-1.25 * pow(om_p / om, 4.0)) * pow(gamma, r);
	return S_om * g / (2.0 * om);
}

float spread(vec2 khat, vec2 dir, float s, float norm) {
	float d = dot(khat, dir);
	return d > 0.0 ? pow(d, s) * norm : 0.0;
}

// 2D S(k) = S(|k|) / |k| * D(theta); wind sea + swell.
float spectrum(vec2 k, float kl) {
	if (kl < 1e-6) return 0.0;
	vec2 khat = k / kl;
	float S = 0.0;
	float U = length(P.wind);
	if (U > 1e-3)
		S += jonswap_k(kl, U, max(P.fetch, 1.0), 3.3) * spread(khat, P.wind / U, P.wind_spread, P.wind_norm);
	float Us = length(P.swell);
	if (Us > 1e-3 && P.swell_amount > 0.0)
		S += P.swell_amount * jonswap_k(kl, Us, max(P.swell_fetch, 1.0), 7.0)
				* spread(khat, P.swell / Us, P.swell_spread, P.swell_norm);
	return S / kl * exp(-kl * kl * P.suppress * P.suppress);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID);
	if (id.x >= P.n || id.y >= P.n || id.z >= P.cascade_count) return;

	int   N = P.n;
	float L = P.patch_sizes[id.z];
	float dk = TAU / L;

	// Centered wavenumber (k indexed -N/2 .. N/2). The compose pass applies
	// the matching (-1)^(x+y) permutation on the spatial output.
	vec2 k  = dk * vec2(float(id.x - N / 2), float(id.y - N / 2));
	float kl = length(k);

	float lo = P.cutoff_low[id.z];
	float hi = P.cutoff_high[id.z];

	vec2 h0  = vec2(0.0);
	vec2 h0m = vec2(0.0);

	if (kl > 1e-6 && kl >= lo && kl < hi) {
		// h0(k)
		vec2 g0 = gaussian(id, P.seed);
		float amp = P.amplitude * sqrt(spectrum(k, kl) * dk * dk);
		h0 = (1.0 / sqrt(2.0)) * g0 * amp;

		// h0(-k): use the Gaussian draw that the mirror texel owns, so the
		// field is consistent regardless of which texel evaluates it.
		ivec3 mir = ivec3((N - id.x) % N, (N - id.y) % N, id.z);
		vec2 gm = gaussian(mir, P.seed);
		vec2 km = -k;
		float ampm = P.amplitude * sqrt(spectrum(km, kl) * dk * dk);
		h0m = (1.0 / sqrt(2.0)) * gm * ampm;
	}

	// store h0(k) and conj(h0(-k))
	imageStore(h0_tex, id, vec4(h0, h0m.x, -h0m.y));
}
