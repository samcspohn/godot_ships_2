#include "projectile_manager.h"
#include "projectile_physics_with_drag.h"
#include "ship.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/scene_tree_timer.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/gd_script.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/stream_peer_buffer.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <cmath>

using namespace godot;

// ============================================================================
// ProjectileData Implementation
// ============================================================================

ProjectileData::ProjectileData() {
    position = Vector3();
    start_position = Vector3();
    start_time = 0.0;
    launch_velocity = Vector3();
    trail_pos = Vector3();
    owner = nullptr;
    frame_count = 0;
}

ProjectileData::~ProjectileData() {
}

void ProjectileData::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "pos", "vel", "t", "p", "_owner", "_exclude"), &ProjectileData::initialize, DEFVAL(TypedArray<Ship>()));

    ClassDB::bind_method(D_METHOD("get_position"), &ProjectileData::get_position);
    ClassDB::bind_method(D_METHOD("set_position", "pos"), &ProjectileData::set_position);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");

    ClassDB::bind_method(D_METHOD("get_start_position"), &ProjectileData::get_start_position);
    ClassDB::bind_method(D_METHOD("set_start_position", "pos"), &ProjectileData::set_start_position);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_position"), "set_start_position", "get_start_position");

    ClassDB::bind_method(D_METHOD("get_start_time"), &ProjectileData::get_start_time);
    ClassDB::bind_method(D_METHOD("set_start_time", "time"), &ProjectileData::set_start_time);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "start_time"), "set_start_time", "get_start_time");

    ClassDB::bind_method(D_METHOD("get_launch_velocity"), &ProjectileData::get_launch_velocity);
    ClassDB::bind_method(D_METHOD("set_launch_velocity", "vel"), &ProjectileData::set_launch_velocity);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "launch_velocity"), "set_launch_velocity", "get_launch_velocity");

    ClassDB::bind_method(D_METHOD("get_params"), &ProjectileData::get_params);
    ClassDB::bind_method(D_METHOD("set_params", "params"), &ProjectileData::set_params);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "params", PROPERTY_HINT_RESOURCE_TYPE, "Resource"), "set_params", "get_params");

    ClassDB::bind_method(D_METHOD("get_trail_pos"), &ProjectileData::get_trail_pos);
    ClassDB::bind_method(D_METHOD("set_trail_pos", "pos"), &ProjectileData::set_trail_pos);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "trail_pos"), "set_trail_pos", "get_trail_pos");

    ClassDB::bind_method(D_METHOD("get_owner"), &ProjectileData::get_owner);
    ClassDB::bind_method(D_METHOD("set_owner", "owner"), &ProjectileData::set_owner);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "owner", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_owner", "get_owner");

    ClassDB::bind_method(D_METHOD("get_frame_count"), &ProjectileData::get_frame_count);
    ClassDB::bind_method(D_METHOD("set_frame_count", "count"), &ProjectileData::set_frame_count);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_count"), "set_frame_count", "get_frame_count");

    ClassDB::bind_method(D_METHOD("get_exclude"), &ProjectileData::get_exclude);
    ClassDB::bind_method(D_METHOD("set_exclude", "exclude"), &ProjectileData::set_exclude);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "exclude"), "set_exclude", "get_exclude");
}

void ProjectileData::initialize(const Vector3& pos, const Vector3& vel, double t, const Ref<Resource>& p, Ship* _owner, const TypedArray<Ship>& _exclude) {
    position = pos;
    start_position = pos;
    trail_pos = pos + vel.normalized() * 25.0;
    params = p;
    start_time = t;
    launch_velocity = vel;
    owner = _owner;
    frame_count = 0;
    exclude = _exclude;
}

// ============================================================================
// ShellData Implementation
// ============================================================================

ShellData::ShellData() {
    velocity = Vector3();
    position = Vector3();
    end_position = Vector3();
    fuse = 0.0;
    hit_result = 0;
}

ShellData::~ShellData() {
}

void ShellData::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_params"), &ShellData::get_params);
    ClassDB::bind_method(D_METHOD("set_params", "params"), &ShellData::set_params);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "params", PROPERTY_HINT_RESOURCE_TYPE, "Resource"), "set_params", "get_params");

    ClassDB::bind_method(D_METHOD("get_velocity"), &ShellData::get_velocity);
    ClassDB::bind_method(D_METHOD("set_velocity", "vel"), &ShellData::set_velocity);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "velocity"), "set_velocity", "get_velocity");

    ClassDB::bind_method(D_METHOD("get_position"), &ShellData::get_position);
    ClassDB::bind_method(D_METHOD("set_position", "pos"), &ShellData::set_position);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");

    ClassDB::bind_method(D_METHOD("get_end_position"), &ShellData::get_end_position);
    ClassDB::bind_method(D_METHOD("set_end_position", "pos"), &ShellData::set_end_position);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "end_position"), "set_end_position", "get_end_position");

    ClassDB::bind_method(D_METHOD("get_fuse"), &ShellData::get_fuse);
    ClassDB::bind_method(D_METHOD("set_fuse", "fuse"), &ShellData::set_fuse);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fuse"), "set_fuse", "get_fuse");

    ClassDB::bind_method(D_METHOD("get_hit_result"), &ShellData::get_hit_result);
    ClassDB::bind_method(D_METHOD("set_hit_result", "result"), &ShellData::set_hit_result);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "hit_result"), "set_hit_result", "get_hit_result");

    // Utility method
    ClassDB::bind_method(D_METHOD("get_speed"), &ShellData::get_speed);
}

// ============================================================================
// ProjectileManager Implementation
// ============================================================================

ProjectileManager::ProjectileManager() {
    UtilityFunctions::print("=== ProjectileManager C++ CONSTRUCTOR called ===");
    shell_time_multiplier = 2.0;
    nextId = 0;
    bulletId = 0;
    particles = nullptr;
    multi_mesh = nullptr;
    gpu_renderer = nullptr;
    use_gpu_renderer = true;
    _compute_particle_system = nullptr;
    _trail_template_id = -1;
    use_compute_trails = true;
    camera = nullptr;
    onready_initialized = false;

    ray_query.instantiate();
    mesh_ray_query.instantiate();

    transforms.resize(16);
    projectiles.resize(1);
    colors.resize(1);
}

ProjectileManager::~ProjectileManager() {
}

