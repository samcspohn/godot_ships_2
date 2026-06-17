shader_type spatial;
render_mode blend_mix, depth_draw_always, specular_schlick_ggx;

// =====================================================================
// FFT CASCADE CONTRACT
// ---------------------------------------------------------------------
// The compute pipeline fills these two texture arrays, one slice per
// cascade. The spatial shader only SAMPLES them; all time evolution
// (h(k,t)) happens compute-side, so there is no wave_time here anymore.
//
//   fft_displacement[i].rgb = (Dx, Dy, Dz)
//       Dy  = height,  Dx/Dz = horizontal (choppiness) displacement.
//   fft_derivatives[i].rg   = (dDy/dx, dDy/dz)   -> height slope, normals
//   fft_derivatives[i].ba   = (dDx/dx, dDz/dz)   -> folding terms, reserved
//                                                   for open-water foam (see
//                                                   FOAM HOOK in fragment()).
//
// Cascades are band-limited per the spectrum and use NON-COMMENSURATE
// patch sizes (cascade_scales) so the combined surface only repeats at
// their LCM -> tiling effectively disappears. repeat_enable + mipmaps
// let distant samples mip down, which is what actually kills the
// far-field shimmer/tiling without per-cascade distance code.
// =====================================================================

uniform sampler2DArray fft_displacement : repeat_enable, filter_linear_mipmap;
uniform sampler2DArray fft_derivatives  : repeat_enable, filter_linear_mipmap;
uniform sampler2DArray fft_foam         : repeat_enable, filter_linear;

uniform int   cascade_count = 3;
uniform float cascade_scales[4]; //   = { 1024.0, 128.0, 24.0, 6.0 };  // patch L (m), large->fine
uniform float cascade_strength[4]; // = { 1.0, 1.0, 1.0, 1.0 };        // per-cascade weight

uniform float choppiness = 1.0;        // horizontal displacement scale (lambda)
uniform float chop_fade_near = 150.0;  // horizontal disp looks bad far away; fade it
uniform float chop_fade_far  = 1200.0; // out between these distances from camera
uniform float foam_roughness = 0.9;    // roughness on whitecapped pixels

// --- depth shading / shoreline foam (unchanged) ---
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3 shallow : source_color = vec3(0.10, 0.30, 0.50);
uniform vec3 deep    : source_color = vec3(0.15, 0.2, 0.35);
uniform float depth_fade = 8.0;
uniform float foam_band  = 0.5;

// --- wake/splash tile system (unchanged) ---
uniform sampler2DArray wave_array : repeat_disable;
uniform sampler2D index_tex : repeat_disable, filter_nearest;
uniform bool tiles_on = false;
uniform float tile_world = 1000.0;
uniform int grid_origin = 32;
uniform float wave_height_scale = 0.5;

varying vec2 v_world_xz;
varying float v_wave_height;

vec2 sample_tile(vec2 wxz) {
	if (!tiles_on) return vec2(0.0);
	ivec2 cell = ivec2(floor(wxz / tile_world)) + ivec2(grid_origin);
	ivec2 sz = textureSize(index_tex, 0);
	if (cell.x < 0 || cell.y < 0 || cell.x >= sz.x || cell.y >= sz.y) return vec2(0.0);
	float slotf = texelFetch(index_tex, cell, 0).r;
	if (slotf < -0.5) return vec2(0.0);
	vec2 uv = fract(wxz / tile_world);
	vec4 w = textureLod(wave_array, vec3(uv, slotf), 0.0);
	return vec2(w.r, w.b);   // height, foam
}

// 4-corner box filter at +-half a sim cell, removes sub-texel spikes.
vec2 sample_tile_smooth(vec2 wxz) {
	float s = tile_world / 128.0 * 0.5;
	vec2 r = vec2(0.0);
	r += sample_tile(wxz + vec2(-s, -s));
	r += sample_tile(wxz + vec2( s, -s));
	r += sample_tile(wxz + vec2(-s,  s));
	r += sample_tile(wxz + vec2( s,  s));
	return r * 0.25;
}

// Per-cascade UV offsets: shifts each cascade's sampling origin so tiles from
// different cascades never align, eliminating visible repetition even when
// cascade_count is low. Values are in texture space (0..1); tune freely.
const vec2 CASCADE_OFFSETS[4] = vec2[4](
	vec2(0.0,    0.0   ),
	vec2(0.4337, 0.7753),
	vec2(0.1863, 0.5124),
	vec2(0.7271, 0.2491)
);

