shader_type spatial;
render_mode blend_mix, depth_draw_always, specular_schlick_ggx;

// =====================================================================
// FFT CASCADE CONTRACT
// ---------------------------------------------------------------------
//   fft_displacement[i].rgb = (Dx, Dy, Dz)
//   fft_derivatives[i].rg   = (dDy/dx, dDy/dz)  height slopes / normals
//   fft_derivatives[i].ba   = (dDx/dx, dDz/dz)  Jacobian / foam
// =====================================================================

uniform sampler2DArray fft_displacement : repeat_enable, filter_linear_mipmap;
uniform sampler2DArray fft_derivatives  : repeat_enable, filter_linear_mipmap;
uniform sampler2DArray fft_foam         : repeat_enable, filter_linear;

uniform int   cascade_count   = 3;
uniform float cascade_scales[4];
uniform float cascade_strength[4];

uniform float choppiness     = 1.0;
uniform float chop_fade_near = 150.0;
uniform float chop_fade_far  = 1200.0;
uniform float foam_roughness    = 0.9;
uniform float water_roughness   = 0.06;  // floor roughness; raise to soften specular lobe
uniform float water_specular    = 0.4;   // fresnel F0 (reflectivity at normal incidence)
uniform float specular_max      = 0.8;   // hard per-light specular cap — keeps ocean below bloom threshold

// --- windless calm patches (Perlin noise wave flattening) ---
uniform float calm_scale      = 4000.0;  // world metres per calm patch cycle
uniform float calm_coverage   = 0.45;    // fraction of ocean that is calm [0..1]
uniform float calm_sharpness  = 0.12;    // edge transition softness
uniform float calm_drift      = 0.0003;  // patch drift speed (world m/s)
uniform float calm_roughness  = 0.03;    // roughness in glassy calm zones

// --- domain warp (breaks macro-scale tiling at distance) ---
// A smooth, large-scale noise offset is added to every cascade UV before
// sampling.  The same offset is used for all cascades so geometry and
// normals stay consistent.
uniform float warp_scale    = 1500.0; // world metres per warp cycle (larger = smoother)
uniform float warp_strength = 1.5;   // UV-space magnitude (0.35 = shifts ±35% of one tile)

// --- foam texture (animated Texture2DArray) ---
// RGB = foam colour, A = coverage mask.  Adjacent frames are cross-faded
// using TIME so the foam streamers visibly morph in a seamless loop.
uniform sampler2DArray foam_tex          : repeat_enable, filter_linear_mipmap;
uniform float          foam_tex_scale    = 8.0;  // world metres per foam tile
uniform float          foam_tex_strength = 0.8;  // 0 = ignore mask, 1 = full carve-out
uniform float          foam_amount       = 0.5;  // scales simulated foam intensity before the cutoff test; lower = less foam
uniform bool           foam_animate      = true; // disable to freeze on a single static frame
uniform float          foam_fps          = 8.0;  // animation playback speed
uniform int            foam_frame_count  = 16;
uniform float          foam_reveal_low   = 0.00; // sim values at/below this show no foam (suppresses noise floor)
uniform float          foam_reveal_high  = 0.10; // sim values at/above this fully reveal the foam texture
uniform bool           debug_foam_alpha  = true; // visualize foam_samp.a as hue (red = 0, purple = 1)

// --- depth shading / shoreline foam ---
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3  shallow    : source_color = vec3(0.10, 0.30, 0.50);
uniform vec3  deep       : source_color = vec3(0.05, 0.08, 0.15);
uniform float depth_fade = 8.0;
uniform float foam_band  = 0.5;

// --- wake/splash tile system ---
uniform sampler2DArray wave_array : repeat_disable;
uniform sampler2D      index_tex  : repeat_disable, filter_nearest;
uniform bool  tiles_on        = false;
uniform float tile_world      = 1000.0;
uniform int   grid_origin     = 32;
uniform float wave_height_scale = 0.5;

varying vec2  v_world_xz;
varying float v_wave_height;
varying vec2  v_wave_velocity;
varying float v_calm_factor;  // 0 = flat/windless, 1 = full waves

// =====================================================================
// Gradient noise (IQ quintic) — must be defined before the sample
// functions so domain_warp() is in scope when they are compiled.
// =====================================================================

vec2 _nhash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}