void ProjectileManager::_bind_methods() {
    // Bind enum - must match ArmorInteraction.gd HitResult
    BIND_ENUM_CONSTANT(PENETRATION);
    BIND_ENUM_CONSTANT(PARTIAL_PEN);
    BIND_ENUM_CONSTANT(RICOCHET);
    BIND_ENUM_CONSTANT(OVERPENETRATION);
    BIND_ENUM_CONSTANT(SHATTER);
    BIND_ENUM_CONSTANT(CITADEL);
    BIND_ENUM_CONSTANT(CITADEL_OVERPEN);
    BIND_ENUM_CONSTANT(WATER);
    BIND_ENUM_CONSTANT(TERRAIN);

    // Bind static methods
    ClassDB::bind_static_method("ProjectileManager", D_METHOD("next_pow_of_2", "value"), &ProjectileManager::next_pow_of_2);
    ClassDB::bind_static_method("ProjectileManager", D_METHOD("transform_to_packed_float32array", "transform"), &ProjectileManager::transform_to_packed_float32array);
    ClassDB::bind_static_method("ProjectileManager", D_METHOD("calculate_penetration_power", "shell_params", "velocity"), &ProjectileManager::calculate_penetration_power);
    ClassDB::bind_static_method("ProjectileManager", D_METHOD("calculate_impact_angle", "velocity", "surface_normal"), &ProjectileManager::calculate_impact_angle);

    // Bind instance methods
    ClassDB::bind_method(D_METHOD("__process", "delta"), &ProjectileManager::__process);
    ClassDB::bind_method(D_METHOD("_process_trails_only", "current_time"), &ProjectileManager::_process_trails_only);
    ClassDB::bind_method(D_METHOD("update_transform_pos", "idx", "pos"), &ProjectileManager::update_transform_pos);
    ClassDB::bind_method(D_METHOD("update_transform_scale", "idx", "scale"), &ProjectileManager::update_transform_scale);
    ClassDB::bind_method(D_METHOD("update_transform", "idx", "trans"), &ProjectileManager::update_transform);
    ClassDB::bind_method(D_METHOD("set_color", "idx", "color"), &ProjectileManager::set_color);
    ClassDB::bind_method(D_METHOD("resize_multimesh_buffers", "new_count"), &ProjectileManager::resize_multimesh_buffers);

    ClassDB::bind_method(D_METHOD("fireBullet", "vel", "pos", "shell", "t", "_owner", "exclude"), &ProjectileManager::fireBullet, DEFVAL(TypedArray<Ship>()));
    ClassDB::bind_method(D_METHOD("fireBulletClient", "pos", "vel", "t", "id", "shell", "_owner", "muzzle_blast", "basis"), &ProjectileManager::fireBulletClient, DEFVAL(true), DEFVAL(Basis()));

    ClassDB::bind_method(D_METHOD("destroyBulletRpc2", "id", "pos", "hit_result", "normal"), &ProjectileManager::destroyBulletRpc2);
    ClassDB::bind_method(D_METHOD("destroyBulletRpc", "id", "position", "hit_result", "normal"), &ProjectileManager::destroyBulletRpc);
    ClassDB::bind_method(D_METHOD("destroyBulletRpc3", "data"), &ProjectileManager::destroyBulletRpc3);

    ClassDB::bind_method(D_METHOD("apply_fire_damage", "projectile", "ship", "hit_position"), &ProjectileManager::apply_fire_damage);
    ClassDB::bind_method(D_METHOD("print_armor_debug", "armor_result", "ship"), &ProjectileManager::print_armor_debug);
    ClassDB::bind_method(D_METHOD("validate_penetration_formula"), &ProjectileManager::validate_penetration_formula);

    ClassDB::bind_method(D_METHOD("track_damage_dealt", "p", "damage"), &ProjectileManager::track_damage_dealt);
    ClassDB::bind_method(D_METHOD("track_damage_event", "p", "damage", "position", "type"), &ProjectileManager::track_damage_event);
    ClassDB::bind_method(D_METHOD("track_penetration", "p"), &ProjectileManager::track_penetration);
    ClassDB::bind_method(D_METHOD("track_citadel", "p"), &ProjectileManager::track_citadel);
    ClassDB::bind_method(D_METHOD("track_overpenetration", "p"), &ProjectileManager::track_overpenetration);
    ClassDB::bind_method(D_METHOD("track_shatter", "p"), &ProjectileManager::track_shatter);
    ClassDB::bind_method(D_METHOD("track_ricochet", "p"), &ProjectileManager::track_ricochet);
    ClassDB::bind_method(D_METHOD("track_frag", "p"), &ProjectileManager::track_frag);

    ClassDB::bind_method(D_METHOD("createRicochetRpc", "original_shell_id", "new_shell_id", "ricochet_position", "ricochet_velocity", "ricochet_time"), &ProjectileManager::createRicochetRpc);
    ClassDB::bind_method(D_METHOD("createRicochetRpc2", "data"), &ProjectileManager::createRicochetRpc2);

    // Bind _init_compute_trails so it can be connected to timer signal
    ClassDB::bind_method(D_METHOD("_init_compute_trails"), &ProjectileManager::_init_compute_trails);

    // Bind properties
    ClassDB::bind_method(D_METHOD("get_shell_time_multiplier"), &ProjectileManager::get_shell_time_multiplier);
    ClassDB::bind_method(D_METHOD("set_shell_time_multiplier", "mult"), &ProjectileManager::set_shell_time_multiplier);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "shell_time_multiplier"), "set_shell_time_multiplier", "get_shell_time_multiplier");

    ClassDB::bind_method(D_METHOD("get_next_id"), &ProjectileManager::get_next_id);
    ClassDB::bind_method(D_METHOD("set_next_id", "id"), &ProjectileManager::set_next_id);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "nextId"), "set_next_id", "get_next_id");

    ClassDB::bind_method(D_METHOD("get_projectiles"), &ProjectileManager::get_projectiles);
    ClassDB::bind_method(D_METHOD("set_projectiles", "projectiles"), &ProjectileManager::set_projectiles);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "projectiles"), "set_projectiles", "get_projectiles");

    ClassDB::bind_method(D_METHOD("get_ids_reuse"), &ProjectileManager::get_ids_reuse);
    ClassDB::bind_method(D_METHOD("set_ids_reuse", "ids"), &ProjectileManager::set_ids_reuse);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "ids_reuse"), "set_ids_reuse", "get_ids_reuse");

    ClassDB::bind_method(D_METHOD("get_shell_param_ids"), &ProjectileManager::get_shell_param_ids);
    ClassDB::bind_method(D_METHOD("set_shell_param_ids", "dict"), &ProjectileManager::set_shell_param_ids);
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "shell_param_ids"), "set_shell_param_ids", "get_shell_param_ids");

    ClassDB::bind_method(D_METHOD("get_bullet_id"), &ProjectileManager::get_bullet_id);
    ClassDB::bind_method(D_METHOD("set_bullet_id", "id"), &ProjectileManager::set_bullet_id);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "bulletId"), "set_bullet_id", "get_bullet_id");

    ClassDB::bind_method(D_METHOD("get_particles"), &ProjectileManager::get_particles);
    ClassDB::bind_method(D_METHOD("set_particles", "particles"), &ProjectileManager::set_particles);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "particles", PROPERTY_HINT_NODE_TYPE, "GPUParticles3D"), "set_particles", "get_particles");

    ClassDB::bind_method(D_METHOD("get_multi_mesh"), &ProjectileManager::get_multi_mesh);
    ClassDB::bind_method(D_METHOD("set_multi_mesh", "mesh"), &ProjectileManager::set_multi_mesh);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "multi_mesh", PROPERTY_HINT_NODE_TYPE, "MultiMeshInstance3D"), "set_multi_mesh", "get_multi_mesh");

    ClassDB::bind_method(D_METHOD("get_gpu_renderer"), &ProjectileManager::get_gpu_renderer);
    ClassDB::bind_method(D_METHOD("set_gpu_renderer", "renderer"), &ProjectileManager::set_gpu_renderer);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "gpu_renderer", PROPERTY_HINT_NODE_TYPE, "Node"), "set_gpu_renderer", "get_gpu_renderer");

    ClassDB::bind_method(D_METHOD("get_use_gpu_renderer"), &ProjectileManager::get_use_gpu_renderer);
    ClassDB::bind_method(D_METHOD("set_use_gpu_renderer", "use"), &ProjectileManager::set_use_gpu_renderer);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_gpu_renderer"), "set_use_gpu_renderer", "get_use_gpu_renderer");

    ClassDB::bind_method(D_METHOD("get_use_compute_trails"), &ProjectileManager::get_use_compute_trails);
    ClassDB::bind_method(D_METHOD("set_use_compute_trails", "use"), &ProjectileManager::set_use_compute_trails);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_compute_trails"), "set_use_compute_trails", "get_use_compute_trails");

    ClassDB::bind_method(D_METHOD("get_transforms"), &ProjectileManager::get_transforms);
    ClassDB::bind_method(D_METHOD("set_transforms", "transforms"), &ProjectileManager::set_transforms);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "transforms"), "set_transforms", "get_transforms");

    ClassDB::bind_method(D_METHOD("get_colors"), &ProjectileManager::get_colors);
    ClassDB::bind_method(D_METHOD("set_colors", "colors"), &ProjectileManager::set_colors);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_COLOR_ARRAY, "colors"), "set_colors", "get_colors");

    ClassDB::bind_method(D_METHOD("get_camera"), &ProjectileManager::get_camera);
    ClassDB::bind_method(D_METHOD("set_camera", "camera"), &ProjectileManager::set_camera);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "camera", PROPERTY_HINT_NODE_TYPE, "Camera3D"), "set_camera", "get_camera");
}


