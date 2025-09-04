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
uniform float particle_spacing = 10.0; // Base spacing between particles
uniform sampler2D alpha_over_lifetime_texture : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform bool use_alpha_over_lifetime = true;

// Varying to pass particle lifetime from vertex to fragment shader
varying float particle_lifetime;
// Varying to pass width scale for debug coloring
varying float width_scale_debug;

void vertex() {
    UV = UV * uv1_scale.xy + uv1_offset.xy;

    // Extract the current particle scale (assuming uniform scaling)
    float particle_scale = length(MODEL_MATRIX[1].xyz) / 5.0; // Normalize by original height

    // Get the vertex position in model space
    vec3 vertex_local = VERTEX;

    // Adjust the y-coordinate based on scale to prevent overlap
    // Map UV.y from [0,1] to [-0.5,0.5] to work with the center of the particle
    float local_y_offset = (UV.y - 0.5);

    // Create a modified local vertex position with corrected y-scaling
    // Keep x and z scaling as is, but adjust y to maintain proper spacing
    vertex_local.y = vertex_local.y * (particle_spacing / 5.0);

    // Get the particle's model matrix which has y aligned to velocity
    mat4 particle_matrix = MODEL_MATRIX;

    // Extract the y-axis (already aligned to velocity)
    vec3 y_axis = normalize(particle_matrix[1].xyz);

    // Get camera direction
    vec3 to_camera = normalize(INV_VIEW_MATRIX[3].xyz - particle_matrix[3].xyz);

    // Project camera direction onto plane perpendicular to y_axis
    vec3 to_camera_projected = normalize(to_camera - dot(to_camera, y_axis) * y_axis);

    // Calculate the x-axis perpendicular to y_axis and camera direction
    vec3 x_axis = normalize(cross(y_axis, to_camera_projected));

    // Calculate z-axis to complete orthonormal basis
    vec3 z_axis = normalize(cross(x_axis, y_axis));

    // Create orientation matrix that faces camera while keeping y aligned to velocity
    mat4 orient_matrix = mat4(
        vec4(x_axis, 0.0),
        vec4(y_axis, 0.0),
        vec4(z_axis, 0.0),
        vec4(0.0, 0.0, 0.0, 1.0)
    );

    // Apply scaling - use COLOR.x for width scaling
    mat4 scale_matrix = mat4(
        vec4(length(MODEL_MATRIX[0].xyz) * COLOR.x, 0.0, 0.0, 0.0), // Width scaling from COLOR.x
        vec4(0.0, particle_spacing, 0.0, 0.0), // Use constant spacing for height
        vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz) * COLOR.x, 0.0), // Width scaling also for z
        vec4(0.0, 0.0, 0.0, 1.0)
    );

    // Pass width scale value to fragment shader for debug coloring
    width_scale_debug = COLOR.x;

    // Create world matrix that preserves position but uses our custom orientation and scaling
    mat4 mat_world = mat4(
        vec4(orient_matrix[0].xyz, 0.0),
        vec4(orient_matrix[1].xyz, 0.0),
        vec4(orient_matrix[2].xyz, 0.0),
        MODEL_MATRIX[3]
    ) * scale_matrix;

    // Apply particle rotation around its y-axis
    mat_world = mat_world * mat4(
        vec4(cos(INSTANCE_CUSTOM.x), 0.0, -sin(INSTANCE_CUSTOM.x), 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(sin(INSTANCE_CUSTOM.x), 0.0, cos(INSTANCE_CUSTOM.x), 0.0),
        vec4(0.0, 0.0, 0.0, 1.0)
    );


    // Set the modelview matrix
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

    // Pass particle lifetime to fragment shader
    // INSTANCE_CUSTOM.y contains the normalized particle age (0.0 to 1.0)
    particle_lifetime = INSTANCE_CUSTOM.y;
}

void fragment() {
    vec2 base_uv = UV;
    vec4 albedo_tex = texture(texture_albedo, base_uv);

    // Create debug color based on width scale value (0-10 range)
    // Red component: width / 10 (0 = no red, 10 = full red)
    // Blue component: 1 - (width / 10) (0 = full blue, 10 = no blue)
    // float normalized_width = clamp(width_scale_debug / 10.0, 0.0, 1.0);
    // float red_component = normalized_width;
    // float blue_component = 1.0 - normalized_width;
    // vec3 debug_color = vec3(red_component, 0.0, blue_component);

    // Mix debug color with albedo
    ALBEDO = albedo.rgb * albedo_tex.rgb;// * debug_color;

    // Calculate alpha based on particle lifetime
    // particle_lifetime contains the normalized particle age (0.0 to 1.0) from vertex shader
    float particle_age = particle_lifetime;

    float life_alpha = 1.0;
    if (use_alpha_over_lifetime) {
        // Sample the alpha over lifetime texture using particle age as UV.x coordinate
        // The texture should be a 1D gradient where x represents time (0=birth, 1=death)
        vec2 lifetime_uv = vec2(particle_age, 0.5);
        life_alpha = texture(alpha_over_lifetime_texture, lifetime_uv).r;
    } else {
        // Fallback to simple linear fade out
        life_alpha = min(1.0 - particle_age, 0.08);
    }

    float metallic_tex = dot(texture(texture_metallic, base_uv), metallic_texture_channel);
    METALLIC = metallic_tex * metallic;
    SPECULAR = specular;
    vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
    float roughness_tex = dot(texture(texture_roughness, base_uv), roughness_texture_channel);
    ROUGHNESS = roughness_tex * roughness;

    // Apply calculated alpha based on lifetime
    ALPHA = albedo.a * albedo_tex.a * life_alpha;
}