// Returns (height, dh/dx, dh/dz).
vec3 gnoise(vec2 p) {
	vec2 i  = floor(p);
	vec2 f  = fract(p);
	vec2 u  = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = _nhash2(i),                 gb = _nhash2(i + vec2(1.0, 0.0)),
	     gc = _nhash2(i + vec2(0.0, 1.0)), gd = _nhash2(i + vec2(1.0, 1.0));
	float va = dot(ga, f),                    vb = dot(gb, f - vec2(1.0, 0.0)),
	      vc = dot(gc, f - vec2(0.0, 1.0)),   vd = dot(gd, f - vec2(1.0, 1.0));
	float v = va + u.x*(vb-va) + u.y*(vc-va) + u.x*u.y*(va-vb-vc+vd);
	vec2  g = ga + u.x*(gb-ga) + u.y*(gc-ga) + u.x*u.y*(ga-gb-gc+gd)
	        + du * (u.yx*(va-vb-vc+vd) + vec2(vb-va, vc-va));
	return vec3(v, g);
}

// Large-scale UV-space domain warp.  The same offset is applied to every
// cascade so displacement and normals stay in agreement.
// Using two decorrelated noise samples for the x and z components.
vec2 domain_warp(vec2 wxz) {
	vec2 p = wxz / warp_scale;
	float wx = gnoise(p).x;
	float wz = gnoise(p + vec2(3.17, 1.59)).x;
	return vec2(wx, wz) * warp_strength;
}

// Returns 0 in calm (windless/flat) zones, 1 in full-wave zones.
// Three-octave FBM gives organic, irregular patch shapes.
float calm_mask(vec2 wxz) {
	vec2 p = wxz / calm_scale + vec2(TIME * calm_drift, TIME * calm_drift * 0.61);
	float n = gnoise(p).x                          * 0.60
	        + gnoise(p * 2.3 + vec2(1.7, 0.30)).x  * 0.30
	        + gnoise(p * 5.1 + vec2(3.2,  1.8)).x  * 0.10;
	n = n * 0.5 + 0.5;
	return smoothstep(calm_coverage - calm_sharpness, calm_coverage + calm_sharpness, n);
}

// =====================================================================
// Wake tile helpers
// =====================================================================

vec4 sample_tile(vec2 wxz) {
	if (!tiles_on) return vec4(0.0);
	ivec2 cell = ivec2(floor(wxz / tile_world)) + ivec2(grid_origin);
	ivec2 sz = textureSize(index_tex, 0);
	if (cell.x < 0 || cell.y < 0 || cell.x >= sz.x || cell.y >= sz.y) return vec4(0.0);
	float slotf = texelFetch(index_tex, cell, 0).r;
	if (slotf < -0.5) return vec4(0.0);
	vec2 uv = fract(wxz / tile_world);
	vec4 w = textureLod(wave_array, vec3(uv, slotf), 0.0);
	return w;
}

vec2 sample_tile_smooth(vec2 wxz) {
	float s = tile_world / 128.0 * 0.5;
	vec2 r = vec2(0.0);
	r += sample_tile(wxz + vec2(-s, -s)).rb;
	r += sample_tile(wxz + vec2( s, -s)).rb;
	r += sample_tile(wxz + vec2(-s,  s)).rb;
	r += sample_tile(wxz + vec2( s,  s)).rb;
	return r * 0.25;
}

// =====================================================================
// Per-cascade UV offsets (phase-shifts each cascade so tiles never align)
// =====================================================================

const vec2 CASCADE_OFFSETS[4] = vec2[4](
	vec2(0.0,    0.0   ),
	vec2(0.4337, 0.7753),
	vec2(0.1863, 0.5124),
	vec2(0.7271, 0.2491)
);

// =====================================================================
// FFT cascade sampling — domain warp applied inside both functions so
// geometry (vertex) and normals (fragment) use identical UV coordinates.
// =====================================================================

vec3 sample_ocean_disp(vec2 wxz, float chop) {
	vec2 warp = domain_warp(wxz);
	vec3 disp = vec3(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i] + warp;
		vec3 d  = texture(fft_displacement, vec3(uv, float(i))).xyz;
		disp += vec3(-d.x * chop, d.y, -d.z * chop) * cascade_strength[i];
	}
	return disp;
}

vec2 sample_ocean_slope(vec2 wxz) {
	vec2 warp  = domain_warp(wxz);
	vec2 slope = vec2(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i] + warp;
		slope += texture(fft_derivatives, vec3(uv, float(i))).rg * cascade_strength[i];
	}
	return slope;
}