void ProjectileManager::_initialize_onready_vars() {
    if (onready_initialized) {
        return;
    }

    particles = Object::cast_to<GPUParticles3D>(get_node_or_null(NodePath("GPUParticles3D")));
    multi_mesh = Object::cast_to<MultiMeshInstance3D>(get_node_or_null(NodePath("MultiMeshInstance3D")));

    onready_initialized = true;
}

void ProjectileManager::_ensure_onready() {
    if (!onready_initialized && is_inside_tree()) {
        _initialize_onready_vars();
    }
}
void ProjectileManager::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
    _initialize_onready_vars();

    // Run penetration formula validation on startup
    validate_penetration_formula();

    PackedStringArray cmdline_args = OS::get_singleton()->get_cmdline_args();
    bool is_server = false;
    for (int i = 0; i < cmdline_args.size(); i++) {
        if (cmdline_args[i] == "--server") {
            is_server = true;
            break;
        }
    }


    if (is_server) {
        UtilityFunctions::print("ProjectileManager: running as SERVER - physics processing ENABLED");

        if (ray_query.is_valid()) {
            ray_query->set_collide_with_areas(true);
            ray_query->set_collide_with_bodies(true);
            ray_query->set_collision_mask(1 | (1 << 1));
            ray_query->set_hit_back_faces(true);
        }

        if (mesh_ray_query.is_valid()) {
            mesh_ray_query->set_collide_with_areas(false);
            mesh_ray_query->set_collide_with_bodies(true);
            mesh_ray_query->set_collision_mask(1 << 1);
            mesh_ray_query->set_hit_back_faces(true);
        }

        set_process(false);
        set_physics_process(true);  // Enable physics processing on server for projectile collision detection
    } else {
        UtilityFunctions::print("ProjectileManager: running as CLIENT - physics processing DISABLED (server handles collisions)");
        set_physics_process(false);

        // Initialize GPU-based renderer
        if (use_gpu_renderer) {
            Ref<GDScript> gpu_renderer_class = ResourceLoader::get_singleton()->load("res://src/artillary/GPUProjectileRenderer.gd");
            if (gpu_renderer_class.is_valid()) {
                gpu_renderer = Object::cast_to<Node>(gpu_renderer_class->call("new"));
                if (gpu_renderer) {
                    gpu_renderer->call("set_time_multiplier", shell_time_multiplier);
                    add_child(gpu_renderer);
                    if (multi_mesh) {
                        multi_mesh->set_visible(false);
                    }
                    UtilityFunctions::print("Using GPU-based projectile rendering");
                }
            }
        } else {
            UtilityFunctions::print("Using legacy CPU-based projectile rendering");
        }

        // Initialize compute particle system for trails (deferred)
        // if (use_compute_trails) {
        use_compute_trails = true;  // Always attempt to use compute trails; fallback handled in _init_compute_trails
        UtilityFunctions::print("ProjectileManager: Scheduling compute trails initialization...");
            SceneTree* tree = get_tree();
            UtilityFunctions::print("ProjectileManager: Scene tree obtained.");
            if (tree) {
            	UtilityFunctions::print("ProjectileManager: Creating timer for compute trails initialization...");
                Ref<SceneTreeTimer> timer = tree->create_timer(0.5);
                if (timer.is_valid()) {
                    timer->connect("timeout", Callable(this, "_init_compute_trails"));
                }
            }
        // }
    }
}

void ProjectileManager::_init_compute_trails() {
    UtilityFunctions::print("ProjectileManager: Initializing compute trails...");

    _compute_particle_system = _find_particle_system();

    if (_compute_particle_system == nullptr) {
        UtilityFunctions::push_warning("ProjectileManager: UnifiedParticleSystem not found, falling back to GPUParticles3D trails");
        use_compute_trails = false;
        return;
    }

    UtilityFunctions::print("ProjectileManager: Found UnifiedParticleSystem");

    // Get template manager and trail template ID
    Node* template_manager = Object::cast_to<Node>(_compute_particle_system->get("template_manager"));
    if (template_manager) {
        _trail_template_id = template_manager->call("get_template_id", "shell_trail");
        UtilityFunctions::print(vformat("ProjectileManager: shell_trail template_id = %d", _trail_template_id));
        if (_trail_template_id < 0) {
            UtilityFunctions::push_warning("ProjectileManager: 'shell_trail' template not found, falling back to GPUParticles3D trails");
            use_compute_trails = false;
            return;
        }
    } else {
        UtilityFunctions::push_warning("ProjectileManager: Template manager not found, falling back to GPUParticles3D trails");
        use_compute_trails = false;
        return;
    }

    // Hide legacy GPUParticles3D when using compute trails
    if (particles) {
        particles->set_visible(false);
    }
    UtilityFunctions::print(vformat("ProjectileManager: Using compute shader trails (template_id=%d)", _trail_template_id));
}

Node* ProjectileManager::_find_particle_system() {
    // Check common locations
    if (has_node(NodePath("/root/UnifiedParticleSystem"))) {
        return get_node<Node>(NodePath("/root/UnifiedParticleSystem"));
    }

    // Search in root children
    SceneTree* tree = get_tree();
    if (!tree) {
        return nullptr;
    }

    Window* root = tree->get_root();
    if (!root) {
        return nullptr;
    }

    for (int i = 0; i < root->get_child_count(); i++) {
        Node* child = root->get_child(i);
        // Check if this is a UnifiedParticleSystem by class name
        if (child->get_class() == "UnifiedParticleSystem" || child->is_class("UnifiedParticleSystem")) {
            return child;
        }
        // Check one level deeper
        for (int j = 0; j < child->get_child_count(); j++) {
            Node* grandchild = child->get_child(j);
            if (grandchild->get_class() == "UnifiedParticleSystem" || grandchild->is_class("UnifiedParticleSystem")) {
                return grandchild;
            }
        }
    }

    return nullptr;
}

Ship* ProjectileManager::find_ship(Node* node) {
    if (node == nullptr) {
        return nullptr;
    }
    Ship* ship = Object::cast_to<Ship>(node);
    if (ship) {
        return ship;
    }
    return find_ship(node->get_parent());
}

void ProjectileManager::_process(double delta) {
    __process(delta);
}

