shader_type spatial;
render_mode blend_mix, depth_draw_always, specular_schlick_ggx;

// xy = direction, z = steepness (0..1), w = wavelength
//uniform vec4 wave_a = vec4(1.0, 0.0, 0.25, 60.0);
//uniform vec4 wave_b = vec4(0.7, 0.7, 0.25, 31.0);
//uniform vec4 wave_c = vec4(-0.8, 0.3, 0.20, 18.0);
uniform vec4 waves[3];   // replaces wave_a / wave_b / wave_c
uniform float wave_time = 0.0;   // set from CPU; see buoyancy note

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3 shallow : source_color = vec3(0.10, 0.40, 0.50);
uniform vec3 deep    : source_color = vec3(0.02, 0.08, 0.15);
uniform float depth_fade = 8.0;
uniform float foam_band  = 0.5;

vec3 gerstner(vec4 wave, vec3 p, inout vec3 tangent, inout vec3 binormal) {
	float k = TAU / wave.w;
	float c = sqrt(9.8 / k);
	vec2 d = normalize(wave.xy);
	float f = k * (dot(d, p.xz) - c * wave_time);
	float a = wave.z / k;

	tangent  += vec3(-d.x*d.x*(wave.z*sin(f)),  d.x*(wave.z*cos(f)), -d.x*d.y*(wave.z*sin(f)));
	binormal += vec3(-d.x*d.y*(wave.z*sin(f)),  d.y*(wave.z*cos(f)), -d.y*d.y*(wave.z*sin(f)));
	return vec3(d.x*(a*cos(f)), a*sin(f), d.y*(a*cos(f)));
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

	vec3 sample_pos = vec3(s_xz.x, 0.0, s_xz.y);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	vec3 disp = vec3(0.0);
	for (int i = 0; i < 3; i++)
		disp += gerstner(waves[i], sample_pos, tangent, binormal);

	vec3 final_world = vec3(s_xz.x, VERTEX.y, s_xz.y) + disp;
	VERTEX = final_world - m_origin;   // back to local (mesh only translates)
	NORMAL = normalize(cross(binormal, tangent));
}

void fragment() {
    float d = texture(depth_tex, SCREEN_UV).r;
    vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
    float scene_z = -(v.z / v.w);
    float water_depth = scene_z - (-VERTEX.z);  // VERTEX is view-space here

    float blend = clamp(water_depth / depth_fade, 0.0, 1.0);
    float foam  = 1.0 - clamp(water_depth / foam_band, 0.0, 1.0);

    ALBEDO = mix(mix(shallow, deep, blend), vec3(1.0), foam);
    METALLIC = 0.0;
    ROUGHNESS = 0.02;
    SPECULAR = 0.6;
    //ALPHA = 1.0;   // stays visually opaque; just moves it to the transparent pass

}