// The foam texture's alpha is used as a cutoff rather than a plain opacity
// multiply: a foam layer only shows where the texture alpha reaches the
// simulation's foam value, then snaps to fully opaque. This lets the
// simulation intensity "reveal" progressively more of the texture's
// streamers instead of just dimming a uniform coat of foam.
vec3 hsv2rgb(vec3 c) {
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

float foam_alpha_cutoff(float sim_value, float tex_alpha) {
	// Invert: higher sim_value lowers the required alpha, so zero simulated
	// foam requires (near-)impossible full-opacity texture (renders nothing),
	// while full-intensity foam requires none (renders everywhere).
	// Dead-zone + ramp instead of a plain linear or power-law map: a pure
	// power curve can't both suppress the near-zero simulation noise floor
	// (which is rarely ever exactly 0) and still meaningfully ramp up by
	// mid-range values, since it rises steeply from zero either way. This
	// clamps everything below foam_reveal_low to "no foam" and only starts
	// revealing texture once the simulation value is genuinely elevated.
	float revealed  = smoothstep(foam_reveal_low, foam_reveal_high, clamp(sim_value, 0.0, 1.0));
	float threshold = 1.0 - revealed;
	float aa = max(fwidth(tex_alpha), 0.001);
	return smoothstep(threshold - aa, threshold + aa, tex_alpha);

}

// =====================================================================
// Vertex shader
// =====================================================================

void vertex() {
	float morph_w = UV.x;
	float cell    = UV.y;
	float coarse  = cell * 2.0;

	vec3 m_origin = MODEL_MATRIX[3].xyz;
	vec3 world    = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	vec2 fine_xz   = round(world.xz / cell)   * cell;
	vec2 coarse_xz = round(world.xz / coarse) * coarse;
	vec2 s_xz      = mix(fine_xz, coarse_xz, morph_w);

	float dist = length(CAMERA_POSITION_WORLD - world);
	float chop = choppiness * (1.0 - smoothstep(chop_fade_near, chop_fade_far, dist));

	v_calm_factor = calm_mask(s_xz);
	vec3 disp = sample_ocean_disp(s_xz, chop) * v_calm_factor;
	// Box-filter tile height over the current cell footprint.
	// Spread scales with cell size so wide wakes are preserved at distance
	// while sub-cell spikes average toward zero instead of mounding.
	float spread = cell * 0.5;
	float tile_h = sample_tile(s_xz).r
	             + sample_tile(s_xz + vec2(-spread, -spread)).r
	             + sample_tile(s_xz + vec2( spread, -spread)).r
	             + sample_tile(s_xz + vec2(-spread,  spread)).r
	             + sample_tile(s_xz + vec2( spread,  spread)).r;
	disp.y += (tile_h * 0.2) * wave_height_scale;

	v_wave_height = disp.y;
	v_world_xz    = s_xz;

	vec3 final_world = vec3(s_xz.x, VERTEX.y, s_xz.y) + disp;
	VERTEX = final_world - m_origin;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

// =====================================================================
// Fragment shader
// =====================================================================

void fragment() {
	// ---- Per-pixel normal from FFT slopes + wake tile gradient ----
	vec2 slope = sample_ocean_slope(v_world_xz) * v_calm_factor;

	const float ne = 4.0;
	float hx = (sample_tile_smooth(v_world_xz + vec2(ne, 0.0)).x
	          - sample_tile_smooth(v_world_xz - vec2(ne, 0.0)).x) * wave_height_scale / (2.0 * ne);
	float hz = (sample_tile_smooth(v_world_xz + vec2(0.0, ne)).x
	          - sample_tile_smooth(v_world_xz - vec2(0.0, ne)).x) * wave_height_scale / (2.0 * ne);
	slope += vec2(hx, hz);

	vec3 world_n = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	// ---- Animated foam texture: cross-fade adjacent frames with TIME ----
	float foam_t    = foam_animate ? mod(TIME * foam_fps, float(foam_frame_count)) : 0.0;
	int   frame_a   = int(foam_t);
	int   frame_b   = foam_animate ? (frame_a + 1) % foam_frame_count : frame_a;
	vec2  foam_uv   = v_world_xz / foam_tex_scale;
	vec4  foam_samp = mix(
		texture(foam_tex, vec3(foam_uv, float(frame_a))),
		texture(foam_tex, vec3(foam_uv, float(frame_b))),
		fract(foam_t)
	);
	vec3  foam_color = foam_samp.rgb;

	// ---- Depth-based color + shoreline foam ----
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4  v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene_z     = -(v.z / v.w);
	float water_depth = scene_z - (-VERTEX.z);

	float blend    = clamp(water_depth / depth_fade, 0.0, 1.0);
	float foam_raw = (1.0 - clamp(water_depth / foam_band, 0.0, 1.0)) * foam_amount;
	float foam     = mix(foam_raw, foam_alpha_cutoff(foam_raw, foam_samp.a), foam_tex_strength);
	ALBEDO = mix(mix(shallow, deep, blend), foam_color, foam);

	// // ---- Wake-tile foam ----
	float _fs = tile_world / 128.0 * 1.5;
	// lines 211-215 — change .y → .z (5 occurrences)
    float foam_val = (sample_tile(v_world_xz).z * 2.0
        + sample_tile(v_world_xz + vec2( _fs, 0.0)).z
        + sample_tile(v_world_xz + vec2(-_fs, 0.0)).z
        + sample_tile(v_world_xz + vec2(0.0,  _fs)).z
        + sample_tile(v_world_xz + vec2(0.0, -_fs)).z) / 6.0;
    foam_val = pow(foam_val, 0.5);
    // foam_val = min(foam_val, 0.35);
    foam_val *= 0.7;
	float tile_foam_raw = smoothstep(0.15, 0.75, foam_val) * foam_amount;
	float tile_foam     = mix(tile_foam_raw, foam_alpha_cutoff(tile_foam_raw, foam_samp.a), foam_tex_strength);
	ALBEDO = mix(ALBEDO, foam_color, tile_foam);
	ROUGHNESS = mix(ROUGHNESS, foam_roughness, tile_foam);
	// vec2 vel = sample_tile(v_world_xz).rg;
	// vec2 veln = sample_tile(v_world_xz + vec2(_fs, 0.0)).rg;
	// float dvel = length(vel - veln);
	// vec2 veln2 = sample_tile(v_world_xz + vec2(0.0, _fs)).rg;
 //    dvel + length(vel - veln2);
 //    vec2 veln3 = sample_tile(v_world_xz + vec2(-_fs, 0.0)).rg;
 //    dvel + length(vel - veln3);
 //    vec2 veln4 = sample_tile(v_world_xz + vec2(0.0, -_fs)).rg;
 //    dvel + length(vel - veln4);
 //    float speed = length(dvel);
 //    if (speed > 0.5) {
 //        float tile_foam = smoothstep(0.0, 0.75, (speed - 0.5) / 1.0);
 //        ALBEDO = mix(ALBEDO, vec3(1.0), tile_foam);
 //        ROUGHNESS = mix(ROUGHNESS, foam_roughness, tile_foam);
 //    }

	// ---- Whitecap foam ----
	vec2 warp = domain_warp(v_world_xz);
	float wc = 0.0;
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = v_world_xz / cascade_scales[i] + CASCADE_OFFSETS[i] + warp;
		wc += texture(fft_foam, vec3(uv, float(i))).r * cascade_strength[i];
	}
	wc = clamp(wc, 0.0, 1.0) * v_calm_factor * foam_amount;
	float _wc = wc;
	wc = mix(wc, foam_alpha_cutoff(wc, foam_samp.a), foam_tex_strength);
	ALBEDO = mix(ALBEDO, foam_color, wc);

	METALLIC  = 0.0;
	ROUGHNESS = mix(calm_roughness, mix(water_roughness, foam_roughness, wc), v_calm_factor);

	if (debug_foam_alpha) {
		// Red (hue 0°) -> purple (hue 300°) across the cutoff alpha's 0..1 range.
		ALBEDO = hsv2rgb(vec3(foam_samp.a * (300.0 / 360.0), 1.0, 1.0));
	}
}

void light() {
	float NdotL = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * NdotL;

	if (NdotL > 0.0) {
		vec3  H     = normalize(VIEW + LIGHT);
		float NdotH = max(dot(NORMAL, H), 0.0);
		float NdotV = max(dot(NORMAL, VIEW), 1e-4);
		float VdotH = max(dot(VIEW,   H), 0.0);

		float alpha  = max(ROUGHNESS * ROUGHNESS, 1e-4);
		float alpha2 = alpha * alpha;
		float denom  = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
		float D      = alpha2 / (PI * denom * denom);

		float F0 = water_specular;
		float F  = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);

		float k  = alpha * 0.5;
		float Gv = NdotV / (NdotV * (1.0 - k) + k);
		float Gl = NdotL / (NdotL * (1.0 - k) + k);

		float spec = D * F * Gv * Gl / (4.0 * NdotV);
		SPECULAR_LIGHT += clamp(LIGHT_COLOR * ATTENUATION * spec, vec3(0.0), vec3(specular_max));
	}
}