void ProjectileManager::_physics_process(double delta) {
    double current_time = Time::get_singleton()->get_unix_time_from_system();

    // Debug: Print every 60 frames to verify physics processing is running
    // static int physics_frame_count = 0;
    // physics_frame_count++;
    // if (physics_frame_count % 60 == 0) {
    //     UtilityFunctions::print(vformat("ProjectileManager::_physics_process running, projectiles count: %d", projectiles.size()));
    // }

    SceneTree* tree = get_tree();
    if (!tree) {
        UtilityFunctions::print("ProjectileManager::_physics_process: No scene tree!");
        return;
    }

    Window* root = tree->get_root();
    if (!root) {
        return;
    }

    Ref<World3D> world = root->get_world_3d();
    if (world.is_null()) {
        return;
    }

    PhysicsDirectSpaceState3D* space_state = world->get_direct_space_state();
    if (!space_state) {
        return;
    }

    // Get ArmorInteraction autoload
    Node* armor_interaction = get_node_or_null(NodePath("/root/ArmorInteraction"));
    Node* tcp_thread_pool = get_node_or_null(NodePath("/root/TcpThreadPool"));

    int id = 0;
    for (int i = 0; i < projectiles.size(); i++) {
        Variant proj_var = projectiles[i];
        if (proj_var.get_type() == Variant::NIL) {
            id++;
            continue;
        }

        Ref<ProjectileData> p = proj_var;
        if (p.is_null()) {
            id++;
            continue;
        }

        p->set_frame_count(p->get_frame_count() + 1);

        double t = (current_time - p->get_start_time()) * shell_time_multiplier;

        if (ray_query.is_valid()) {
            ray_query->set_from(p->get_position());
        }

        Vector3 new_pos = ProjectilePhysicsWithDrag::calculate_position_at_time(
            p->get_start_position(), p->get_launch_velocity(), t, p->get_params()->get("drag"));
        p->set_position(new_pos);

        if (ray_query.is_valid()) {
            ray_query->set_to(p->get_position());
        }

        // Call ArmorInteraction.process_travel
        Variant hit_result;
        if (armor_interaction) {
            hit_result = armor_interaction->call("process_travel", p, ray_query->get_from(), t, space_state);
        }

        if (hit_result.get_type() == Variant::NIL) {
            id++;
            continue;
        }

        // Get result properties
        Object* hit_result_obj = hit_result;
        if (!hit_result_obj) {
            id++;
            continue;
        }

        Variant ship_var = hit_result_obj->get("ship");
        Ship* result_ship = nullptr;
        if (ship_var.get_type() != Variant::NIL) {
            result_ship = Object::cast_to<Ship>(ship_var);
        }

        int result_type = hit_result_obj->get("result_type");
        Vector3 explosion_position = hit_result_obj->get("explosion_position");
        Vector3 collision_normal = hit_result_obj->get("collision_normal");
        Vector3 velocity = hit_result_obj->get("velocity");

        // ArmorInteraction HitResult enum values (must match ArmorInteraction.gd)
        const int AR_PENETRATION = 0;
        const int AR_PARTIAL_PEN = 1;
        const int AR_RICOCHET = 2;
        const int AR_OVERPENETRATION = 3;
        const int AR_SHATTER = 4;
        const int AR_CITADEL = 5;
        const int AR_CITADEL_OVERPEN = 6;
        const int AR_WATER = 7;
        const int AR_TERRAIN = 8;

        Ship* owner_ship = p->get_owner();
        TypedArray<Ship> exclude = p->get_exclude();

        bool ship_excluded = false;
        for (int j = 0; j < exclude.size(); j++) {
            if (exclude[j] == Variant(result_ship)) {
                ship_excluded = true;
                break;
            }
        }

        if (result_ship != nullptr && owner_ship != nullptr && !ship_excluded && result_ship != owner_ship) {
            if (exclude.size() >= 1) {
                UtilityFunctions::print(vformat("ricochet exclude ships: %d", exclude.size()));
            }

            Ref<Resource> shell_params = p->get_params();
            double damage_val = shell_params->get("damage");
            double damage = 0.0;

            if (result_type == AR_PENETRATION || result_type == AR_PARTIAL_PEN) {
                damage = damage_val / 3.0;
                destroyBulletRpc(id, explosion_position, result_type == AR_PARTIAL_PEN ? PARTIAL_PEN : PENETRATION, collision_normal);
            } else if (result_type == AR_CITADEL) {
                damage = damage_val;
                destroyBulletRpc(id, explosion_position, CITADEL, collision_normal);
            } else if (result_type == AR_CITADEL_OVERPEN) {
                damage = damage_val * 0.5;
                destroyBulletRpc(id, explosion_position, CITADEL_OVERPEN, collision_normal);
            } else if (result_type == AR_OVERPENETRATION) {
                damage = damage_val * 0.1;
                destroyBulletRpc(id, explosion_position, OVERPENETRATION, collision_normal);
            } else if (result_type == AR_SHATTER) {
                damage = damage_val * 0.0;
                destroyBulletRpc(id, explosion_position, SHATTER, collision_normal);
            } else if (result_type == AR_RICOCHET) {
                damage = 0.0;
                Vector3 ricochet_velocity = velocity;
                Vector3 ricochet_position = explosion_position + collision_normal * 0.2 + ricochet_velocity.normalized() * 0.2;

                TypedArray<Ship> new_exclude = exclude.duplicate();
                new_exclude.append(result_ship);
                int ricochet_id = fireBullet(ricochet_velocity, ricochet_position, shell_params, current_time, nullptr, new_exclude);

                if (tcp_thread_pool) {
                    tcp_thread_pool->call("send_ricochet", id, ricochet_id, ricochet_position, ricochet_velocity, current_time);
                }

                destroyBulletRpc(id, explosion_position, RICOCHET, collision_normal);
            }

            // Get health controller and process damage
            Node* health_controller = Object::cast_to<Node>(result_ship->call("get_health_controller"));
            if (health_controller && health_controller->call("is_alive")) {
                Array dmg_result = health_controller->call("take_damage", damage, explosion_position);
                double dmg_dealt = dmg_result[0];
                bool sunk = dmg_result[1];

                apply_fire_damage(p, result_ship, explosion_position);
                track_damage_dealt(p, dmg_dealt);

                if (result_type == AR_PENETRATION || result_type == AR_PARTIAL_PEN) {
                    track_penetration(p);
                } else if (result_type == AR_CITADEL || result_type == AR_CITADEL_OVERPEN) {
                    track_citadel(p);
                } else if (result_type == AR_OVERPENETRATION) {
                    track_overpenetration(p);
                } else if (result_type == AR_SHATTER) {
                    track_shatter(p);
                } else if (result_type == AR_RICOCHET) {
                    track_ricochet(p);
                }

                if (sunk) {
                    track_frag(p);
                }
                track_damage_event(p, dmg_dealt, result_ship->get_global_position(), result_type);
            }
        } else if (result_type == AR_WATER) {
            // UtilityFunctions::print(vformat("_physics_process: WATER hit, result_type=%d, sending WATER=%d", result_type, WATER));
            destroyBulletRpc(id, explosion_position, WATER, collision_normal);
        } else if (result_type == AR_TERRAIN) {
            // UtilityFunctions::print(vformat("_physics_process: TERRAIN hit, result_type=%d, sending TERRAIN=%d", result_type, TERRAIN));
            destroyBulletRpc(id, explosion_position, TERRAIN, collision_normal);
        }

        id++;
    }
}

