shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded;

// Texture array containing all particle textures
uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;

// Color ramp atlas - 2D texture where each row is a template's gradient
// Width = CURVE_RESOLUTION (256), Height = MAX_TEMPLATES
uniform sampler2D color_ramp_atlas : source_color, filter_linear_mipmap;

// Alpha settings
uniform bool use_alpha_scissor = false;
uniform float alpha_scissor_threshold = 0.5;

// Varying to pass template_id from vertex to fragment
// Note: template_id is encoded in COLOR.r at emission time
varying flat int template_id;
varying float lifetime_percent;

void vertex() {
	// Extract template_id from COLOR.r (encoded at emission time)
	// Decode from normalized float (0.0-1.0) back to int (0-255)
	template_id = int(COLOR.r * 255.0 + 0.5);

	// Extract particle age and lifetime from INSTANCE_CUSTOM
	// CUSTOM.x = particle_lifetime (total lifetime in seconds)
	// CUSTOM.y = particle_age (current age in seconds)
	float particle_lifetime = INSTANCE_CUSTOM.w;
	float particle_age = INSTANCE_CUSTOM.y;

	// Calculate normalized lifetime (0.0 = just born, 1.0 = end of life)
	lifetime_percent = clamp(particle_age / max(particle_lifetime, 0.001), 0.0, 1.0);

	float size = COLOR.g;

	// Manual billboarding for particles
	// Make the particle always face the camera

	// Get camera right and up vectors in world space from INV_VIEW_MATRIX
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	vec3 camera_forward = normalize(INV_VIEW_MATRIX[2].xyz);

	// Extract and preserve scale from original MODEL_MATRIX
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);

	// Build billboard matrix in world space
	mat4 mat_world = mat4(1.0);
	mat_world[0].xyz = camera_right * scale_x * size;
	mat_world[1].xyz = camera_up * scale_y * size;
	mat_world[2].xyz = camera_forward * scale_z * size;
	mat_world[3] = MODEL_MATRIX[3]; // Preserve position

	MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
}

void fragment() {
	// Sample texture from array using template_id as layer index
	int texture_index = int(template_id);
	vec4 tex_color = texture(texture_atlas, vec3(UV, float(texture_index)));

	// Sample color ramp based on particle lifetime
	// U coordinate = lifetime_percent (0.0 to 1.0 across the gradient)
	// V coordinate = template_id normalized to row in atlas
	float v_coord = (float(template_id) + 0.5) / 16.0; // 16 = MAX_TEMPLATES
	vec4 ramp_color = texture(color_ramp_atlas, vec2(lifetime_percent, v_coord));

	// Combine texture with color ramp
	vec4 final_color = tex_color * ramp_color;

	// Fade out at end of life to prevent flashing
	float fade_start = 0.95;
	float alpha_fade = 1.0;
	if (lifetime_percent > fade_start) {
		alpha_fade = 1.0 - ((lifetime_percent - fade_start) / (1.0 - fade_start));
	}

	ALBEDO = final_color.rgb;
	ALPHA = final_color.a * alpha_fade;

	// Alpha scissor for performance
	if (use_alpha_scissor && ALPHA < alpha_scissor_threshold) {
		discard;
	}

	// // Emission for bright particles (optional, based on COLOR intensity)
	// if (length(COLOR.rgb) > 1.0) {
	// 	EMISSION = ALBEDO * (length(COLOR.rgb) - 1.0);
	// }
}
