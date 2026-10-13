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
uniform float water_roughness   = 0.06;
uniform float water_specular    = 0.02;  // Fresnel F0 of water
uniform float specular_max      = 0.8;   // per-light cap, keeps the sun glint below bloom
uniform float sun_glint         = 0.35;  // gameplay dimming of the sun path, applied before the cap

// --- water body ---
uniform vec3  deep          : source_color = vec3(0.025, 0.07, 0.13);
uniform vec3  shallow       : source_color = vec3(0.06, 0.25, 0.30);
uniform vec3  scatter_color : source_color = vec3(0.04, 0.30, 0.34);
uniform float crest_height  = 2.0;   // displacement (m) treated as a fully lit crest
uniform float crest_ambient = 0.35;  // crest lightening independent of sun direction
uniform float sss_strength  = 1.6;   // sun shining through crests toward the camera
uniform float sss_facing    = 0.25;
uniform float crest_view_falloff = 1.5;  // crest lighting fades as the view turns straight down

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

// --- foam ---
// foam_tex.r = reveal order (equalised), .g = bubble brightness; see gen_foam.py.
uniform sampler2D foam_tex : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3  foam_color       : source_color = vec3(0.86, 0.9, 0.92);
uniform vec3  bubble_color     : source_color = vec3(0.04, 0.16, 0.19);
uniform float foam_amount      = 1.0;
uniform float foam_tex_scale   = 9.0;    // metres per lace tile
uniform float foam_detail_scale = 2.3;
uniform float foam_edge        = 0.06;
uniform float foam_drift       = 0.3;    // m/s along the wind
uniform vec2  wind_dir         = vec2(0.94, 0.35);
uniform float foam_roughness   = 0.8;
uniform float whitecap_residual = 0.85;  // looser Jacobian bound for thin lace around crests
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
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
varying float v_calm_factor;  // 0 = flat/windless, 1 = full waves
varying float f_crest;
varying float f_foam;

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

// Equalised reveal order -> opacity; c = 0 shows nothing, c = 1 covers all.
float foam_cover(float c, float order, float edge) {
	float t = 1.0 + edge - c * (1.0 + 2.0 * edge);
	return smoothstep(t - edge, t + edge, order);
}

float tile_foam_raw(vec2 wxz) {
	float r = tile_world / 128.0 * 1.5;
	float v = (sample_tile(wxz).z * 2.0
		+ sample_tile(wxz + vec2( r, 0.0)).z + sample_tile(wxz + vec2(-r, 0.0)).z
		+ sample_tile(wxz + vec2(0.0,  r)).z + sample_tile(wxz + vec2(0.0, -r)).z) / 6.0;
	return 0.7 * sqrt(max(v, 0.0));
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

	// ---- coverage sources ----
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4  vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float water_depth = -(vp.z / vp.w) + VERTEX.z;
	float shore_c = 1.0 - clamp(water_depth / foam_band, 0.0, 1.0);

	float wc_core = 1.0 - smoothstep(whitecap_j_low, whitecap_j_high, jacobian);
	float wc_lace = 1.0 - smoothstep(whitecap_j_high, whitecap_residual, jacobian);
	float tile_raw = tile_foam_raw(v_world_xz);
	float cover = max(max(wc_core, wc_lace * 0.3), max(smoothstep(0.15, 0.75, tile_raw), shore_c));
	cover = clamp(cover * foam_amount, 0.0, 1.0);
	float sub = clamp(max(wc_lace * wc_lace, smoothstep(0.02, 0.35, tile_raw)) * foam_amount, 0.0, 1.0);

	// ---- foam texture; widen the edge as the lace drops below a pixel so far foam reads as coverage ----
	vec2 drift = wind_dir * TIME * foam_drift;
	vec2 uv_a = (v_world_xz - drift) / foam_tex_scale;
	vec2 uv_b = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * (v_world_xz - drift * 1.3) / foam_detail_scale;
	vec2 fa = texture(foam_tex, uv_a).rg;
	vec2 fb = texture(foam_tex, uv_b).rg;
	float order = clamp(fa.r + (fb.r - 0.5) * 0.35, 0.0, 1.0);
	float tex_lod = log2(footprint * float(textureSize(foam_tex, 0).x) / foam_detail_scale);
	float edge = mix(foam_edge, 0.5, clamp(tex_lod / 5.0, 0.0, 1.0));
	float foam = foam_cover(cover, order, edge);

	// ---- water body: crests lighter than troughs, bubbles tint below the surface ----
	float view_up = clamp((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).y, 0.0, 1.0);
	float crest = clamp(v_wave_height / crest_height, 0.0, 1.0) * v_calm_factor
			* pow(1.0 - view_up, crest_view_falloff);
	float depth_blend = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec3 water = mix(shallow, deep, depth_blend);
	water = mix(water, scatter_color, crest * crest * crest_ambient);
	water = mix(water, bubble_color, sub * (1.0 - foam) * 0.5);

	ALBEDO = mix(water, foam_color * (0.8 + 0.2 * fb.g), foam);
	METALLIC = 0.0;
	// F0(specular) = 0.16 * specular^2 in Godot's IBL; match water_specular.
	SPECULAR = mix(sqrt(water_specular / 0.16), 0.5, foam);
	float base_rough = mix(mix(calm_roughness, water_roughness, v_calm_factor), foam_roughness, foam);
	float alpha = sqrt(pow(base_rough, 4.0) + lost_var);
	ROUGHNESS = sqrt(alpha);
	f_crest = crest;
	f_foam = foam;
}

// Godot multiplies DIFFUSE_LIGHT by ALBEDO afterwards; SPECULAR_LIGHT is not,
// so the crest scatter goes there to keep its own colour.
void light() {
	float NdotL = max(dot(NORMAL, LIGHT), 0.0);
	vec3  sun   = LIGHT_COLOR * ATTENUATION;
	float water = 1.0 - f_foam;
	DIFFUSE_LIGHT += sun * mix(0.4 + 0.6 * NdotL, NdotL, f_foam);

	float NdotV = max(dot(NORMAL, VIEW), 1e-4);
	float sss = sss_strength * f_crest * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0)
			* pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0)
			+ sss_facing * f_crest * NdotV * NdotV;
	float fresnel_v = water_specular + (1.0 - water_specular) * pow(1.0 - NdotV, 5.0);
	SPECULAR_LIGHT += sun * scatter_color * sss * (1.0 - fresnel_v) * water;

	if (NdotL > 0.0) {
		vec3  H     = normalize(VIEW + LIGHT);
		float NdotH = max(dot(NORMAL, H), 0.0);
		float VdotH = max(dot(VIEW, H), 0.0);
		float alpha  = max(ROUGHNESS * ROUGHNESS, 1e-4);
		float alpha2 = alpha * alpha;
		float denom  = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
		float D      = alpha2 / (PI * denom * denom);
		float F  = water_specular + (1.0 - water_specular) * pow(1.0 - VdotH, 5.0);
		float k  = alpha * 0.5;
		float Gv = NdotV / (NdotV * (1.0 - k) + k);
		float Gl = NdotL / (NdotL * (1.0 - k) + k);
		float spec = D * F * Gv * Gl / (4.0 * NdotV);
		SPECULAR_LIGHT += clamp(sun * spec * sun_glint, vec3(0.0), vec3(specular_max)) * water;
	}
}