void ProjectileManager::__process(double delta) {
    double current_time = Time::get_singleton()->get_unix_time_from_system();

    if (camera == nullptr) {
        return;
    }

    // GPU renderer handles shell position/rendering automatically via shader
    if (use_gpu_renderer && gpu_renderer != nullptr) {
        _process_trails_only(current_time);
        return;
    }

    // Legacy CPU-based rendering path
    _ensure_onready();

    int id = 0;
    for (int i = 0; i < projectiles.size(); i++) {
        Variant proj_var = projectiles[i];
        if (proj_var.get_type() == Variant::NIL) {
            id++;
            continue;
        }

        Ref<ProjectileData> p = proj_var;
        if (p.is_null()) {
            id++;
            continue;
        }

        double t = (current_time - p->get_start_time()) * shell_time_multiplier;
        Ref<Resource> params = p->get_params();
        double drag = params->get("drag");

        Vector3 new_pos = ProjectilePhysicsWithDrag::calculate_position_at_time(
            p->get_start_position(), p->get_launch_velocity(), t, drag);
        p->set_position(new_pos);
        update_transform_pos(id, p->get_position());

        id++;

        Vector3 offset = p->get_position() - p->get_trail_pos();
        if ((p->get_position() - p->get_start_position()).length_squared() < 80) {
            continue;
        }

        double offset_length = offset.length();
        const double step_size = 20.0;
        Vector3 vel = offset.normalized();
        offset = vel * step_size;

        Transform3D trans = Transform3D().translated(p->get_trail_pos());
        double size = params->get("size");

        while (offset_length > step_size && particles) {
            double width_scale = size * 0.9;
            Color color_data = Color(width_scale, 1.0, 1.0, 1.0);
            particles->emit_particle(trans, vel, color_data, Color(1, 1, 1, 1), 5 | 8);
            trans = trans.translated(offset);
            p->set_trail_pos(p->get_trail_pos() + offset);
            offset_length -= step_size;
        }
    }

    if (multi_mesh && multi_mesh->get_multimesh().is_valid()) {
        Ref<MultiMesh> mm = multi_mesh->get_multimesh();
        mm->set_instance_count(int(transforms.size() / 16.0));
        mm->set_visible_instance_count(mm->get_instance_count());
        mm->set_buffer(transforms);
    }
}

void ProjectileManager::_process_trails_only(double current_time) {
    for (int i = 0; i < projectiles.size(); i++) {
        Variant proj_var = projectiles[i];
        if (proj_var.get_type() == Variant::NIL) {
            continue;
        }

        Ref<ProjectileData> p = proj_var;
        if (p.is_null()) {
            continue;
        }

        double t = (current_time - p->get_start_time()) * shell_time_multiplier;
        Ref<Resource> params = p->get_params();
        double drag = params->get("drag");

        Vector3 new_pos = ProjectilePhysicsWithDrag::calculate_position_at_time(
            p->get_start_position(), p->get_launch_velocity(), t, drag);
        p->set_position(new_pos);

        Vector3 offset = p->get_position() - p->get_trail_pos();
        if ((p->get_position() - p->get_start_position()).length_squared() < 80) {
            continue;
        }

        double offset_length = offset.length();
        const double step_size = 20.0;
        Vector3 vel = offset.normalized();

        double size = params->get("size");

        if (use_compute_trails && _compute_particle_system != nullptr && _trail_template_id >= 0) {
            double width_scale = size * 0.9;
            int emitted = _compute_particle_system->call("emit_trail",
                p->get_trail_pos(),
                p->get_position(),
                vel,
                _trail_template_id,
                width_scale,
                step_size,
                1.0
            );

            if (emitted > 0) {
                p->set_trail_pos(p->get_trail_pos() + vel * step_size * emitted);
            }
        } else if (particles) {
            // Fall back to legacy GPUParticles3D
            Vector3 step_offset = vel * step_size;
            Transform3D trans = Transform3D().translated(p->get_trail_pos());

            while (offset_length > step_size) {
                double width_scale = size * 0.9;
                Color color_data = Color(width_scale, 1.0, 1.0, 1.0);
                particles->emit_particle(trans, vel, color_data, Color(1, 1, 1, 1), 5 | 8);
                trans = trans.translated(step_offset);
                p->set_trail_pos(p->get_trail_pos() + step_offset);
                offset_length -= step_size;
            }
        }
    }
}

int ProjectileManager::next_pow_of_2(int value) {
    if (value <= 0) {
        return 1;
    }

    int result = value - 1;
    result |= result >> 1;
    result |= result >> 2;
    result |= result >> 4;
    result |= result >> 8;
    result |= result >> 16;
    result += 1;
    return result;
}

PackedFloat32Array ProjectileManager::transform_to_packed_float32array(const Transform3D& transform) {
    PackedFloat32Array array;
    array.resize(16);

    // Extract basis (3x3 rotation matrix)
    array.set(0, transform.basis.get_column(0).x);
    array.set(1, transform.basis.get_column(0).y);
    array.set(2, transform.basis.get_column(0).z);
    array.set(3, transform.basis.get_column(1).x);
    array.set(4, transform.basis.get_column(1).y);
    array.set(5, transform.basis.get_column(1).z);
    array.set(6, transform.basis.get_column(2).x);
    array.set(7, transform.basis.get_column(2).y);
    array.set(8, transform.basis.get_column(2).z);

    // Extract origin (translation)
    array.set(9, transform.origin.x);
    array.set(10, transform.origin.y);
    array.set(11, transform.origin.z);

    return array;
}

void ProjectileManager::update_transform_pos(int idx, const Vector3& pos) {
    int offset = idx * 16;
    if (offset + 11 >= transforms.size()) {
        return;
    }
    transforms.set(offset + 3, pos.x);
    transforms.set(offset + 7, pos.y);
    transforms.set(offset + 11, pos.z);
}

void ProjectileManager::update_transform_scale(int idx, double scale) {
    int offset = idx * 16;
    if (offset + 10 >= transforms.size()) {
        return;
    }

    // Get current x-basis direction and normalize it
    Vector3 x_basis = Vector3(transforms[offset + 0], transforms[offset + 1], transforms[offset + 2]);
    if (x_basis.length_squared() > 0.0001) {
        x_basis = x_basis.normalized() * scale;
    } else {
        x_basis = Vector3(scale, 0, 0);
    }

    // Get current y-basis direction and normalize it
    Vector3 y_basis = Vector3(transforms[offset + 4], transforms[offset + 5], transforms[offset + 6]);
    if (y_basis.length_squared() > 0.0001) {
        y_basis = y_basis.normalized() * scale;
    } else {
        y_basis = Vector3(0, scale, 0);
    }

    transforms.set(offset + 0, x_basis.x);
    transforms.set(offset + 1, x_basis.y);
    transforms.set(offset + 2, x_basis.z);

    transforms.set(offset + 4, y_basis.x);
    transforms.set(offset + 5, y_basis.y);
    transforms.set(offset + 6, y_basis.z);
}

void ProjectileManager::update_transform(int idx, const Transform3D& trans) {
    int offset = idx * 16;
    if (offset + 11 >= transforms.size()) {
        return;
    }

    // Basis
    transforms.set(offset + 0, trans.basis.get_column(0).x);
    transforms.set(offset + 1, trans.basis.get_column(0).y);
    transforms.set(offset + 2, trans.basis.get_column(0).z);
    transforms.set(offset + 3, trans.origin.x);
    transforms.set(offset + 4, trans.basis.get_column(1).x);
    transforms.set(offset + 5, trans.basis.get_column(1).y);
    transforms.set(offset + 6, trans.basis.get_column(1).z);
    transforms.set(offset + 7, trans.origin.y);
    transforms.set(offset + 8, trans.basis.get_column(2).x);
    transforms.set(offset + 9, trans.basis.get_column(2).y);
    transforms.set(offset + 10, trans.basis.get_column(2).z);
    transforms.set(offset + 11, trans.origin.z);
}

