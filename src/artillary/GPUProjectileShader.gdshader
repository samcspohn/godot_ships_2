// GPU-based projectile rendering shader
// Reads positions from a texture updated by the CPU each frame
// Shell data is passed via a data texture where each row contains one shell's parameters

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, unshaded;

// Visual parameters
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform float point_size : hint_range(0.1, 128.0, 0.1) = 1.0;

// Position texture: each row = 1 shell
// Pixel 0 (RGBA): current_position.xyz, active (0/1)
uniform sampler2D shell_position_texture : filter_nearest;

// Data texture: each row = 1 shell
// Pixel 0 (RGBA): color.rgba
// Pixel 1 (RGBA): size, shell_type (0=HE, 1=AP), reserved, reserved
uniform sampler2D shell_data_texture : filter_nearest;
uniform int texture_width = 2; // 2 pixels per shell (for data)
uniform int max_shells = 1024;

// Output to fragment
varying flat float scale_distance_factor;
varying flat vec4 shell_color;
varying flat float is_active;

void vertex() {
	// Get shell index from instance ID
	int shell_id = INSTANCE_ID;

	// Calculate texture coordinates for this shell's data
	float tex_y = (float(shell_id) + 0.5) / float(max_shells);

	// Read position from position texture
	// Pixel 0: current_position.xyz, active
	vec4 pos_data = texture(shell_position_texture, vec2(0.5, tex_y));

	vec3 world_pos = pos_data.xyz;
	is_active = pos_data.w;

	// Read shell data from data texture
	// Pixel 0: color.rgba
	vec4 data0 = texture(shell_data_texture, vec2(0.25, tex_y)); // 0.5/2 = 0.25
	// Pixel 1: size, shell_type, reserved, reserved
	vec4 data1 = texture(shell_data_texture, vec2(0.75, tex_y)); // 1.5/2 = 0.75

	shell_color = data0;
	float shell_size = data1.x;

	// Ensure shell_color has reasonable values (fallback if texture read fails)
	if (shell_color.a < 0.01) {
		shell_color = vec4(1.0, 1.0, 1.0, 1.0); // Default white
	}

	// Ensure shell_size is reasonable
	if (shell_size < 0.1) {
		shell_size = 1.0; // Default size
	}

	// If shell is inactive (destroyed or not yet fired), move it far away
	if (is_active < 0.5) {
		world_pos = vec3(0.0, -1000000.0, 0.0);
	}

	// Apply UV transformation
	UV = UV;

	// Billboard Mode: Face camera
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			MAIN_CAM_INV_VIEW_MATRIX[0],
			MAIN_CAM_INV_VIEW_MATRIX[1],
			MAIN_CAM_INV_VIEW_MATRIX[2],
			vec4(world_pos, 1.0));

	// Calculate FOV-based distance scaling
	float fov_y = 2.0 * atan(1.0 / PROJECTION_MATRIX[1][1]);
	float dist = length(MAIN_CAM_INV_VIEW_MATRIX[3].xyz - world_pos);
	scale_distance_factor = 1.5 + dist * 0.0002 * -fov_y;

	// Apply scale (billboard keep scale)
	float final_scale = shell_size * scale_distance_factor;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(final_scale, 0.0, 0.0, 0.0),
			vec4(0.0, final_scale, 0.0, 0.0),
			vec4(0.0, 0.0, final_scale, 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));

	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 base_uv = UV;
	vec4 albedo_tex = texture(texture_albedo, base_uv);

	// Apply distance-based brightness boost (like original shader)
	albedo_tex.rgb *= scale_distance_factor;

	// Shell color replaces the per-instance COLOR from the original shader
	// Multiply texture by shell color (this is how original shader did it)
	albedo_tex *= shell_color;

	// Final color: albedo uniform * texture (matches original shader exactly)
	ALBEDO = albedo.rgb * albedo_tex.rgb;

	// Use alpha from texture, but ensure inactive shells are hidden
	float active_alpha = is_active > 0.5 ? 1.0 : 0.0;
	ALPHA = albedo.a * albedo_tex.a * active_alpha;

	// Discard fully transparent pixels
	if (ALPHA < 0.01) {
		discard;
	}
}
