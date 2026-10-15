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
// Sub-pixel glitter: the mip-averaged lobe is redistributed into sparse sparkles with the same mean.
uniform float glint_density     = 0.5;   // expected lit facets per cell at the lobe peak
uniform float glint_cell        = 1.5;   // cell size in pixels
uniform float glint_rate        = 3.0;   // sparkle lifetimes per second
uniform float glint_density_down = 0.5;  // density scale with the camera looking straight down; 1 at horizontal
uniform float glint_max         = 3.0;   // sparkle brightness ceiling; above glow_hdr_threshold so sparkles bloom
uniform float glint_tail        = 0.5;   // sparkle dimming toward the lobe edge
uniform float glint_var_ref     = 0.004; // lost slope variance at which glitter is half the lobe
uniform vec2  glint_aniso_fade  = vec2(12.0, 48.0);  // footprint elongation where glitter blends into a smooth band

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
// foam_tex.r = lace reveal order, .g = whorl order, .b = churn reveal order, .a = blotches; see gen_foam.py.
uniform sampler2D foam_tex : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3  foam_color       : source_color = vec3(0.86, 0.9, 0.92);
uniform vec3  bubble_color     : source_color = vec3(0.04, 0.16, 0.19);
uniform float foam_amount      = 1.0;
uniform float foam_tex_scale   = 9.0;    // metres per lace tile
uniform float foam_detail_scale = 2.3;
uniform float foam_edge        = 0.06;
uniform float churn_tex_scale  = 80.0;   // metres per churn tile (wakes, blasts)
uniform float churn_edge       = 0.14;
uniform float foam_drift       = 0.3;    // m/s along the wind
uniform vec2  wind_dir         = vec2(0.94, 0.35);
uniform float foam_roughness   = 0.8;
uniform float whitecap_residual = 0.85;  // looser Jacobian bound for thin lace around crests
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform float depth_fade = 8.0;
uniform float foam_band  = 0.5;

// --- wave sims (heights in metres; *_lod = 4x4 averages). Unsuffixed = fine
// splash grid, _c = coarse ship-wake grid. ---
uniform sampler2DArray wave_array   : repeat_disable, filter_linear;
uniform sampler2DArray wave_lod     : repeat_disable, filter_linear;
uniform sampler2D      index_tex    : repeat_disable, filter_nearest;
uniform float tile_world      = 256.0;
uniform int   grid_origin     = 72;
uniform sampler2DArray wave_array_c : repeat_disable, filter_linear;
uniform sampler2DArray wave_lod_c   : repeat_disable, filter_linear;
uniform sampler2D      index_tex_c  : repeat_disable, filter_nearest;
uniform float tile_world_c    = 768.0;
uniform int   grid_origin_c   = 24;
uniform bool  tiles_on        = false;
uniform float wave_height_scale = 1.0;

// --- persistent wake map: (stamp time, strength) per 4 m texel ---
uniform sampler2D      wake_index : repeat_disable, filter_nearest;
uniform sampler2DArray wake_array : repeat_disable, filter_nearest;
uniform float wake_world  = 512.0;
uniform int   wake_origin = 36;
uniform float wake_time   = 0.0;
uniform float wake_life   = 60.0;

// --- foam decal cascades (see foam_decals.gd): r = reveal margin * 0.5 + 0.5, g = bubbles, b = (opacity gain - 1) / 2 ---
uniform sampler2DArray foam_decals : repeat_disable, filter_linear;
uniform vec4 decal_cascades[3];   // (origin xz, extent, texel) per level, finest first