void ProjectileManager::set_color(int idx, const Color& color) {
    int offset = idx * 16;
    if (offset + 15 >= transforms.size()) {
        return;
    }
    transforms.set(offset + 12, color.r);
    transforms.set(offset + 13, color.g);
    transforms.set(offset + 14, color.b);
    transforms.set(offset + 15, color.a);
}

void ProjectileManager::resize_multimesh_buffers(int new_count) {
    transforms.resize(new_count * 16);
    colors.resize(new_count);
    projectiles.resize(new_count);

    _ensure_onready();
    if (multi_mesh && multi_mesh->get_multimesh().is_valid()) {
        Ref<MultiMesh> mm = multi_mesh->get_multimesh();
        mm->set_instance_count(new_count);
        mm->set_buffer(transforms);
    }
}

double ProjectileManager::calculate_penetration_power(const Ref<Resource>& shell_params, double velocity) {
    if (shell_params.is_null()) {
        return 0.0;
    }

    double weight_kg = shell_params->get("mass");
    double caliber_mm = shell_params->get("caliber");
    double velocity_ms = velocity;

    double naval_constant_metric = 0.55664;
    double base_penetration = naval_constant_metric * std::pow(weight_kg, 0.55) * std::pow(velocity_ms, 1.1) / std::pow(caliber_mm, 0.65);

    double shell_quality_factor = 1.0;
    int shell_type = shell_params->get("type");
    if (shell_type == 1) { // AP
        shell_quality_factor = 1.0;
    } else { // HE
        shell_quality_factor = 0.4;
    }

    double penetration_modifier = shell_params->get("penetration_modifier");
    shell_quality_factor *= penetration_modifier;

    return base_penetration * shell_quality_factor;
}

double ProjectileManager::calculate_impact_angle(const Vector3& velocity, const Vector3& surface_normal) {
    double angle_rad = velocity.normalized().angle_to(surface_normal);
    return std::min(angle_rad, Math_PI - angle_rad);
}

int ProjectileManager::fireBullet(const Vector3& vel, const Vector3& pos, const Ref<Resource>& shell, double t, Ship* _owner, const TypedArray<Ship>& exclude) {
    Variant id_var = ids_reuse.pop_back();
    int id;
    if (id_var.get_type() == Variant::NIL) {
        id = nextId;
        nextId++;
    } else {
        id = id_var;
    }

    if (id >= projectiles.size()) {
        int np2 = next_pow_of_2(id + 1);
        projectiles.resize(np2);
    }

    Ref<ProjectileData> bullet;
    bullet.instantiate();
    bullet->initialize(pos, vel, t, shell, _owner, exclude);

    projectiles[id] = bullet;

    return id;
}

void ProjectileManager::fireBulletClient(const Vector3& pos, const Vector3& vel, double t, int id, const Ref<Resource>& shell, Ship* _owner, bool muzzle_blast, const Basis& basis) {
    Ref<ProjectileData> bullet;
    bullet.instantiate();

    if (use_gpu_renderer && gpu_renderer != nullptr) {
        // Determine shell color based on type
        Color shell_color;
        int shell_type = shell->get("type");
        if (shell_type == 1) { // AP
            shell_color = Color(0.05, 0.1, 1.0, 1.0);
        } else { // HE
            shell_color = Color(1.0, 0.2, 0.05, 1.0);
        }

        double drag = shell->get("drag");
        double size = shell->get("size");

        int gpu_id = gpu_renderer->call("fire_shell", pos, vel, drag, size, shell_type, shell_color);

        if (id >= projectiles.size()) {
            int np2 = next_pow_of_2(id + 1);
            projectiles.resize(np2);
        }

        bullet->initialize(pos, vel, t, shell, _owner);
        bullet->set_frame_count(gpu_id);
        projectiles[id] = bullet;
    } else {
        // Legacy path
        if (id * 16 >= transforms.size()) {
            int np2 = next_pow_of_2(id + 1);
            resize_multimesh_buffers(np2);
        }

        double s = shell->get("size");
        Transform3D trans = Transform3D().scaled(Vector3(s, s, s)).translated(pos);
        update_transform(id, trans);

        int shell_type = shell->get("type");
        if (shell_type == 1) { // AP
            set_color(id, Color(0.05, 0.1, 1.0, 1.0));
        } else { // HE
            set_color(id, Color(1.0, 0.2, 0.05, 1.0));
        }

        bullet->initialize(pos, vel, t, shell, _owner);
        projectiles[id] = bullet;
    }

    if (muzzle_blast) {
        Node* hit_effects = get_node_or_null(NodePath("/root/HitEffects"));
        if (hit_effects) {
            double size = shell->get("size");
            hit_effects->call("muzzle_blast_effect", pos, basis, size * size);
        }
    }
}

void ProjectileManager::destroyBulletRpc2(int id, const Vector3& pos, int hit_result, const Vector3& normal) {
    // UtilityFunctions::print(vformat("destroyBulletRpc2: id=%d, hit_result=%d, pos=(%f,%f,%f)", id, hit_result, pos.x, pos.y, pos.z));

    if (id < 0 || id >= projectiles.size()) {
        UtilityFunctions::print(vformat("bullet is null: %d", id));
        return;
    }

    Variant proj_var = projectiles[id];
    if (proj_var.get_type() == Variant::NIL) {
        UtilityFunctions::print(vformat("bullet is null: %d", id));
        return;
    }

    Ref<ProjectileData> bullet = proj_var;
    if (bullet.is_null()) {
        UtilityFunctions::print(vformat("bullet is null: %d", id));
        return;
    }

    double radius = bullet->get_params()->get("size");

    // Destroy in GPU renderer if using it
    if (use_gpu_renderer && gpu_renderer != nullptr) {
        int gpu_id = bullet->get_frame_count();
        gpu_renderer->call("destroy_shell", gpu_id);
    } else {
        // Legacy path - hide by moving far away
        Basis b;
        b.set_column(0, Vector3());
        b.set_column(1, Vector3());
        b.set_column(2, Vector3());
        Transform3D t = Transform3D(b, Vector3(0.0, INFINITY, 0.0));
        update_transform(id, t);
    }

    projectiles[id] = Variant();

    Node* hit_effects = get_node_or_null(NodePath("/root/HitEffects"));
    if (!hit_effects) {
        return;
    }

    switch (hit_result) {
        case WATER:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: WATER case hit"));
            hit_effects->call("splash_effect", pos, radius);
            break;
        case PENETRATION:
        case TERRAIN:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: PENETRATION/TERRAIN case hit (hit_result=%d, PENETRATION=%d, TERRAIN=%d)", hit_result, PENETRATION, TERRAIN));
            hit_effects->call("he_explosion_effect", pos, radius * 0.8, normal);
            hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
            break;
        case PARTIAL_PEN:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: PARTIAL_PEN case hit"));
            hit_effects->call("he_explosion_effect", pos, radius * 0.6, normal);
            hit_effects->call("sparks_effect", pos, radius * 0.4, normal);
            break;
        case CITADEL:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: CITADEL case hit"));
            radius *= 1.2;
            hit_effects->call("he_explosion_effect", pos, radius, normal);
            hit_effects->call("sparks_effect", pos, radius * 0.6, normal);
            break;
        case CITADEL_OVERPEN:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: CITADEL_OVERPEN case hit"));
            hit_effects->call("he_explosion_effect", pos, radius * 0.9, normal);
            hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
            break;
        case RICOCHET:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: RICOCHET case hit"));
            hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
            break;
        case OVERPENETRATION:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: OVERPENETRATION case hit"));
            hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
            break;
        case SHATTER:
            // UtilityFunctions::print(vformat("destroyBulletRpc2 switch: SHATTER case hit"));
            hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
            break;
            // hit_effects->call("he_explosion_effect", pos, radius * 0., normal);
            // break;
        default:
            UtilityFunctions::print(vformat("destroyBulletRpc2 switch: DEFAULT case hit! hit_result=%d did not match any case!", hit_result));
            break;
    }
}