// Sum FFT displacement across all cascades at a world-XZ position.
// chop = current (possibly distance-faded) horizontal displacement scale.
vec3 sample_ocean_disp(vec2 wxz, float chop) {
	vec3 disp = vec3(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		vec3 d  = texture(fft_displacement, vec3(uv, float(i))).xyz;
		disp += vec3(-d.x * chop, d.y, -d.z * chop) * cascade_strength[i];
	}
	return disp;
}

// Sum FFT height-slope across all cascades (for per-pixel normals).
vec2 sample_ocean_slope(vec2 wxz) {
	vec2 slope = vec2(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		slope += texture(fft_derivatives, vec3(uv, float(i))).rg * cascade_strength[i];
	}
	return slope;
}

void vertex() {
	float morph_w = UV.x;
	float cell = UV.y;
	float coarse = cell * 2.0;

	vec3 m_origin = MODEL_MATRIX[3].xyz;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// world-lock to this level's own grid -> no sliding as the mesh recenters
	vec2 fine_xz   = round(world.xz / cell)   * cell;
	vec2 coarse_xz = round(world.xz / coarse) * coarse;
	vec2 s_xz = mix(fine_xz, coarse_xz, morph_w);   // collapse onto coarse at the seam

	// Distance-fade the horizontal choppiness only; height stays full strength.
	float dist = length(CAMERA_POSITION_WORLD - world);
	float chop = choppiness * (1.0 - smoothstep(chop_fade_near, chop_fade_far, dist));

	// FFT ambient ocean (replaces the old Gerstner sum, which now lives only
	// in the server-side CPU buoyancy sim).
	vec3 disp = sample_ocean_disp(s_xz, chop);

	// Wake/splash tiles composite additively on top of the FFT surface.
	vec2 tile = sample_tile_smooth(s_xz);
	disp.y += tile.x * wave_height_scale;

	v_wave_height = disp.y;
	v_world_xz = s_xz;

	vec3 final_world = vec3(s_xz.x, VERTEX.y, s_xz.y) + disp;
	VERTEX = final_world - m_origin;   // back to local (mesh only translates)

	// Provisional normal; the real per-pixel normal is built in fragment()
	// from the cascade slope textures (much finer than vertex density allows).
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	// ---- Per-pixel normal from FFT slopes (+ wake tile gradient) ----
	vec2 slope = sample_ocean_slope(v_world_xz);

	// Fold the wake-tile height gradient into the slope so wakes shade
	// correctly instead of only displacing geometry. Central difference.
	const float ne = 4.0;  // ~2 sim cells, world units
	float hx = (sample_tile_smooth(v_world_xz + vec2(ne, 0.0)).x
	          - sample_tile_smooth(v_world_xz - vec2(ne, 0.0)).x) * wave_height_scale / (2.0 * ne);
	float hz = (sample_tile_smooth(v_world_xz + vec2(0.0, ne)).x
	          - sample_tile_smooth(v_world_xz - vec2(0.0, ne)).x) * wave_height_scale / (2.0 * ne);
	slope += vec2(hx, hz);

	vec3 world_n = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);  // world -> view

	// ---- Depth-based color + shoreline foam (unchanged) ----
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene_z = -(v.z / v.w);
	float water_depth = scene_z - (-VERTEX.z);  // VERTEX is view-space here

	float blend = clamp(water_depth / depth_fade, 0.0, 1.0);
	float foam  = 1.0 - clamp(water_depth / foam_band, 0.0, 1.0);
	ALBEDO = mix(mix(shallow, deep, blend), vec3(1.0), foam);

	// ---- Wake-tile foam (unchanged 5-tap blend) ----
	float _fs = tile_world / 128.0 * 1.5;
	float foam_val = (sample_tile(v_world_xz).y * 2.0
		+ sample_tile(v_world_xz + vec2( _fs, 0.0)).y
		+ sample_tile(v_world_xz + vec2(-_fs, 0.0)).y
		+ sample_tile(v_world_xz + vec2(0.0,  _fs)).y
		+ sample_tile(v_world_xz + vec2(0.0, -_fs)).y) / 6.0;
	ALBEDO = mix(ALBEDO, vec3(1.0), smoothstep(0.0, 0.8, foam_val));

	// ---- Whitecap foam accumulated by the compose compute pass ----
	float wc = 0.0;
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = v_world_xz / cascade_scales[i] + CASCADE_OFFSETS[i];
		wc += texture(fft_foam, vec3(uv, float(i))).r * cascade_strength[i];
	}
	wc = clamp(wc, 0.0, 1.0);
	ALBEDO = mix(ALBEDO, vec3(1.0), wc);

	METALLIC  = 0.0;
	ROUGHNESS = mix(0.02, foam_roughness, wc);
	SPECULAR  = 0.6;
}