// --- blast shock rings: (x, z, start time on wake_time clock, max radius) ---
uniform vec4  rings[64];
uniform vec4  ring_hulls[64];         // firing ship centerline (stern xz, bow xz); zero = unoccluded
uniform int   ring_count    = 0;
uniform float ring_speed    = 120.0;  // m/s; well below sound so the front reads
uniform float ring_depress  = 0.15;   // centre depression, metres per metre of band width
uniform float ring_foam_linger = 2.0; // foam decal lifetime as a multiple of the fill's (read by WaveManager)
uniform float ring_foam_cover = 0.75; // peak foam decal coverage at the blast centre (read by WaveManager)
uniform float ring_flatten  = 0.48;   // calming of the band at the front
uniform float ring_darken   = 0.36;   // albedo drop in the band at the front
uniform float ring_foam     = 0.24;   // whitening at the blast centre, fading outward
uniform float ring_fill_life = 2.5;   // total visible life as a multiple of the front's travel time
uniform float ring_fill_spread = 0.5; // growth after the front's nominal stop, as a fraction of max radius

varying vec2  v_world_xz;
varying vec2  v_surf_xz;      // displaced; glint cells stay world-fixed instead of riding the chop
varying float v_wave_height;
varying float v_calm_factor;  // 0 = flat/windless, 1 = full waves
varying vec4  v_cm;           // cascade_mods: varies over km, so per-vertex is exact enough
varying float f_crest;
varying float f_foam;
varying vec4  f_glint_u0;  // per-cell random thresholds, angle bin 0 / 1
varying vec4  f_glint_u1;
varying vec4  f_glint_e0;  // per-cell envelope x blend weight
varying vec4  f_glint_e1;
varying float f_glint_w;
varying float f_glint_density;   // glitter share of the specular lobe

// =====================================================================
// Gradient noise (IQ quintic)
// =====================================================================

vec2 _nhash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}

const float GLINT_BINS = 64.0;

float _uhash(ivec2 c, int a, int b) {
	uint h = uint(c.x) * 1597334677u ^ uint(c.y) * 3812015801u ^ uint(a) * 2798796415u ^ uint(b) * 958745281u;
	h = (h ^ (h >> 16u)) * 2246822519u;
	h = (h ^ (h >> 13u)) * 3266489917u;
	h ^= h >> 16u;
	return float(h) * (1.0 / 4294967295.0);
}

vec2 glint_cell_sample(vec2 q, vec2 lvl, int bin) {
	ivec2 c = ivec2(floor(q / exp2(lvl)));
	int k = bin * 4096 + int(lvl.x + 32.0) * 64 + int(lvl.y + 32.0);
	float t = TIME * glint_rate + _uhash(c, k, 0);
	return vec2(_uhash(c, k, int(floor(t)) + 1), sin(PI * fract(t)) * (PI * 0.5));
}

// Cells stretched along the radial (footprint major) axis so each is ~glint_cell pixels on screen;
// the axis is binned so the lattice stays world-fixed.
void glint_lattice(vec2 wxz, vec2 fx, vec2 fy, float bin, out vec4 u, out vec4 e) {
	float th = bin * (TAU / GLINT_BINS);
	vec2 r = vec2(cos(th), sin(th)), t = vec2(-r.y, r.x);
	vec2 q = vec2(dot(wxz, r), dot(wxz, t));
	vec2 fp = vec2(length(vec2(dot(fx, r), dot(fy, r))), length(vec2(dot(fx, t), dot(fy, t)))) * glint_cell;
	vec2 lv = log2(max(fp, vec2(1e-4)));
	vec2 l0 = floor(lv), f = lv - l0;
	int b = int(mod(bin, GLINT_BINS));
	vec2 s00 = glint_cell_sample(q, l0, b), s10 = glint_cell_sample(q, l0 + vec2(1.0, 0.0), b);
	vec2 s01 = glint_cell_sample(q, l0 + vec2(0.0, 1.0), b), s11 = glint_cell_sample(q, l0 + 1.0, b);
	u = vec4(s00.x, s10.x, s01.x, s11.x);
	e = vec4(s00.y, s10.y, s01.y, s11.y) * vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
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
// Sim tiles and wake map
// =====================================================================

float tile_slot(sampler2D idx, float tw, int go, vec2 wxz) {
	if (!tiles_on) return -1.0;
	ivec2 cell = ivec2(floor(wxz / tw)) + ivec2(go);
	ivec2 sz = textureSize(idx, 0);
	if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, sz))) return -1.0;
	return texelFetch(idx, cell, 0).r;
}