void ProjectileManager::destroyBulletRpc(int id, const Vector3& position, int hit_result, const Vector3& normal) {
    // UtilityFunctions::print(vformat("destroyBulletRpc: id=%d, hit_result=%d (TERRAIN=%d, PENETRATION=%d, WATER=%d)", id, hit_result, TERRAIN, PENETRATION, WATER));
    projectiles[id] = Variant();
    ids_reuse.push_back(id);

    Node* tcp_thread_pool = get_node_or_null(NodePath("/root/TcpThreadPool"));
    if (tcp_thread_pool) {
        tcp_thread_pool->call("send_destroy_shell", id, position, hit_result, normal);
    }
}

void ProjectileManager::destroyBulletRpc3(const PackedByteArray& data) {
    if (data.size() < 32) {  // 4 (id) + 12 (pos) + 4 (hit_result) + 12 (normal) = 32 bytes
        UtilityFunctions::print("Invalid data size for destroyBulletRpc3");
        return;
    }

    Ref<StreamPeerBuffer> stream;
    stream.instantiate();
    stream->set_data_array(data);

    int id = stream->get_32();
    Vector3 pos = Vector3(stream->get_float(), stream->get_float(), stream->get_float());
    int hit_result = stream->get_32();  // Must match put_u32 in tcp_thread_pool.gd send_destroy_shell
    Vector3 normal = Vector3(stream->get_float(), stream->get_float(), stream->get_float());

    destroyBulletRpc2(id, pos, hit_result, normal);
}

void ProjectileManager::apply_fire_damage(const Ref<ProjectileData>& projectile, Ship* ship, const Vector3& hit_position) {
    if (projectile.is_null() || ship == nullptr) {
        return;
    }

    Ref<Resource> params = projectile->get_params();
    double fire_buildup = params->get("fire_buildup");

    if (fire_buildup > 0) {
        Node* fire_manager = Object::cast_to<Node>(ship->call("get_fire_manager"));
        if (!fire_manager) {
            return;
        }

        Array fires = fire_manager->get("fires");
        Node* closest_fire = nullptr;
        double closest_fire_dist = 1000000000.0;

        for (int i = 0; i < fires.size(); i++) {
            Node3D* f = Object::cast_to<Node3D>(fires[i]);
            if (f) {
                double dist = f->get_global_position().distance_squared_to(hit_position);
                if (dist < closest_fire_dist) {
                    closest_fire_dist = dist;
                    closest_fire = f;
                }
            }
        }

        if (closest_fire) {
            closest_fire->call("_apply_build_up", fire_buildup, projectile->get_owner());
        }
    }
}

void ProjectileManager::print_armor_debug(const Dictionary& armor_result, Ship* ship) {
    if (ship == nullptr) {
        return;
    }

    String ship_class = "Unknown";
    Node* health_controller = Object::cast_to<Node>(ship->call("get_health_controller"));
    if (health_controller) {
        double max_hp = health_controller->get("max_hp");
        if (max_hp > 40000) {
            ship_class = "Battleship";
        } else if (max_hp > 15000) {
            ship_class = "Cruiser";
        } else {
            ship_class = "Destroyer";
        }
    }

    String result_name = "";
    int result_type = armor_result.get("result_type", 0);
    switch (result_type) {
        case PENETRATION: result_name = "PENETRATION"; break;
        case PARTIAL_PEN: result_name = "PARTIAL_PEN"; break;
        case RICOCHET: result_name = "RICOCHET"; break;
        case OVERPENETRATION: result_name = "OVERPENETRATION"; break;
        case SHATTER: result_name = "SHATTER"; break;
        case CITADEL: result_name = "CITADEL"; break;
        case CITADEL_OVERPEN: result_name = "CITADEL_OVERPEN"; break;
        case WATER: result_name = "WATER"; break;
        case TERRAIN: result_name = "TERRAIN"; break;
    }

    Dictionary armor_data = armor_result.get("armor_data", Dictionary());
    String hit_location = armor_data.get("node_path", "unknown");
    int face_index = armor_data.get("face_index", 0);

    double penetration_power = armor_result.get("penetration_power", 0.0);
    double armor_thickness = armor_result.get("armor_thickness", 0.0);
    double impact_angle = armor_result.get("impact_angle", 0.0);
    double damage = armor_result.get("damage", 0.0);

    UtilityFunctions::print(vformat("🛡️ %s vs %s: %s | Target: %s face %d | %.0fmm pen vs %.0fmm armor at %.1f° | %.0f damage",
        result_name, ship_class, result_name, hit_location, face_index,
        penetration_power, armor_thickness, impact_angle, damage));
}

void ProjectileManager::validate_penetration_formula() {
    UtilityFunctions::print("=== Penetration Formula Validation ===");

    // Load ShellParams resource script
    Ref<GDScript> shell_params_script = ResourceLoader::get_singleton()->load("res://src/artillary/Shells/shell_params.gd");
    if (shell_params_script.is_null()) {
        UtilityFunctions::print("Could not load ShellParams script");
        return;
    }

    // Test 380mm BB shell
    Ref<Resource> bb_shell = shell_params_script->call("new");
    bb_shell->set("caliber", 380.0);
    bb_shell->set("mass", 800.0);
    bb_shell->set("type", 1); // AP
    bb_shell->set("penetration_modifier", 1.0);

    double bb_penetration = calculate_penetration_power(bb_shell, 820.0);
    UtilityFunctions::print(vformat("380mm AP shell at 820 m/s, 0° impact: %fmm penetration", bb_penetration));
    UtilityFunctions::print("Expected: ~700-800mm for battleship shells");

    // Test 500mm super BB shell
    Ref<Resource> super_bb_shell = shell_params_script->call("new");
    super_bb_shell->set("caliber", 500.0);
    super_bb_shell->set("mass", 1850.0);
    super_bb_shell->set("type", 1); // AP
    super_bb_shell->set("penetration_modifier", 1.0);

    double super_bb_penetration = calculate_penetration_power(super_bb_shell, 810.0);
    UtilityFunctions::print(vformat("500mm AP shell at 810 m/s, 0° impact: %fmm penetration", super_bb_penetration));
    UtilityFunctions::print("Expected: ~1200-1300mm for super battleship shells");

    // Test 203mm CA shell
    Ref<Resource> ca_shell = shell_params_script->call("new");
    ca_shell->set("caliber", 203.0);
    ca_shell->set("mass", 118.0);
    ca_shell->set("type", 1); // AP
    ca_shell->set("penetration_modifier", 1.0);

    double ca_penetration = calculate_penetration_power(ca_shell, 760.0);
    UtilityFunctions::print(vformat("203mm AP shell at 760 m/s, 0° impact: %fmm penetration", ca_penetration));
    UtilityFunctions::print("Expected: ~200-300mm for cruiser shells");

    // Test 152mm secondary shell
    Ref<Resource> sec_shell = shell_params_script->call("new");
    sec_shell->set("caliber", 152.0);
    sec_shell->set("mass", 45.3);
    sec_shell->set("type", 1); // AP
    sec_shell->set("penetration_modifier", 1.0);

    double sec_penetration = calculate_penetration_power(sec_shell, 900.0);
    UtilityFunctions::print(vformat("152mm AP shell at 900 m/s, 0° impact: %fmm penetration", sec_penetration));
    UtilityFunctions::print("Expected: ~150-200mm for secondary guns");

    UtilityFunctions::print("=== End of Penetration Formula Validation ===");

    // Test air drag vs water drag
    Vector3 air_pos = ProjectilePhysicsWithDrag::calculate_position_at_time(Vector3(), Vector3(0, 0, 820), 0.035, 0.009);

    // Get water drag multiplier from ArmorInteraction
    double water_drag_mult = 1.0;
    Node* armor_interaction = get_node_or_null(NodePath("/root/ArmorInteraction"));
    if (armor_interaction) {
        water_drag_mult = armor_interaction->get("WATER_DRAG");
    }

    Vector3 water_pos = ProjectilePhysicsWithDrag::calculate_position_at_time(Vector3(), Vector3(0, 0, 820), 0.035, 0.009 * water_drag_mult);
    UtilityFunctions::print(vformat("Position after 0.035s in air drag: %s", air_pos));
    UtilityFunctions::print(vformat("Position after 0.035s in water drag: %s", water_pos));

    Vector3 speed_air = ProjectilePhysicsWithDrag::calculate_velocity_at_time(Vector3(0, 0, 820), 0.035, 0.009);
    Vector3 speed_water = ProjectilePhysicsWithDrag::calculate_velocity_at_time(Vector3(0, 0, 820), 0.035, 0.009 * water_drag_mult);
    UtilityFunctions::print(vformat("Speed after 0.035s in air drag: %s", speed_air));
    UtilityFunctions::print(vformat("Speed after 0.035s in water drag: %s", speed_water));
}

