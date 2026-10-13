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
uniform sampler2DArray fft_derivatives  : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2DArray fft_foam         : repeat_enable, filter_linear_mipmap;

uniform int   cascade_count   = 4;
uniform float cascade_scales[4];
uniform float cascade_strength[4];
uniform float fft_size        = 256.0;

// Cumulative slope variance above k (log2 k axis); adds roughness for sub-pixel waves.
uniform sampler2D slope_var_tex : filter_linear, repeat_disable;
uniform vec2  slope_var_range   = vec2(-8.0, 5.0);

uniform float ring_half   = 128.0;  // level half-width in cells
uniform float morph_cells = 16.0;

uniform float choppiness     = 1.0;
uniform float chop_fade_near = 150.0;
uniform float chop_fade_far  = 1200.0;
uniform float foam_roughness    = 0.9;
uniform float water_roughness   = 0.06;  // floor roughness; raise to soften specular lobe
uniform float water_specular    = 0.02;  // Fresnel F0 of water
uniform float specular_max      = 0.8;   // hard per-light specular cap — keeps ocean below bloom threshold

// --- windless calm patches (Perlin noise wave flattening) ---
uniform float calm_scale      = 4000.0;  // world metres per calm patch cycle
uniform float calm_coverage   = 0.45;    // fraction of ocean that is calm [0..1]
uniform float calm_sharpness  = 0.12;    // edge transition softness
uniform float calm_drift      = 0.0003;  // patch drift speed (world m/s)
uniform float calm_roughness  = 0.03;    // roughness in glassy calm zones
uniform float calm_floor      = 0.35;    // wave scale left inside calm zones

// --- per-cascade amplitude modulation (breaks tiling without moving UVs) ---
uniform float mod_scale    = 2300.0;
uniform float mod_strength = 0.45;

// Whitecaps where the combined horizontal-displacement Jacobian folds below these.
uniform float whitecap_j_low  = 0.45;
uniform float whitecap_j_high = 0.75;
uniform float whitecap_max_lod = 2.0;

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
// Gradient noise (IQ quintic)
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

vec4 cascade_mods(vec2 wxz) {
	vec4 m;
	for (int i = 0; i < 4; i++) {
		vec2 p = wxz / (mod_scale * (1.0 + 0.37 * float(i))) + vec2(5.3, 9.1) * float(i);
		m[i] = max(1.0 + mod_strength * 1.4 * gnoise(p).x, 0.0);
	}
	return m;
}