// level 0 = full grid, 1 = 4x4 average
float sim_h(sampler2DArray arr, sampler2DArray lod_arr, sampler2D idx, float tw, int go, vec2 wxz, bool coarse) {
	float slot = tile_slot(idx, tw, go, wxz);
	if (slot < -0.5) return 0.0;
	vec3 uvw = vec3(fract(wxz / tw), slot);
	return coarse ? textureLod(lod_arr, uvw, 0.0).r : textureLod(arr, uvw, 0.0).r;
}

float fine_h(vec2 p, bool c) { return sim_h(wave_array, wave_lod, index_tex, tile_world, grid_origin, p, c); }
float coarse_h(vec2 p, bool c) { return sim_h(wave_array_c, wave_lod_c, index_tex_c, tile_world_c, grid_origin_c, p, c); }

// Band-limited to footprint: 5-tap at full res, then the 4x4 average, then nothing.
float sim_vertex_h(vec2 p, float footprint, float cell, bool is_coarse) {
	float fade = 1.0 - smoothstep(cell * 8.0, cell * 16.0, footprint);
	if (fade <= 0.0) return 0.0;
	float slot = is_coarse ? tile_slot(index_tex_c, tile_world_c, grid_origin_c, p) : tile_slot(index_tex, tile_world, grid_origin, p);
	if (slot < -0.5) return 0.0;
	float lod_w = smoothstep(cell, cell * 3.0, footprint);
	float h = 0.0;
	if (lod_w < 1.0) {
		float sp = footprint * 0.5;
		h = is_coarse
			? (coarse_h(p, false) * 2.0 + coarse_h(p + vec2(-sp, -sp), false) + coarse_h(p + vec2(sp, -sp), false)
				+ coarse_h(p + vec2(-sp, sp), false) + coarse_h(p + vec2(sp, sp), false)) / 6.0
			: (fine_h(p, false) * 2.0 + fine_h(p + vec2(-sp, -sp), false) + fine_h(p + vec2(sp, -sp), false)
				+ fine_h(p + vec2(-sp, sp), false) + fine_h(p + vec2(sp, sp), false)) / 6.0;
	}
	if (lod_w > 0.0) h = mix(h, is_coarse ? coarse_h(p, true) : fine_h(p, true), lod_w);
	return h * fade;
}

// 1 where the firing ship's hull lies between the muzzle and p.
float hull_shadow(vec2 o, vec2 p, vec4 hull) {
	vec2 a = hull.xy;
	vec2 ab = hull.zw - a;
	vec2 op = p - o;
	float denom = op.x * ab.y - op.y * ab.x;
	if (dot(ab, ab) < 1.0 || abs(denom) < 1e-4) return 0.0;
	vec2 ao = a - o;
	float t = (ao.x * ab.y - ao.y * ab.x) / denom;
	float s = (ao.x * op.y - ao.y * op.x) / denom;
	if (t <= 0.0 || t >= 1.0) return 0.0;
	return smoothstep(-0.05, 0.05, s) * (1.0 - smoothstep(0.95, 1.05, s));
}

// (ridge slope xz, front calming 0..1, interior fill 0..1) over live rings.
// Shared ring geometry: radius R, band width w, life 0..1, hull visibility.
bool ring_eval(int i, vec2 p, out vec2 d, out float r, out float R, out float w, out float life, out float vis) {
	vec4 e = rings[i];
	float age = wake_time - e.z;
	float dur = e.w / ring_speed;
	if (age < 0.0 || age > dur * ring_fill_life) return false;
	d = p - e.xy;
	r = length(d);
	w = max(e.w * 0.05, 3.0);
	// Constant speed to e.w, then decelerating toward e.w * (1 + ring_fill_spread).
	float tau = dur * ring_fill_spread;
	R = age < dur ? age * ring_speed : e.w + ring_speed * tau * (1.0 - exp(-(age - dur) / tau));
	if (r > R + 3.0 * w) return false;
	vis = 1.0 - hull_shadow(e.xy, p, ring_hulls[i]);
	life = age / (dur * ring_fill_life);
	return true;
}