void ProjectileManager::track_damage_dealt(const Ref<ProjectileData>& p, double damage) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        double total_damage = stats->get("total_damage");
        stats->set("total_damage", total_damage + damage);

        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");
        if (is_secondary) {
            double sec_damage = stats->get("sec_damage");
            stats->set("sec_damage", sec_damage + damage);
        } else {
            double main_damage = stats->get("main_damage");
            stats->set("main_damage", main_damage + damage);
        }
    }
}

void ProjectileManager::track_damage_event(const Ref<ProjectileData>& p, double damage, const Vector3& position, int type) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        Dictionary event;
        event["type"] = type;
        event["sec"] = is_secondary;
        event["damage"] = damage;
        event["position"] = position;

        Array damage_events = stats->get("damage_events");
        damage_events.append(event);
        stats->set("damage_events", damage_events);
    }
}

void ProjectileManager::track_penetration(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        if (!is_secondary) {
            int penetration_count = stats->get("penetration_count");
            stats->set("penetration_count", penetration_count + 1);
            int main_hits = stats->get("main_hits");
            stats->set("main_hits", main_hits + 1);
        } else {
            int sec_penetration_count = stats->get("sec_penetration_count");
            stats->set("sec_penetration_count", sec_penetration_count + 1);
            int secondary_count = stats->get("secondary_count");
            stats->set("secondary_count", secondary_count + 1);
        }
    }
}

void ProjectileManager::track_citadel(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        if (!is_secondary) {
            int citadel_count = stats->get("citadel_count");
            stats->set("citadel_count", citadel_count + 1);
            int main_hits = stats->get("main_hits");
            stats->set("main_hits", main_hits + 1);
        } else {
            int sec_citadel_count = stats->get("sec_citadel_count");
            stats->set("sec_citadel_count", sec_citadel_count + 1);
            int secondary_count = stats->get("secondary_count");
            stats->set("secondary_count", secondary_count + 1);
        }
    }
}

void ProjectileManager::track_overpenetration(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        if (!is_secondary) {
            int overpen_count = stats->get("overpen_count");
            stats->set("overpen_count", overpen_count + 1);
            int main_hits = stats->get("main_hits");
            stats->set("main_hits", main_hits + 1);
        } else {
            int sec_overpen_count = stats->get("sec_overpen_count");
            stats->set("sec_overpen_count", sec_overpen_count + 1);
            int secondary_count = stats->get("secondary_count");
            stats->set("secondary_count", secondary_count + 1);
        }
    }
}

void ProjectileManager::track_shatter(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        if (!is_secondary) {
            int shatter_count = stats->get("shatter_count");
            stats->set("shatter_count", shatter_count + 1);
            int main_hits = stats->get("main_hits");
            stats->set("main_hits", main_hits + 1);
        } else {
            int sec_shatter_count = stats->get("sec_shatter_count");
            stats->set("sec_shatter_count", sec_shatter_count + 1);
            int secondary_count = stats->get("secondary_count");
            stats->set("secondary_count", secondary_count + 1);
        }
    }
}

void ProjectileManager::track_ricochet(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        Ref<Resource> params = p->get_params();
        bool is_secondary = params->get("_secondary");

        if (!is_secondary) {
            int ricochet_count = stats->get("ricochet_count");
            stats->set("ricochet_count", ricochet_count + 1);
            int main_hits = stats->get("main_hits");
            stats->set("main_hits", main_hits + 1);
        } else {
            int sec_ricochet_count = stats->get("sec_ricochet_count");
            stats->set("sec_ricochet_count", sec_ricochet_count + 1);
            int secondary_count = stats->get("secondary_count");
            stats->set("secondary_count", secondary_count + 1);
        }
    }
}

void ProjectileManager::track_frag(const Ref<ProjectileData>& p) {
    if (p.is_null()) {
        return;
    }

    Ship* owner = p->get_owner();
    if (owner == nullptr) {
        return;
    }

    Node* stats = Object::cast_to<Node>(owner->call("get_stats"));
    if (stats) {
        int frags = stats->get("frags");
        stats->set("frags", frags + 1);
    }
}

void ProjectileManager::createRicochetRpc(int original_shell_id, int new_shell_id, const Vector3& ricochet_position, const Vector3& ricochet_velocity, double ricochet_time) {
    if (original_shell_id < 0 || original_shell_id >= projectiles.size()) {
        UtilityFunctions::print(vformat("Warning: Could not find original shell with ID %d for ricochet", original_shell_id));
        return;
    }

    Variant proj_var = projectiles[original_shell_id];
    if (proj_var.get_type() == Variant::NIL) {
        UtilityFunctions::print(vformat("Warning: Could not find original shell with ID %d for ricochet", original_shell_id));
        return;
    }

    Ref<ProjectileData> p = proj_var;
    if (p.is_null()) {
        UtilityFunctions::print(vformat("Warning: Could not find original shell with ID %d for ricochet", original_shell_id));
        return;
    }

    fireBulletClient(ricochet_position, ricochet_velocity, ricochet_time, new_shell_id, p->get_params(), nullptr, false);
}

void ProjectileManager::createRicochetRpc2(const PackedByteArray& data) {
    if (data.size() < 32) {
        UtilityFunctions::print("Warning: Invalid ricochet data size");
        return;
    }

    Ref<StreamPeerBuffer> stream;
    stream.instantiate();
    stream->set_data_array(data);

    int original_shell_id = stream->get_32();
    int new_shell_id = stream->get_32();
    Vector3 ricochet_position = Vector3(stream->get_float(), stream->get_float(), stream->get_float());
    Vector3 ricochet_velocity = Vector3(stream->get_float(), stream->get_float(), stream->get_float());
    double ricochet_time = stream->get_double();

    createRicochetRpc(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time);
}
