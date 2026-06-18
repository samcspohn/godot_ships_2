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
uniform float foam_roughness = 0.9;

// --- domain warp (breaks macro-scale tiling at distance) ---
// A smooth, large-scale noise offset is added to every cascade UV before
// sampling.  The same offset is used for all cascades so geometry and
// normals stay consistent.
uniform float warp_scale    = 1500.0; // world metres per warp cycle (larger = smoother)
uniform float warp_strength = 1.5;   // UV-space magnitude (0.35 = shifts ±35% of one tile)

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
varying vec2 v_wave_velocity;

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

	vec3 disp = sample_ocean_disp(s_xz, chop);
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
	vec2 slope = sample_ocean_slope(v_world_xz);

	const float ne = 4.0;
	float hx = (sample_tile_smooth(v_world_xz + vec2(ne, 0.0)).x
	          - sample_tile_smooth(v_world_xz - vec2(ne, 0.0)).x) * wave_height_scale / (2.0 * ne);
	float hz = (sample_tile_smooth(v_world_xz + vec2(0.0, ne)).x
	          - sample_tile_smooth(v_world_xz - vec2(0.0, ne)).x) * wave_height_scale / (2.0 * ne);
	slope += vec2(hx, hz);

	vec3 world_n = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	// ---- Depth-based color + shoreline foam ----
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4  v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene_z     = -(v.z / v.w);
	float water_depth = scene_z - (-VERTEX.z);

	float blend = clamp(water_depth / depth_fade, 0.0, 1.0);
	float foam  = 1.0 - clamp(water_depth / foam_band, 0.0, 1.0);
	ALBEDO = mix(mix(shallow, deep, blend), vec3(1.0), foam);

	// // ---- Wake-tile foam ----
	float _fs = tile_world / 128.0 * 1.5;
	// lines 211-215 — change .y → .z (5 occurrences)
    float foam_val = (sample_tile(v_world_xz).z * 2.0
        + sample_tile(v_world_xz + vec2( _fs, 0.0)).z
        + sample_tile(v_world_xz + vec2(-_fs, 0.0)).z
        + sample_tile(v_world_xz + vec2(0.0,  _fs)).z
        + sample_tile(v_world_xz + vec2(0.0, -_fs)).z) / 6.0;

	float tile_foam = smoothstep(0.15, 0.75, foam_val);
	ALBEDO = mix(ALBEDO, vec3(1.0), tile_foam);
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
	wc = clamp(wc, 0.0, 1.0);
	ALBEDO = mix(ALBEDO, vec3(1.0), wc);

	METALLIC  = 0.0;
	ROUGHNESS = mix(0.02, foam_roughness, wc);
	SPECULAR  = 0.6;
}