// Depth under the fill gradient over life: pressed down, rebounds past level, settles.
float ring_bounce(float life) {
	return -cos(PI * 1.5 * life) * (1.0 - life);
}

float shock_depress(vec2 p) {
	float h = 0.0;
	for (int i = 0; i < ring_count; i++) {
		vec2 d; float r, R, w, life, vis;
		if (!ring_eval(i, p, d, r, R, w, life, vis)) continue;
		float q = clamp(r / max(R, 1e-3), 0.0, 1.0);
		h += ring_depress * w * ring_bounce(life) * (1.0 - q) * (1.0 - q) * vis;
	}
	return h;
}

// (depression slope xz, front calming 0..1, interior fill 0..1); blast foam is a decal.
vec4 shock_rings(vec2 p) {
	vec4 acc = vec4(0.0);
	for (int i = 0; i < ring_count; i++) {
		vec2 d; float r, R, w, life, vis;
		if (!ring_eval(i, p, d, r, R, w, life, vis)) continue;
		float q = clamp(r / max(R, 1e-3), 0.0, 1.0);
		float fade = (1.0 - life) * (1.0 - life) * vis;
		acc.w = max(acc.w, (1.0 - q) * (1.0 - q) * (1.0 - life * life) * vis);
		acc.xy += d / max(r, 1e-3) * (-2.0 * ring_depress * w * ring_bounce(life) * (1.0 - q) / max(R, 1e-3)) * vis;
		float band = smoothstep(R + w, R, r) * (1.0 - smoothstep(R - w, R - 3.0 * w, r));
		acc.z = max(acc.z, band * fade);
	}
	return acc;
}

// Finest cascade that covers p without minifying, blended into the next at window edges.
vec3 sample_decals(vec2 p, float footprint) {
	vec3 acc = vec3(0.0);
	for (int i = 2; i >= 0; i--) {
		vec4 c = decal_cascades[i];
		if (c.z <= 0.0) continue;
		vec2 uv = (p - c.xy) / c.z;
		vec2 m = min(uv, 1.0 - uv);
		float w = smoothstep(0.0, 0.05, min(m.x, m.y));
		if (i < 2) w *= 1.0 - smoothstep(c.w * 1.5, c.w * 3.0, footprint);
		if (w <= 0.0) continue;
		vec4 t = textureLod(foam_decals, vec3(uv, float(i)), 0.0);
		acc = mix(acc, t.rgb, w);
	}
	return acc;
}

vec2 sim_frag_slope(vec2 p, float footprint, float cell, bool is_coarse) {
	float fade = 1.0 - smoothstep(cell * 16.0, cell * 32.0, footprint);
	if (fade <= 0.0) return vec2(0.0);
	float slot = is_coarse ? tile_slot(index_tex_c, tile_world_c, grid_origin_c, p) : tile_slot(index_tex, tile_world, grid_origin, p);
	if (slot < -0.5) return vec2(0.0);
	bool lod = footprint > cell * 2.0;
	float e = lod ? cell * 4.0 : cell;
	vec2 dxv = vec2(e, 0.0), dzv = vec2(0.0, e);
	vec2 g = is_coarse
		? vec2(coarse_h(p + dxv, lod) - coarse_h(p - dxv, lod), coarse_h(p + dzv, lod) - coarse_h(p - dzv, lod))
		: vec2(fine_h(p + dxv, lod) - fine_h(p - dxv, lod), fine_h(p + dzv, lod) - fine_h(p - dzv, lod));
	return g / (2.0 * e) * fade;
}