// Returns 0 in calm (windless/flat) zones, 1 in full-wave zones.
// Three-octave FBM gives organic, irregular patch shapes.
float calm_mask(vec2 wxz) {
	vec2 p = wxz / calm_scale + vec2(TIME * calm_drift, TIME * calm_drift * 0.61);
	float n = gnoise(p).x                          * 0.60
	        + gnoise(p * 2.3 + vec2(1.7, 0.30)).x  * 0.30
	        + gnoise(p * 5.1 + vec2(3.2,  1.8)).x  * 0.10;
	n = n * 0.5 + 0.5;
	return mix(calm_floor, 1.0, smoothstep(calm_coverage - calm_sharpness, calm_coverage + calm_sharpness, n));
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
// FFT cascade sampling
// =====================================================================

vec3 sample_ocean_disp(vec2 wxz, float chop, float footprint) {
	vec4 cm = cascade_mods(wxz);
	vec3 disp = vec3(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		float lod = max(log2(footprint * fft_size / cascade_scales[i]), 0.0);
		vec3 d  = textureLod(fft_displacement, vec3(uv, float(i)), lod).xyz;
		disp += vec3(-d.x * chop, d.y, -d.z * chop) * cascade_strength[i] * cm[i];
	}
	return disp;
}

// (slope.xz, Jxx, Jzz) summed over cascades.
vec4 sample_ocean_derivs(vec2 wxz, vec4 cm) {
	vec4 d = vec4(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		d += texture(fft_derivatives, vec3(uv, float(i))) * cascade_strength[i] * cm[i];
	}
	return d;
}

// Mip-capped so distant crests are not averaged away; full chop so the
// distance fade on vertex chop does not erase them.
float whitecap_jacobian(vec2 wxz, vec4 cm, float footprint) {
	vec2 j = vec2(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		float lod = clamp(log2(footprint * fft_size / cascade_scales[i]), 0.0, whitecap_max_lod);
		j += textureLod(fft_derivatives, vec3(uv, float(i)), lod).ba * cascade_strength[i] * cm[i];
	}
	j *= choppiness * v_calm_factor;
	return (1.0 + j.x) * (1.0 + j.y);
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
	// VERTEX is in level-cell units relative to the level centre; the instance
	// transform is scale(cell) + floor-snapped centre (see ocean.gd).
	float cell   = MODEL_MATRIX[0].x;
	vec2  center = MODEL_MATRIX[3].xz;
	vec2  local  = VERTEX.xz;

	float cheb = max(abs(local.x), abs(local.y));
	float w    = clamp((cheb - (ring_half - morph_cells)) / morph_cells, 0.0, 1.0);
	vec2  g    = center + local * cell;
	vec2  gc   = floor(g / (2.0 * cell)) * (2.0 * cell);
	vec2  s_xz = mix(g, gc, w);
	float footprint = cell * (1.0 + w);

	float dist = length(CAMERA_POSITION_WORLD.xz - s_xz);
	float chop = choppiness * (1.0 - smoothstep(chop_fade_near, chop_fade_far, dist));

	v_calm_factor = calm_mask(s_xz);
	vec3 disp = sample_ocean_disp(s_xz, chop, footprint) * v_calm_factor;

	// Wake/splash heights are only a few sim cells wide; on quads much larger
	// than that they only lift whole quads, so they fade to normal-only detail.
	float sim_cell = tile_world / 128.0;
	float tile_fade = 1.0 - smoothstep(sim_cell * 1.5, sim_cell * 3.0, footprint);
	if (tile_fade > 0.0) {
		float spread = footprint * 0.5;
		float tile_h = sample_tile(s_xz).r
		             + sample_tile(s_xz + vec2(-spread, -spread)).r
		             + sample_tile(s_xz + vec2( spread, -spread)).r
		             + sample_tile(s_xz + vec2(-spread,  spread)).r
		             + sample_tile(s_xz + vec2( spread,  spread)).r;
		disp.y += tile_h * 0.2 * wave_height_scale * tile_fade;
	}

	v_wave_height = disp.y;
	v_world_xz    = s_xz;

	vec3 world = vec3(s_xz.x, 0.0, s_xz.y) + disp;
	VERTEX = vec3((world.x - center.x) / cell, world.y, (world.z - center.y) / cell);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

// =====================================================================
// Fragment shader
// =====================================================================

void fragment() {
	// ---- Per-pixel normal from FFT slopes + wake tile gradient ----
	vec4 cm = cascade_mods(v_world_xz);
	vec4 derivs = sample_ocean_derivs(v_world_xz, cm) * v_calm_factor;
	vec2 slope = derivs.xy;

	vec2  fx = dFdx(v_world_xz), fy = dFdy(v_world_xz);
	float footprint = sqrt(max(length(fx) * length(fy), 1e-8));
	float jacobian = whitecap_jacobian(v_world_xz, cm, footprint);
	float lk = log2(PI / footprint);
	float lost_u = clamp((lk - slope_var_range.x) / (slope_var_range.y - slope_var_range.x), 0.0, 1.0);
	float lost_var = texture(slope_var_tex, vec2(lost_u, 0.5)).r * v_calm_factor * v_calm_factor;

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
	float wc = (1.0 - smoothstep(whitecap_j_low, whitecap_j_high, jacobian)) * foam_amount;
	wc = mix(wc, foam_alpha_cutoff(wc, foam_samp.a), foam_tex_strength);
	ALBEDO = mix(ALBEDO, foam_color, wc);

	METALLIC  = 0.0;
	float base_rough = mix(calm_roughness, mix(water_roughness, foam_roughness, wc), v_calm_factor);
	// GGX alpha = roughness^2; Beckmann-equivalent alpha^2 ≈ total slope variance.
	float alpha = sqrt(pow(base_rough, 4.0) + lost_var);
	ROUGHNESS = sqrt(alpha);

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
