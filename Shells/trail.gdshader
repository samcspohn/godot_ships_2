// NOTE: Shader automatically converted from Godot Engine 4.4.stable's StandardMaterial3D.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx, unshaded;
uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform ivec2 albedo_texture_size;
uniform float point_size : hint_range(0.1, 128.0, 0.1);
uniform float roughness : hint_range(0.0, 1.0);
uniform sampler2D texture_metallic : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 metallic_texture_channel;
uniform sampler2D texture_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform float specular : hint_range(0.0, 1.0, 0.01);
uniform float metallic : hint_range(0.0, 1.0, 0.01);
uniform int particles_anim_h_frames : hint_range(1, 128);
uniform int particles_anim_v_frames : hint_range(1, 128);
uniform bool particles_anim_loop;
uniform vec3 uv1_scale;
uniform vec3 uv1_offset;
uniform vec3 uv2_scale;
uniform vec3 uv2_offset;

void vertex() {
    UV = UV * uv1_scale.xy + uv1_offset.xy;

    // Extract the scale factor from INSTANCE_CUSTOM
    // Assuming INSTANCE_CUSTOM.w contains the scale curve value
    float scale_factor = INSTANCE_CUSTOM.w;

    // Get the particle's model matrix with y aligned to velocity
    mat4 particle_matrix = MODEL_MATRIX;

    // Extract the current y-axis (velocity direction)
    vec3 y_axis = normalize(particle_matrix[1].xyz);

    // Get the vector from particle to camera
    vec3 to_camera = normalize(INV_VIEW_MATRIX[3].xyz - particle_matrix[3].xyz);

    // Project to_camera onto the plane perpendicular to y_axis
    vec3 to_camera_projected = normalize(to_camera - dot(to_camera, y_axis) * y_axis);

    // Calculate the x-axis perpendicular to both y_axis and to_camera_projected
    vec3 x_axis = normalize(cross(y_axis, to_camera_projected));

    // Calculate the z-axis to complete the orthonormal basis
    vec3 z_axis = normalize(cross(x_axis, y_axis));

    // Calculate the x and z scales (for width)
    float x_scale = length(MODEL_MATRIX[0].xyz);
    float z_scale = length(MODEL_MATRIX[2].xyz);

    // Calculate original y scale (height)
    float y_scale = length(MODEL_MATRIX[1].xyz);

    // Adjust y scale based on scale_factor to prevent overlap
    // If scale_factor increases, y scale should decrease proportionally
    // to maintain the same overall trail length
    float adjusted_y_scale = y_scale;
    if (scale_factor > 0.0) {
        // Adjust y scale inversely proportional to scale_factor
        // This ensures particles maintain contiguous trail without overlap
        adjusted_y_scale = y_scale / scale_factor;
    }

    // Create the orientation matrix
    mat4 orient_matrix = mat4(
        vec4(x_axis * x_scale, 0.0),
        vec4(y_axis * adjusted_y_scale, 0.0),
        vec4(z_axis * z_scale, 0.0),
        particle_matrix[3]
    );

    // Apply the particle's own rotation around its y-axis
    mat4 mat_world = orient_matrix * mat4(
        vec4(cos(INSTANCE_CUSTOM.x), 0.0, -sin(INSTANCE_CUSTOM.x), 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(sin(INSTANCE_CUSTOM.x), 0.0, cos(INSTANCE_CUSTOM.x), 0.0),
        vec4(0.0, 0.0, 0.0, 1.0));

    MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
    MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);

    // Animation (unchanged)
    float h_frames = float(particles_anim_h_frames);
    float v_frames = float(particles_anim_v_frames);
    float particle_total_frames = float(particles_anim_h_frames * particles_anim_v_frames);
    float particle_frame = floor(INSTANCE_CUSTOM.z * float(particle_total_frames));
    if (!particles_anim_loop) {
        particle_frame = clamp(particle_frame, 0.0, particle_total_frames - 1.0);
    } else {
        particle_frame = mod(particle_frame, particle_total_frames);
    }
    UV /= vec2(h_frames, v_frames);
    UV += vec2(mod(particle_frame, h_frames) / h_frames, floor((particle_frame + 0.5) / h_frames) / v_frames);
}

void fragment() {
    vec2 base_uv = UV;
    vec4 albedo_tex = texture(texture_albedo, base_uv);
    // Vertex Color Use as Albedo: Enabled
    albedo_tex *= COLOR;
    ALBEDO = albedo.rgb * albedo_tex.rgb;
    float metallic_tex = dot(texture(texture_metallic, base_uv), metallic_texture_channel);
    METALLIC = metallic_tex * metallic;
    SPECULAR = specular;
    vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
    float roughness_tex = dot(texture(texture_roughness, base_uv), roughness_texture_channel);
    ROUGHNESS = roughness_tex * roughness;
    ALPHA *= albedo.a * albedo_tex.a;
}