// Bilinear over per-texel fades: interpolating raw stamp times would blend
// fresh and never-stamped texels into a meaningless age.
// x = surface foam, y = lingering bubbles under the surface.
vec2 sample_wake(vec2 wxz) {
	ivec2 cell = ivec2(floor(wxz / wake_world)) + ivec2(wake_origin);
	ivec2 sz = textureSize(wake_index, 0);
	if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, sz))) return vec2(0.0);
	float slot = texelFetch(wake_index, cell, 0).r;
	if (slot < -0.5) return vec2(0.0);
	int res = textureSize(wake_array, 0).x;
	vec2 f = fract(wxz / wake_world) * float(res) - 0.5;
	ivec2 i0 = ivec2(floor(f));
	vec2 t = f - vec2(i0);
	vec2 acc = vec2(0.0);
	for (int k = 0; k < 4; k++) {
		ivec2 o = ivec2(k & 1, k >> 1);
		vec2 v = texelFetch(wake_array, ivec3(clamp(i0 + o, ivec2(0), ivec2(res - 1)), int(slot)), 0).rg;
		// negative strength = splash foam, which lives 0.2 x wake_life (see wave.glsl)
		float life = clamp(1.0 - (wake_time - v.x) / (wake_life * (v.y < 0.0 ? 0.2 : 1.0)), 0.0, 1.0);
		float w = (o.x == 1 ? t.x : 1.0 - t.x) * (o.y == 1 ? t.y : 1.0 - t.y);
		acc += abs(v.y) * vec2(life * life * life, sqrt(life)) * w;
	}
	return acc;
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

vec3 sample_ocean_disp(vec2 wxz, float chop, float footprint, vec4 cm) {
	vec3 disp = vec3(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec2 uv = wxz / cascade_scales[i] + CASCADE_OFFSETS[i];
		float lod = max(log2(footprint * fft_size / cascade_scales[i]), 0.0);
		vec3 d  = textureLod(fft_displacement, vec3(uv, float(i)), lod).xyz;
		disp += vec3(-d.x * chop, d.y, -d.z * chop) * cascade_strength[i] * cm[i];
	}
	return disp;
}

// (slope.xz, Jxx, Jzz) summed over cascades; wc_j = Jacobian terms for whitecaps,
// mip-capped so distant crests are not averaged away. Cascades already sampled at
// or below the cap reuse that sample.
vec4 sample_ocean_derivs(vec2 wxz, vec4 cm, float footprint, out vec2 wc_j) {
	vec4 d = vec4(0.0);
	wc_j = vec2(0.0);
	for (int i = 0; i < cascade_count; i++) {
		vec3 uvw = vec3(wxz / cascade_scales[i] + CASCADE_OFFSETS[i], float(i));
		float k = cascade_strength[i] * cm[i];
		vec4 t = texture(fft_derivatives, uvw);
		d += t * k;
		float lod = log2(footprint * fft_size / cascade_scales[i]);
		wc_j += (lod <= whitecap_max_lod ? t.ba : textureLod(fft_derivatives, uvw, whitecap_max_lod).ba) * k;
	}
	return d;
}

