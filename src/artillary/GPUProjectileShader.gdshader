// GPU-based projectile rendering shader
// Calculates positions analytically on GPU, eliminating CPU-GPU data transfer bottleneck
// Shell data is passed via a data texture where each row contains one shell's parameters

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, unshaded;

// Visual parameters
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform float point_size : hint_range(0.1, 128.0, 0.1) = 1.0;

// Physics constants
uniform float gravity : hint_range(0.0, 20.0) = 9.8;
uniform float shell_time_multiplier : hint_range(0.1, 5.0) = 1.5;

// Data texture: each row = 1 shell
// Pixel 0 (RGBA): start_position.xyz, start_time
// Pixel 1 (RGBA): launch_velocity.xyz, drag_coefficient
// Pixel 2 (RGBA): color.rgba
// Pixel 3 (RGBA): size, shell_type (0=HE, 1=AP), active (0/1), reserved
uniform sampler2D shell_data_texture : filter_nearest;
uniform int texture_width = 4; // 4 pixels per shell (for data)
uniform int max_shells = 256;

// Current time from game
uniform float current_time = 0.0;

// Output to fragment
varying flat float scale_distance_factor;
varying flat vec4 shell_color;
varying flat float is_active;

// Analytical position calculation with drag (matches ProjectilePhysicsWithDrag.calculate_position_at_time)
vec3 calculate_position_at_time(vec3 start_pos, vec3 launch_velocity, float time, float drag_coefficient) {
	if (time <= 0.0) {
		return start_pos;
	}
	
	float beta = drag_coefficient;
	float g = gravity;
	
	// drag_factor = 1 - e^(-beta * time)
	float drag_factor = 1.0 - exp(-beta * time);
	
	vec3 position;
	// Horizontal: x = start + (v0 / beta) * (1 - e^(-beta*t))
	position.x = start_pos.x + (launch_velocity.x / beta) * drag_factor;
	position.z = start_pos.z + (launch_velocity.z / beta) * drag_factor;
	
	// Vertical: y = start + (v0y/beta) * drag_factor - (g/beta)*t + (g/beta^2)*drag_factor
	position.y = start_pos.y + (launch_velocity.y / beta) * drag_factor 
				 - (g / beta) * time 
				 + (g / (beta * beta)) * drag_factor;
	
	return position;
}

void vertex() {
	// Get shell index from instance ID
	int shell_id = INSTANCE_ID;
	
	// Calculate texture coordinates for this shell's data
	float tex_y = (float(shell_id) + 0.5) / float(max_shells);
	
	// Read shell data from texture
	// Pixel 0: start_position.xyz, start_time
	vec4 data0 = texture(shell_data_texture, vec2(0.125, tex_y)); // 0.5/4 = 0.125
	// Pixel 1: launch_velocity.xyz, drag_coefficient  
	vec4 data1 = texture(shell_data_texture, vec2(0.375, tex_y)); // 1.5/4 = 0.375
	// Pixel 2: color.rgba
	vec4 data2 = texture(shell_data_texture, vec2(0.625, tex_y)); // 2.5/4 = 0.625
	// Pixel 3: size, shell_type, active, reserved
	vec4 data3 = texture(shell_data_texture, vec2(0.875, tex_y)); // 3.5/4 = 0.875
	
	vec3 start_position = data0.xyz;
	float start_time = data0.w;
	vec3 launch_velocity = data1.xyz;
	float drag_coefficient = data1.w;
	shell_color = data2;
	float shell_size = data3.x;
	is_active = data3.z;
	
	// Ensure shell_color has reasonable values (fallback if texture read fails)
	if (shell_color.a < 0.01) {
		shell_color = vec4(1.0, 1.0, 1.0, 1.0); // Default white
	}
	
	// Ensure shell_size is reasonable
	if (shell_size < 0.1) {
		shell_size = 1.0; // Default size
	}
	
	// Ensure drag coefficient is valid (avoid division by zero)
	if (drag_coefficient < 0.001) {
		drag_coefficient = 0.009; // Default drag
	}
	
	// Calculate time since launch
	float t = (current_time - start_time) * shell_time_multiplier;
	
	// Calculate current position
	vec3 world_pos = calculate_position_at_time(start_position, launch_velocity, t, drag_coefficient);
	
	// If shell is inactive (destroyed or not yet fired), move it far away
	if (is_active < 0.5 || t < 0.0) {
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
	scale_distance_factor = 1.0 + dist * 0.00025 * -fov_y;
	
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