// Equalised reveal order -> opacity; c = 0 shows nothing, c = 1 covers all.
float foam_cover(float c, float order, float edge) {
	float t = 1.0 + edge - c * (1.0 + 2.0 * edge);
	return smoothstep(t - edge, t + edge, order);
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
	v_cm = cascade_mods(s_xz);
	vec3 disp = sample_ocean_disp(s_xz, chop, footprint, v_cm) * v_calm_factor;

	disp.y += ring_count > 0 ? shock_depress(s_xz) : 0.0;
	disp.y += (sim_vertex_h(s_xz, footprint, tile_world_c / 128.0, true)
			+ sim_vertex_h(s_xz, footprint, tile_world / 128.0, false)) * wave_height_scale;

	v_wave_height = disp.y;
	v_world_xz    = s_xz;

	vec3 world = vec3(s_xz.x, 0.0, s_xz.y) + disp;
	v_surf_xz = world.xz;
	VERTEX = vec3((world.x - center.x) / cell, world.y, (world.z - center.y) / cell);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

// =====================================================================
// Fragment shader
// =====================================================================

void fragment() {
	vec4 cm = v_cm;
	vec2  fx = dFdx(v_world_xz), fy = dFdy(v_world_xz);
	float footprint = sqrt(max(length(fx) * length(fy), 1e-8));
	vec2 wc_j;
	vec4 derivs = sample_ocean_derivs(v_world_xz, cm, footprint, wc_j) * v_calm_factor;
	wc_j *= choppiness * v_calm_factor;
	float jacobian = (1.0 + wc_j.x) * (1.0 + wc_j.y);
	vec4 shock = shock_rings(v_world_xz);
	float calm_k = 1.0 - ring_flatten * shock.z;
	vec2 slope = derivs.xy * calm_k + shock.xy;

	float lk = log2(PI / footprint);
	float lost_u = clamp((lk - slope_var_range.x) / (slope_var_range.y - slope_var_range.x), 0.0, 1.0);
	float lost_var = texture(slope_var_tex, vec2(lost_u, 0.5)).r * v_calm_factor * v_calm_factor * calm_k * calm_k;

	slope += (sim_frag_slope(v_world_xz, footprint, tile_world_c / 128.0, true)
			+ sim_frag_slope(v_world_xz, footprint, tile_world / 128.0, false)) * wave_height_scale;

	vec3 world_n = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	// ---- coverage sources ----
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4  vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float water_depth = -(vp.z / vp.w) + VERTEX.z;
	float shore_c = 1.0 - clamp(water_depth / foam_band, 0.0, 1.0);

	float wc_core = (1.0 - smoothstep(whitecap_j_low, whitecap_j_high, jacobian)) * calm_k;
	float wc_lace = (1.0 - smoothstep(whitecap_j_high, whitecap_residual, jacobian)) * calm_k;
	vec2 wake = sample_wake(v_world_xz);
	float cover = clamp(max(max(wc_core, wc_lace * 0.3), shore_c) * foam_amount, 0.0, 1.0);
	float churn_c = clamp(wake.x * foam_amount, 0.0, 1.0);
	vec3 decal = sample_decals(v_world_xz, footprint);
	float sub = clamp(max(max(wc_lace * wc_lace, max(wake.y, decal.y)), shock.w * 0.5) * foam_amount, 0.0, 1.0);

	// ---- foam texture; widen the edge as the lace drops below a pixel so far foam reads as coverage ----
	vec2 drift = wind_dir * TIME * foam_drift;
	vec2 uv_a = (v_world_xz - drift) / foam_tex_scale;
	vec2 uv_b = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * (v_world_xz - drift * 1.3) / foam_detail_scale;
	float fa = texture(foam_tex, uv_a).r;
	vec3 fb = texture(foam_tex, uv_b).rgb;
	float order = clamp(fa + (fb.r - 0.5) * 0.35, 0.0, 1.0);
	float tex_lod = log2(footprint * float(textureSize(foam_tex, 0).x) / foam_detail_scale);
	float edge = mix(foam_edge, 0.5, clamp(tex_lod / 5.0, 0.0, 1.0));
	float foam = foam_cover(cover, order, edge);
	vec2 uv_c = mat2(vec2(0.6, -0.8), vec2(0.8, 0.6)) * (v_world_xz - drift) / churn_tex_scale;
	float churn = clamp(texture(foam_tex, uv_c).b + (fb.b - 0.5) * 0.1, 0.0, 1.0);
	float churn_lod = log2(footprint * float(textureSize(foam_tex, 0).x) / churn_tex_scale);
	float edge_c = mix(churn_edge, 0.5, clamp(churn_lod / 5.0, 0.0, 1.0));
	float churn_foam = foam_cover(churn_c, churn, edge_c);
	// Thin churn edges stay translucent so clumps read as piled-up froth.
	float thick = smoothstep(0.0, 0.35, churn - (1.0 - churn_c));
	foam = max(foam, churn_foam * mix(0.7, 1.0, thick));
	float margin = decal.x * 2.0 - 1.0 - (1.0 - foam_amount);
	// Zero coverage sits at margin <= -churn_edge, so widening the edge never lifts empty decal rims.
	float decal_foam = smoothstep(0.0, 2.0 * edge_c, margin + churn_edge) * mix(0.7, 1.0, smoothstep(0.0, 0.35, margin));
	decal_foam = min(decal_foam * (1.0 + 2.0 * decal.z), 1.0);
	// 2.3 m detail tint suits lace only; decal foam stays flat.
	float detail = mix(1.0, 0.8 + 0.2 * fb.b, smoothstep(-0.1, 0.1, foam - decal_foam));
	foam = max(foam, decal_foam);

	// ---- water body: crests lighter than troughs, bubbles tint below the surface ----
	float view_up = clamp((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).y, 0.0, 1.0);
	float crest = clamp(v_wave_height / crest_height, 0.0, 1.0) * v_calm_factor
			* pow(1.0 - view_up, crest_view_falloff);
	float depth_blend = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec3 water = mix(shallow, deep, depth_blend);
	water = mix(water, scatter_color, crest * crest * crest_ambient);
	water = mix(water, bubble_color, sub * (1.0 - foam) * 0.5);

	// Blast disk: smooth frosted whitening, no lace (uniform low lace coverage reads as a dot grid).
	water *= 1.0 - ring_darken * shock.z;
	water = mix(water, foam_color, shock.w * ring_foam * (1.0 - foam));
	ALBEDO = mix(water, foam_color * detail, foam);
	METALLIC = 0.0;
	// F0(specular) = 0.16 * specular^2 in Godot's IBL; match water_specular.
	SPECULAR = mix(sqrt(water_specular / 0.16), 0.5, foam);
	float base_rough = mix(mix(calm_roughness, water_roughness, v_calm_factor), foam_roughness, foam);
	float alpha = sqrt(pow(base_rough, 4.0) + lost_var);
	ROUGHNESS = sqrt(alpha);
	vec2 rad = v_surf_xz - CAMERA_POSITION_WORLD.xz;
	float gb = atan(rad.y, rad.x) * (GLINT_BINS / TAU);
	float gb0 = floor(gb);
	vec2 sfx = dFdx(v_surf_xz), sfy = dFdy(v_surf_xz);
	vec4 gu0, ge0, gu1, ge1;
	glint_lattice(v_surf_xz, sfx, sfy, gb0, gu0, ge0);
	glint_lattice(v_surf_xz, sfx, sfy, gb0 + 1.0, gu1, ge1);
	f_glint_u0 = gu0;
	f_glint_u1 = gu1;
	f_glint_e0 = ge0 * (1.0 - (gb - gb0));
	f_glint_e1 = ge1 * (gb - gb0);
	float fmaj = max(dot(fx, fx), dot(fy, fy));
	float elong = fmaj / max(abs(fx.x * fy.y - fx.y * fy.x), 1e-8);
	float cam_down = asin(clamp(INV_VIEW_MATRIX[2].y, 0.0, 1.0)) / (PI * 0.5);
	f_glint_density = glint_density * mix(1.0, glint_density_down, cam_down);
	f_glint_w = lost_var / max(lost_var + glint_var_ref, 1e-8) * (1.0 - smoothstep(glint_aniso_fade.x, glint_aniso_fade.y, elong));
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
		vec3 raw = sun * spec * sun_glint;
		vec3 smooth_spec = specular_max * (1.0 - exp(-raw / specular_max));
		// Each lit cell carries the energy of 1/p cells, so sparkle brightness is flat across the lobe.
		float lobe = D * PI * alpha2;
		float p = max(1.0 - exp(-f_glint_density * lobe), 1e-4);
		float soft = 0.2 * p + 0.01;
		float lit = dot(clamp((p - f_glint_u0) / soft + 0.5, 0.0, 1.0), f_glint_e0)
				+ dot(clamp((p - f_glint_u1) / soft + 0.5, 0.0, 1.0), f_glint_e1);
		// Tail sparkles dimmed: at full brightness they read as a starfield off the sun path.
		vec3 sparkle = glint_max * (1.0 - exp(-raw / (p * glint_max))) * lit * pow(lobe, glint_tail);
		SPECULAR_LIGHT += mix(smooth_spec, sparkle, f_glint_w) * water;
	}
}
