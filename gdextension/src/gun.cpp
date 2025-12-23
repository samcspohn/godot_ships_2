#include "gun.h"
#include "ship.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/multiplayer_peer.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <cmath>

using namespace godot;

// ============================================================================
// SimShell Implementation
// ============================================================================

void SimShell::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_start_position"), &SimShell::get_start_position);
    ClassDB::bind_method(D_METHOD("set_start_position", "position"), &SimShell::set_start_position);
    ClassDB::bind_method(D_METHOD("get_position"), &SimShell::get_position);
    ClassDB::bind_method(D_METHOD("set_position", "position"), &SimShell::set_position);

    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_position"), "set_start_position", "get_start_position");
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
}

SimShell::SimShell() : start_position(Vector3()), position(Vector3()) {}
SimShell::~SimShell() {}

// ============================================================================
// Projectile Physics Script Helper
// ============================================================================

Ref<GDScript> Gun::get_projectile_physics_script() {
    static Ref<GDScript> cached_script;
    if (cached_script.is_null()) {
        Ref<Resource> res = ResourceLoader::get_singleton()->load("res://src/artillary/analytical_projectile_system.gd");
        if (res.is_valid()) {
            cached_script = res;
        } else {
            UtilityFunctions::printerr("Gun: Failed to load ProjectilePhysicsWithDrag script");
        }
    }
    return cached_script;
}

// ============================================================================
// ShootOver Implementation
// ============================================================================

void ShootOver::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_can_shoot_over_terrain"), &ShootOver::get_can_shoot_over_terrain);
    ClassDB::bind_method(D_METHOD("set_can_shoot_over_terrain", "value"), &ShootOver::set_can_shoot_over_terrain);
    ClassDB::bind_method(D_METHOD("get_can_shoot_over_ship"), &ShootOver::get_can_shoot_over_ship);
    ClassDB::bind_method(D_METHOD("set_can_shoot_over_ship", "value"), &ShootOver::set_can_shoot_over_ship);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "can_shoot_over_terrain"), "set_can_shoot_over_terrain", "get_can_shoot_over_terrain");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "can_shoot_over_ship"), "set_can_shoot_over_ship", "get_can_shoot_over_ship");
}

ShootOver::ShootOver() : can_shoot_over_terrain(false), can_shoot_over_ship(false) {}
ShootOver::ShootOver(bool terrain, bool ship) : can_shoot_over_terrain(terrain), can_shoot_over_ship(ship) {}
ShootOver::~ShootOver() {}

// ============================================================================
// Gun Implementation
// ============================================================================

void Gun::_bind_methods() {
    // Signals (none currently, but can be added)

    // Methods
    ClassDB::bind_method(D_METHOD("to_dict"), &Gun::to_dict);
    ClassDB::bind_method(D_METHOD("to_bytes", "full"), &Gun::to_bytes);
    ClassDB::bind_method(D_METHOD("from_dict", "d"), &Gun::from_dict);
    ClassDB::bind_method(D_METHOD("from_bytes", "b", "full"), &Gun::from_bytes);
    ClassDB::bind_method(D_METHOD("get_params"), &Gun::get_params);
    ClassDB::bind_method(D_METHOD("get_shell"), &Gun::get_shell);
    ClassDB::bind_method(D_METHOD("notify_gun_updated"), &Gun::notify_gun_updated);
    ClassDB::bind_method(D_METHOD("cleanup"), &Gun::cleanup);
    ClassDB::bind_method(D_METHOD("update_barrels"), &Gun::update_barrels);

    // Angle functions
    ClassDB::bind_static_method("Gun", D_METHOD("normalize_angle_0_2pi", "angle"), &Gun::normalize_angle_0_2pi);
    ClassDB::bind_static_method("Gun", D_METHOD("normalize_angle_0_2pi_simple", "angle"), &Gun::normalize_angle_0_2pi_simple);
    ClassDB::bind_static_method("Gun", D_METHOD("normalize_angle", "angle"), &Gun::normalize_angle);

    // Rotation limit functions
    ClassDB::bind_method(D_METHOD("apply_rotation_limits", "current_angle", "desired_delta"), &Gun::apply_rotation_limits);
    ClassDB::bind_method(D_METHOD("clamp_to_rotation_limits"), &Gun::clamp_to_rotation_limits);
    ClassDB::bind_method(D_METHOD("apply_rotation_limits_simple", "current_angle", "desired_delta"), &Gun::apply_rotation_limits_simple);
    ClassDB::bind_method(D_METHOD("clamp_to_rotation_limits_simple"), &Gun::clamp_to_rotation_limits_simple);

    // Movement and targeting
    ClassDB::bind_method(D_METHOD("return_to_base", "delta"), &Gun::return_to_base);
    ClassDB::bind_method(D_METHOD("get_angle_to_target", "target"), &Gun::get_angle_to_target);
    ClassDB::bind_method(D_METHOD("valid_target", "target"), &Gun::valid_target);
    ClassDB::bind_method(D_METHOD("valid_target_leading", "target", "target_velocity"), &Gun::valid_target_leading);
    ClassDB::bind_method(D_METHOD("get_muzzles_position"), &Gun::get_muzzles_position);

    // Aiming
    ClassDB::bind_method(D_METHOD("_aim", "aim_point", "delta", "return_to_base"), &Gun::_aim, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("_aim_leading", "aim_point", "vel", "delta"), &Gun::_aim_leading);

    // Firing
    ClassDB::bind_method(D_METHOD("fire", "mod"), &Gun::fire, DEFVAL(Variant()));
    ClassDB::bind_method(D_METHOD("fire_client", "vel", "pos", "t", "_id"), &Gun::fire_client);
    ClassDB::bind_method(D_METHOD("fire_client2", "data"), &Gun::fire_client2);

    // Armor system
    ClassDB::bind_method(D_METHOD("initialize_armor_system"), &Gun::initialize_armor_system);
    ClassDB::bind_method(D_METHOD("extract_and_load_armor_data", "glb_path", "armor_json_path"), &Gun::extract_and_load_armor_data);
    ClassDB::bind_method(D_METHOD("enable_backface_collision_recursive", "node"), &Gun::enable_backface_collision_recursive);

    // Terrain simulation
    ClassDB::bind_method(D_METHOD("sim_can_shoot_over_terrain", "aim_point"), &Gun::sim_can_shoot_over_terrain);
    ClassDB::bind_static_method("Gun", D_METHOD("sim_can_shoot_over_terrain_static", "pos", "launch_vector", "flight_time", "drag", "ship"), &Gun::sim_can_shoot_over_terrain_static);

    // Property getters/setters
    ClassDB::bind_method(D_METHOD("get_barrel_count"), &Gun::get_barrel_count);
    ClassDB::bind_method(D_METHOD("set_barrel_count", "count"), &Gun::set_barrel_count);
    ClassDB::bind_method(D_METHOD("get_barrel_spacing"), &Gun::get_barrel_spacing);
    ClassDB::bind_method(D_METHOD("set_barrel_spacing", "spacing"), &Gun::set_barrel_spacing);
    ClassDB::bind_method(D_METHOD("get_rotation_limits_enabled"), &Gun::get_rotation_limits_enabled);
    ClassDB::bind_method(D_METHOD("set_rotation_limits_enabled", "enabled"), &Gun::set_rotation_limits_enabled);
    ClassDB::bind_method(D_METHOD("get_min_rotation_angle"), &Gun::get_min_rotation_angle);
    ClassDB::bind_method(D_METHOD("set_min_rotation_angle", "angle"), &Gun::set_min_rotation_angle);
    ClassDB::bind_method(D_METHOD("get_max_rotation_angle"), &Gun::get_max_rotation_angle);
    ClassDB::bind_method(D_METHOD("set_max_rotation_angle", "angle"), &Gun::set_max_rotation_angle);

    ClassDB::bind_method(D_METHOD("get_aim_point"), &Gun::get_aim_point);
    ClassDB::bind_method(D_METHOD("set_aim_point", "aim"), &Gun::set_aim_point);
    ClassDB::bind_method(D_METHOD("get_reload"), &Gun::get_reload);
    ClassDB::bind_method(D_METHOD("set_reload", "reload"), &Gun::set_reload);
    ClassDB::bind_method(D_METHOD("get_can_fire"), &Gun::get_can_fire);
    ClassDB::bind_method(D_METHOD("set_can_fire", "can_fire"), &Gun::set_can_fire);
    ClassDB::bind_method(D_METHOD("get_valid_target"), &Gun::get_valid_target);
    ClassDB::bind_method(D_METHOD("set_valid_target", "valid"), &Gun::set_valid_target);
    ClassDB::bind_method(D_METHOD("get_muzzles"), &Gun::get_muzzles);
    ClassDB::bind_method(D_METHOD("set_muzzles", "muzzles"), &Gun::set_muzzles);
    ClassDB::bind_method(D_METHOD("get_gun_id"), &Gun::get_gun_id);
    ClassDB::bind_method(D_METHOD("set_gun_id", "id"), &Gun::set_gun_id);
    ClassDB::bind_method(D_METHOD("get_disabled"), &Gun::get_disabled);
    ClassDB::bind_method(D_METHOD("set_disabled", "disabled"), &Gun::set_disabled);
    ClassDB::bind_method(D_METHOD("get_base_rotation"), &Gun::get_base_rotation);
    ClassDB::bind_method(D_METHOD("set_base_rotation", "rotation"), &Gun::set_base_rotation);
    ClassDB::bind_method(D_METHOD("get_ship"), &Gun::get_ship);
    ClassDB::bind_method(D_METHOD("set_ship", "ship"), &Gun::set_ship);
    ClassDB::bind_method(D_METHOD("get_id"), &Gun::get_id);
    ClassDB::bind_method(D_METHOD("set_id", "id"), &Gun::set_id);
    ClassDB::bind_method(D_METHOD("get_armor_system"), &Gun::get_armor_system);
    ClassDB::bind_method(D_METHOD("set_armor_system", "armor"), &Gun::set_armor_system);
    ClassDB::bind_method(D_METHOD("get_ship_model_glb_path"), &Gun::get_ship_model_glb_path);
    ClassDB::bind_method(D_METHOD("set_ship_model_glb_path", "path"), &Gun::set_ship_model_glb_path);
    ClassDB::bind_method(D_METHOD("get_auto_extract_armor"), &Gun::get_auto_extract_armor);
    ClassDB::bind_method(D_METHOD("set_auto_extract_armor", "auto"), &Gun::set_auto_extract_armor);
    ClassDB::bind_method(D_METHOD("get_controller"), &Gun::get_controller);
    ClassDB::bind_method(D_METHOD("set_controller", "controller"), &Gun::set_controller);
    ClassDB::bind_method(D_METHOD("get_shell_sim"), &Gun::get_shell_sim);
    ClassDB::bind_method(D_METHOD("set_shell_sim", "shell"), &Gun::set_shell_sim);
    ClassDB::bind_method(D_METHOD("get_sim_shell_in_flight"), &Gun::get_sim_shell_in_flight);
    ClassDB::bind_method(D_METHOD("set_sim_shell_in_flight", "in_flight"), &Gun::set_sim_shell_in_flight);
    ClassDB::bind_method(D_METHOD("get_barrel"), &Gun::get_barrel);
    ClassDB::bind_method(D_METHOD("set_barrel", "barrel"), &Gun::set_barrel);

    // Export properties
    ADD_PROPERTY(PropertyInfo(Variant::INT, "barrel_count"), "set_barrel_count", "get_barrel_count");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "barrel_spacing"), "set_barrel_spacing", "get_barrel_spacing");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "rotation_limits_enabled"), "set_rotation_limits_enabled", "get_rotation_limits_enabled");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_rotation_angle", PROPERTY_HINT_RANGE, "-6.28318,6.28318,0.01,radians_as_degrees"), "set_min_rotation_angle", "get_min_rotation_angle");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_rotation_angle", PROPERTY_HINT_RANGE, "-6.28318,6.28318,0.01,radians_as_degrees"), "set_max_rotation_angle", "get_max_rotation_angle");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "ship_model_glb_path", PROPERTY_HINT_FILE, "*.glb"), "set_ship_model_glb_path", "get_ship_model_glb_path");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_extract_armor"), "set_auto_extract_armor", "get_auto_extract_armor");

    // Regular properties
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "_aim_point"), "set_aim_point", "get_aim_point");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "reload"), "set_reload", "get_reload");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "can_fire"), "set_can_fire", "get_can_fire");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_valid_target"), "set_valid_target", "get_valid_target");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "muzzles", PROPERTY_HINT_ARRAY_TYPE, "Node3D"), "set_muzzles", "get_muzzles");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "gun_id"), "set_gun_id", "get_gun_id");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "disabled"), "set_disabled", "get_disabled");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "base_rotation"), "set_base_rotation", "get_base_rotation");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "_ship", PROPERTY_HINT_NODE_TYPE, "Node"), "set_ship", "get_ship");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "id"), "set_id", "get_id");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "armor_system", PROPERTY_HINT_NODE_TYPE, "Node"), "set_armor_system", "get_armor_system");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "controller", PROPERTY_HINT_NODE_TYPE, "Node"), "set_controller", "get_controller");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shell_sim", PROPERTY_HINT_RESOURCE_TYPE, "SimShell"), "set_shell_sim", "get_shell_sim");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sim_shell_in_flight"), "set_sim_shell_in_flight", "get_sim_shell_in_flight");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "barrel", PROPERTY_HINT_NODE_TYPE, "Node3D"), "set_barrel", "get_barrel");
}

Gun::Gun() {
    min_rotation_angle = Math::deg_to_rad(90.0);
    max_rotation_angle = Math::deg_to_rad(180.0);
    shell_sim.instantiate();
}

Gun::~Gun() {}

// Handle notifications for proper initialization timing
void Gun::_notification(int p_what) {
    if (Engine::get_singleton()->is_editor_hint()) {
        return;
    }

    switch (p_what) {
        case NOTIFICATION_ENTER_TREE:
            // Nothing special needed on enter_tree for Gun currently
            break;
        case NOTIFICATION_READY:
            _initialize_onready_vars();
            _on_ready();
            break;
        case NOTIFICATION_PHYSICS_PROCESS:
            _physics_process(get_physics_process_delta_time());
            break;
    }
}

// Game logic called from NOTIFICATION_READY
void Gun::_on_ready() {
    // Enable physics processing first
    set_physics_process(true);

    // Set up muzzles
    update_barrels();

    // Set processing mode based on authority
    // Call _Utils.authority() via GDScript autoload
    Node* utils = get_tree()->get_root()->get_node_or_null(NodePath("_Utils"));
    bool is_authority = true;
    if (utils) {
        is_authority = utils->call("authority");
    }

    if (is_authority) {
        set_process_mode(Node::PROCESS_MODE_INHERIT);
    } else {
        set_process_mode(Node::PROCESS_MODE_INHERIT);
        set_physics_process(false);
    }

    // Deferred calls
    call_deferred("initialize_armor_system");
    call_deferred("cleanup");
}

void Gun::_initialize_onready_vars() {
	UtilityFunctions::print("Gun::_initialize_onready_vars() called for: ", get_path());
    if (onready_initialized) {
        return;
    }

    Node* first_child = get_child_count() > 0 ? get_child(0) : nullptr;
    UtilityFunctions::print("  First child: ", first_child ? first_child->get_name() : "null");
    if (first_child && first_child->get_child_count() > 0) {
        barrel = Object::cast_to<Node3D>(first_child->get_child(0));
        UtilityFunctions::print("  Barrel assigned to: ", barrel ? barrel->get_name() : "null");
    }
    UtilityFunctions::print("  Barrels is now: ", barrel);

    onready_initialized = true;
}

void Gun::_ensure_onready() {
    if (!onready_initialized && is_inside_tree()) {
        _initialize_onready_vars();
    }
}

Node3D* Gun::get_barrel() {
    _ensure_onready();
    return barrel;
}

void Gun::_physics_process(double delta) {
    // Call _Utils.authority() via GDScript autoload
    Node* utils = get_tree()->get_root()->get_node_or_null(NodePath("_Utils"));
    bool is_authority = true;
    if (utils) {
        is_authority = utils->call("authority");
    }

    if (is_authority) {
        if (!disabled && reload < 1.0) {
            Ref<Resource> params = get_params();
            if (params.is_valid()) {
                double reload_time = params->get("reload_time");
                reload = Math::min(reload + delta / reload_time, 1.0);
            }
        }
    }
}

Dictionary Gun::to_dict() const {
    Dictionary result;
    result["r"] = get_basis();
    if (barrel) {
        result["e"] = barrel->get_basis();
    }
    result["c"] = can_fire;
    result["v"] = _valid_target;
    result["rl"] = reload;
    return result;
}

PackedByteArray Gun::to_bytes(bool full) const {
    Ref<StreamPeerBuffer> writer;
    writer.instantiate();

    writer->put_float(get_rotation().y);

    if (barrel) {
        writer->put_float(barrel->get_rotation().x);
    } else {
        writer->put_float(0.0f);
    }

    if (full) {
        writer->put_u8(can_fire ? 1 : 0);
        writer->put_u8(_valid_target ? 1 : 0);
        writer->put_float(reload);
    }

    return writer->get_data_array();
}

void Gun::from_dict(const Dictionary& d) {
    set_basis(d["r"]);
    if (barrel) {
        barrel->set_basis(d["e"]);
    }
    can_fire = d["c"];
    _valid_target = d["v"];
    reload = d["rl"];
}

void Gun::from_bytes(const PackedByteArray& b, bool full) {
    Ref<StreamPeerBuffer> reader;
    reader.instantiate();
    reader->set_data_array(b);

    Vector3 rot = get_rotation();
    rot.y = reader->get_float();
    set_rotation(rot);

    if (barrel) {
        Vector3 barrel_rot = barrel->get_rotation();
        barrel_rot.x = reader->get_float();
        barrel->set_rotation(barrel_rot);
    } else {
        reader->get_float();  // Skip the value
    }

    if (!full) {
        return;
    }

    can_fire = reader->get_u8() == 1;
    _valid_target = reader->get_u8() == 1;
    reload = reader->get_float();
}

Ref<Resource> Gun::get_params() const {
    if (controller) {
        return controller->call("get_params");
    }
    return Ref<Resource>();
}

Ref<Resource> Gun::get_shell() const {
    if (controller) {
        return controller->call("get_shell_params");
    }
    return Ref<Resource>();
}

void Gun::notify_gun_updated() {
    Node* server = get_tree()->get_root()->get_node_or_null(NodePath("Server"));
    Node* utils = get_tree()->get_root()->get_node_or_null(NodePath("_Utils"));
    bool is_authority = true;
    if (utils) {
        is_authority = utils->call("authority");
    }

    if (server != nullptr && is_authority) {
        server->set("gun_updated", true);
    }
}

void Gun::cleanup() {
    // Don't run in editor - this corrupts scenes
    if (Engine::get_singleton()->is_editor_hint()) {
        return;
    }

    // Detach from parent for easier management
    Node* grand_parent = get_parent() ? get_parent()->get_parent() : nullptr;
    Node* parent = get_parent();

    if (!grand_parent || !parent) {
        return;
    }

    Transform3D saved_transform = get_global_transform();

    // Preserve the original owner before reparenting
    Node* original_owner = get_owner();
    if (original_owner == nullptr) {
        original_owner = grand_parent->get_owner();
    }
    if (original_owner == nullptr) {
        original_owner = get_tree()->get_current_scene();
    }

    // Remove self from parent first
    parent->remove_child(this);
    // Add self to grandparent
    grand_parent->add_child(this);
    // Now safe to remove and free the old parent
    grand_parent->remove_child(parent);
    parent->queue_free();

    // Restore transform
    set_global_transform(saved_transform);

    // Set owner for Remote inspector visibility
    if (original_owner != nullptr) {
        set_owner(original_owner);
        // Also set owner on all children recursively
        TypedArray<Node> children = find_children("*", "", true, false);
        for (int i = 0; i < children.size(); i++) {
            Node* child = Object::cast_to<Node>(children[i]);
            if (child != nullptr) {
                child->set_owner(original_owner);
            }
        }
    }

    base_rotation = get_rotation().y;

    call_deferred("notify_gun_updated");
}

void Gun::update_barrels() {
    // Clear existing muzzles array
    muzzles.clear();

    // Check if barrel exists
    if (!is_node_ready()) {
        return;
    }

    _ensure_onready();

    if (barrel) {
        for (int i = 0; i < barrel->get_child_count(); i++) {
            Node3D* muzzle = Object::cast_to<Node3D>(barrel->get_child(i));
            if (muzzle) {
                muzzles.append(muzzle);
            }
        }
    }
}

// Normalize angle to the range [0, 2π]
double Gun::normalize_angle_0_2pi(double angle) {
    while (angle < 0) {
        angle += Math_TAU;
    }
    while (angle >= Math_TAU) {
        angle -= Math_TAU;
    }
    return angle;
}

double Gun::normalize_angle_0_2pi_simple(double angle) {
    return Math::fmod(angle + Math_TAU * 1000.0, Math_TAU);
}

double Gun::normalize_angle(double angle) {
    return Math::wrapf(angle, -Math_PI, Math_PI);
}

// Apply rotation limits to a desired rotation
Array Gun::apply_rotation_limits(double current_angle, double desired_delta) const {
    Array result;

    // If rotation limits are not enabled, return the desired delta as is
    if (!rotation_limits_enabled || desired_delta == 0) {
        result.append(desired_delta);
        result.append(false);
        return result;
    }

    // Normalize the current angle to [0, 2π]
    double normalized_current = normalize_angle_0_2pi(current_angle);

    // Calculate the target angle after applying the delta
    double target_angle = normalize_angle_0_2pi(normalized_current + desired_delta);

    // Check if the target angle is in the valid region
    bool is_target_valid = false;
    if (min_rotation_angle <= max_rotation_angle) {
        // Valid region is [min, max]
        is_target_valid = (target_angle >= min_rotation_angle && target_angle <= max_rotation_angle);
    } else {
        // Valid region wraps around: [min, 2π] ∪ [0, max]
        is_target_valid = (target_angle >= min_rotation_angle || target_angle <= max_rotation_angle);
    }

    // If target is valid, check if the rotation path crosses the invalid region
    if (is_target_valid) {
        bool crosses_invalid = false;

        if (min_rotation_angle <= max_rotation_angle) {
            // The invalid region is [0, min) ∪ (max, 2π)
            double invalid_region = Math_TAU - (max_rotation_angle - min_rotation_angle);
            if (desired_delta > 0) {  // Clockwise rotation
                crosses_invalid = normalized_current <= max_rotation_angle + 0.01 &&
                                  normalized_current + desired_delta > max_rotation_angle + invalid_region;
            } else {  // Counter-clockwise rotation
                crosses_invalid = normalized_current >= min_rotation_angle - 0.01 &&
                                  normalized_current + desired_delta < min_rotation_angle - invalid_region;
            }
        } else {
            // The invalid region is (max, min)
            if (desired_delta > 0) {  // Clockwise rotation
                if (normalized_current <= max_rotation_angle) {
                    crosses_invalid = (normalized_current + desired_delta) > min_rotation_angle;
                } else {
                    crosses_invalid = false;
                }
            } else {  // Counter-clockwise rotation
                if (normalized_current >= min_rotation_angle) {
                    crosses_invalid = (normalized_current + desired_delta) < max_rotation_angle;
                } else {
                    crosses_invalid = false;
                }
            }
        }

        if (crosses_invalid) {
            // If we would cross the invalid region, go the other way around the circle
            if (desired_delta > 0) {
                result.append(desired_delta - Math_TAU);
            } else {
                result.append(desired_delta + Math_TAU);
            }
            result.append(false);
            return result;
        } else {
            result.append(desired_delta);
            result.append(false);
            return result;
        }
    } else {
        // Target is in the invalid region, find the nearest valid boundary
        double dist_to_min = Math::min(Math::abs(target_angle - min_rotation_angle),
                                        Math_TAU - Math::abs(target_angle - min_rotation_angle));
        double dist_to_max = Math::min(Math::abs(target_angle - max_rotation_angle),
                                        Math_TAU - Math::abs(target_angle - max_rotation_angle));

        if (min_rotation_angle <= max_rotation_angle) {
            if (dist_to_min <= dist_to_max) {
                result.append(min_rotation_angle - normalized_current);
            } else {
                result.append(max_rotation_angle - normalized_current);
            }
        } else {
            if (dist_to_min <= dist_to_max) {
                result.append(-normalize_angle_0_2pi(Math_TAU - (min_rotation_angle - normalized_current)));
            } else {
                result.append(normalize_angle_0_2pi(Math_TAU - (max_rotation_angle - normalized_current)));
            }
        }
        result.append(true);
        return result;
    }
}

void Gun::clamp_to_rotation_limits() {
    if (!rotation_limits_enabled) {
        return;
    }

    double normalized_current = normalize_angle_0_2pi(get_rotation().y);

    bool is_valid = false;
    if (min_rotation_angle <= max_rotation_angle) {
        is_valid = (normalized_current >= min_rotation_angle && normalized_current <= max_rotation_angle);
    } else {
        is_valid = (normalized_current >= min_rotation_angle || normalized_current <= max_rotation_angle);
    }

    if (!is_valid) {
        double dist_to_min = Math::min(Math::abs(normalized_current - min_rotation_angle),
                                        Math_TAU - Math::abs(normalized_current - min_rotation_angle));
        double dist_to_max = Math::min(Math::abs(normalized_current - max_rotation_angle),
                                        Math_TAU - Math::abs(normalized_current - max_rotation_angle));

        Vector3 rot = get_rotation();
        if (dist_to_min <= dist_to_max) {
            rot.y = min_rotation_angle;
        } else {
            rot.y = max_rotation_angle;
        }
        set_rotation(rot);
    }
}

Array Gun::apply_rotation_limits_simple(double current_angle, double desired_delta) const {
    Array result;

    if (!rotation_limits_enabled || desired_delta == 0) {
        result.append(desired_delta);
        result.append(false);
        return result;
    }

    double current = normalize_angle_0_2pi_simple(current_angle);
    double target = normalize_angle_0_2pi_simple(current + desired_delta);

    bool is_valid = false;
    if (min_rotation_angle <= max_rotation_angle) {
        is_valid = target >= min_rotation_angle && target <= max_rotation_angle;
    } else {
        is_valid = target >= min_rotation_angle || target <= max_rotation_angle;
    }

    if (is_valid) {
        bool crosses_invalid = false;

        if (min_rotation_angle <= max_rotation_angle) {
            if (desired_delta > 0) {
                if (current >= min_rotation_angle && current <= max_rotation_angle) {
                    double steps_to_max = max_rotation_angle - current;
                    crosses_invalid = desired_delta > steps_to_max && desired_delta > (Math_TAU - current + target);
                }
            } else {
                if (current >= min_rotation_angle && current <= max_rotation_angle) {
                    double steps_to_min = current - min_rotation_angle;
                    crosses_invalid = Math::abs(desired_delta) > steps_to_min &&
                                      Math::abs(desired_delta) > (current + Math_TAU - target);
                }
            }
        } else {
            if (desired_delta > 0 && current <= max_rotation_angle) {
                crosses_invalid = target >= min_rotation_angle && (current + desired_delta) > min_rotation_angle;
            } else if (desired_delta < 0 && current >= min_rotation_angle) {
                crosses_invalid = target <= max_rotation_angle && (current + desired_delta) < max_rotation_angle;
            }
        }

        if (crosses_invalid) {
            result.append(desired_delta + (desired_delta < 0 ? Math_TAU : -Math_TAU));
            result.append(false);
        } else {
            result.append(desired_delta);
            result.append(false);
        }
        return result;
    } else {
        double to_min = min_rotation_angle - current;
        double to_max = max_rotation_angle - current;

        if (Math::abs(to_min) > Math_PI) {
            to_min += to_min < 0 ? Math_TAU : -Math_TAU;
        }
        if (Math::abs(to_max) > Math_PI) {
            to_max += to_max < 0 ? Math_TAU : -Math_TAU;
        }

        result.append(Math::abs(to_min) <= Math::abs(to_max) ? to_min : to_max);
        result.append(true);
        return result;
    }
}

void Gun::clamp_to_rotation_limits_simple() {
    if (!rotation_limits_enabled) {
        return;
    }

    double current = normalize_angle_0_2pi_simple(get_rotation().y);
    bool is_valid = false;

    if (min_rotation_angle <= max_rotation_angle) {
        is_valid = current >= min_rotation_angle && current <= max_rotation_angle;
    } else {
        is_valid = current >= min_rotation_angle || current <= max_rotation_angle;
    }

    if (!is_valid) {
        double to_min = Math::abs(current - min_rotation_angle);
        double to_max = Math::abs(current - max_rotation_angle);

        to_min = Math::min(to_min, Math_TAU - to_min);
        to_max = Math::min(to_max, Math_TAU - to_max);

        Vector3 rot = get_rotation();
        rot.y = to_min <= to_max ? min_rotation_angle : max_rotation_angle;
        set_rotation(rot);
    }
}

void Gun::return_to_base(double delta) {
    Ref<Resource> params = get_params();
    if (!params.is_valid()) {
        return;
    }

    double traverse_speed = params->get("traverse_speed");
    double turret_rot_speed_rad = Math::deg_to_rad(traverse_speed);
    double max_turret_angle_delta = turret_rot_speed_rad * delta;
    double adjusted_angle = base_rotation - get_rotation().y;

    if (Math::abs(adjusted_angle) > Math_PI) {
        adjusted_angle = -Math::sign(adjusted_angle) * (Math_TAU - Math::abs(adjusted_angle));
    }

    double turret_angle_delta = Math::clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta);
    rotate(Vector3(0, 1, 0), turret_angle_delta);
    can_fire = false;
}

double Gun::get_angle_to_target(const Vector3& target) const {
    Vector3 forward = -get_global_basis().get_column(2).normalized();
    Vector2 forward_2d = Vector2(forward.x, forward.z).normalized();
    Vector3 target_dir = (target - get_global_position()).normalized();
    Vector2 target_dir_2d = Vector2(target_dir.x, target_dir.z).normalized();
    double desired_local_angle_delta = target_dir_2d.angle_to(forward_2d);
    return desired_local_angle_delta;
}

bool Gun::valid_target(const Vector3& target) const {
    Ref<Resource> shell = get_shell();
    Ref<Resource> params = get_params();
    if (!shell.is_valid() || !params.is_valid()) {
        return false;
    }

    // Call ProjectilePhysicsWithDrag.calculate_launch_vector via GDScript static method
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
        return false;
    }

    double speed = shell->get("speed");
    double drag = shell->get("drag");
    double range = params->get("_range");

    Array sol = projectile_physics->call("calculate_launch_vector", get_global_position(), target, speed, drag);

    if (sol.size() > 0 && sol[0].get_type() != Variant::NIL &&
        (target - get_global_position()).length() < range) {
        double desired_local_angle_delta = get_angle_to_target(target);
        Array a = apply_rotation_limits(get_rotation().y, desired_local_angle_delta);
        if ((bool)a[1]) {
            return false;
        }
        return true;
    }
    return false;
}

bool Gun::valid_target_leading(const Vector3& target, const Vector3& target_velocity) const {
    Ref<Resource> shell = get_shell();
    Ref<Resource> params = get_params();
    if (!shell.is_valid() || !params.is_valid()) {
        return false;
    }

    // Call ProjectilePhysicsWithDrag.calculate_leading_launch_vector via GDScript static method
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
        return false;
    }

    double speed = shell->get("speed");
    double drag = shell->get("drag");
    double range = params->get("_range");

    Array sol = projectile_physics->call("calculate_leading_launch_vector", get_global_position(), target, target_velocity, speed, drag);

    if (sol.size() > 2 && sol[0].get_type() != Variant::NIL) {
        Vector3 aim_point = sol[2];
        if ((aim_point - get_global_position()).length() < range) {
            double desired_local_angle_delta = get_angle_to_target(aim_point);
            Array a = apply_rotation_limits(get_rotation().y, desired_local_angle_delta);
            if ((bool)a[1]) {
                return false;
            }
            return true;
        }
    }
    return false;
}

Vector3 Gun::get_muzzles_position() const {
    Vector3 muzzles_pos = Vector3();
    int count = muzzles.size();
    if (count == 0) {
        return get_global_position();
    }

    for (int i = 0; i < count; i++) {
        Node3D* m = Object::cast_to<Node3D>(muzzles[i]);
        if (m) {
            muzzles_pos += m->get_global_position();
        }
    }
    muzzles_pos /= (double)count;
    return muzzles_pos;
}

void Gun::_aim(const Vector3& aim_point, double delta, bool return_to_base_flag) {

	// UtilityFunctions::print("Gun::_aim called for: ", get_path(), " with aim_point: ", aim_point, " delta: ", delta, " return_to_base_flag: ", return_to_base_flag);

    if (disabled) {
        return;
    }

    Ref<Resource> params = get_params();
    Ref<Resource> shell = get_shell();
    if (!params.is_valid() || !shell.is_valid()) {
        return;
    }

    double traverse_speed = params->get("traverse_speed");
    double elevation_speed = params->get("elevation_speed");
    double range = params->get("_range");
    double speed = shell->get("speed");
    double drag = shell->get("drag");

    // Calculate turret rotation
    double turret_rot_speed_rad = Math::deg_to_rad(traverse_speed);
    double max_turret_angle_delta = turret_rot_speed_rad * delta;

    double desired_local_angle_delta = get_angle_to_target(aim_point);

    // Apply rotation limits
    Array a = apply_rotation_limits(get_rotation().y, desired_local_angle_delta);
    double adjusted_angle = a[0];
    _valid_target = !(bool)a[1];

    double turret_angle_delta = Math::clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta);

    if (return_to_base_flag && !_valid_target) {
        adjusted_angle = base_rotation - get_rotation().y;
        if (Math::abs(adjusted_angle) > Math_PI) {
            adjusted_angle = -Math::sign(adjusted_angle) * (Math_TAU - Math::abs(adjusted_angle));
        }
        _valid_target = !(bool)a[1];
        turret_angle_delta = Math::clamp(adjusted_angle, -max_turret_angle_delta, max_turret_angle_delta);
    }

    // Apply rotation
    rotate(Vector3(0, 1, 0), turret_angle_delta);

    // Ensure rotation is within limits
    clamp_to_rotation_limits();

    Vector3 muzzles_pos = get_muzzles_position();

    // Get projectile physics script for static method calls
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
    	UtilityFunctions::print("Gun::_aim: projectile_physics script is null");
        return;
    }

    // Existing aiming logic for elevation
    Array sol = projectile_physics->call("calculate_launch_vector", muzzles_pos, aim_point, speed, drag);

    if (sol.size() > 0 && sol[0].get_type() != Variant::NIL && (aim_point - muzzles_pos).length() < range) {
        _aim_point = aim_point;
    } else {
        Vector3 g = Vector3(get_global_position().x, 0, get_global_position().z);
        Vector3 aim_2d = Vector3(aim_point.x, 0, aim_point.z);
        _aim_point = g + (aim_2d - g).normalized() * (range - 500.0);
        sol = projectile_physics->call("calculate_launch_vector", muzzles_pos, _aim_point, speed, drag);
    }
    // UtilityFunctions::print("Gun::_aim: Sol is ", sol);

    double turret_elev_speed_rad = Math::deg_to_rad(elevation_speed);
    double max_elev_angle = turret_elev_speed_rad * delta;
    double elevation_delta = max_elev_angle;

    if (sol.size() > 1 && sol[1].operator double() != -1) {
    	// UtilityFunctions::print("Gun::_aim: calculating elevation delta");
        Vector3 barrel_dir = sol[0];
        Vector2 elevation = Vector2(Vector2(barrel_dir.x, barrel_dir.z).length(), barrel_dir.y).normalized();

        if (barrel) {
            Vector3 barrel_z = barrel->get_global_basis().get_column(2);
            Vector2 curr_elevation = Vector2(Vector2(barrel_z.x, barrel_z.z).length(), -barrel_z.y).normalized();
            double elevation_angle = curr_elevation.angle_to(elevation);
            elevation_delta = Math::clamp(elevation_angle, -max_elev_angle, max_elev_angle);
        }
    }

    if (sol.size() > 0 && sol[0].get_type() == Variant::NIL) {
        elevation_delta = -max_elev_angle;
    }

    if (std::isnan(elevation_delta)) {
        elevation_delta = 0.0;
    }

    if (barrel) {
    	// UtilityFunctions::print("Gun::_aim: rotating barrel by elevation delta: ", elevation_delta);
        barrel->rotate(Vector3(1, 0, 0), elevation_delta);
    }

    if (Math::abs(elevation_delta) < 0.02 && Math::abs(desired_local_angle_delta) < 0.02 && _valid_target) {
        can_fire = true;
    } else {
        can_fire = false;
    }
}

void Gun::_aim_leading(const Vector3& aim_point, const Vector3& vel, double delta) {
    Ref<Resource> shell = get_shell();
    Ref<Resource> params = get_params();
    if (!shell.is_valid() || !params.is_valid()) {
        return;
    }

    double speed = shell->get("speed");
    double drag = shell->get("drag");
    double range = params->get("_range");

    Vector3 muzzles_pos = get_muzzles_position();

    // Get projectile physics script for static method calls
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
        return;
    }

    Array sol = projectile_physics->call("calculate_leading_launch_vector", muzzles_pos, aim_point, vel, speed, drag);

    if (sol.size() < 3 || sol[0].get_type() == Variant::NIL || (aim_point - muzzles_pos).length() > range) {
        can_fire = false;
        return;
    }

    _aim(sol[2], delta, true);
}

void Gun::fire(Object* mod) {
    Node* utils = get_tree()->get_root()->get_node_or_null(NodePath("_Utils"));
    bool is_authority = true;
    if (utils) {
        is_authority = utils->call("authority");
    }

    if (!is_authority) {
        return;
    }

    if (!disabled && reload >= 1.0 && can_fire) {
        Ref<Resource> params = get_params();
        Ref<Resource> shell = get_shell();
        if (!params.is_valid() || !shell.is_valid()) {
            return;
        }

        Vector3 muzzles_pos = get_muzzles_position();

        for (int i = 0; i < muzzles.size(); i++) {
            Node3D* m = Object::cast_to<Node3D>(muzzles[i]);
            if (!m) continue;

            // Get shell_index from controller
            int shell_index = 0;
            if (controller) {
                shell_index = controller->get("shell_index");
            }

            // Call calculate_dispersed_launch on params
            Variant dispersed_velocity = params->call("calculate_dispersed_launch", _aim_point, muzzles_pos, shell_index, mod);

            if (dispersed_velocity.get_type() != Variant::NIL) {
                double t = Time::get_singleton()->get_unix_time_from_system();

                // Call ProjectileManager.fireBullet
                Node* projectile_manager = get_tree()->get_root()->get_node_or_null(NodePath("ProjectileManager"));
                if (projectile_manager) {
                    int _id = projectile_manager->call("fireBullet", dispersed_velocity, m->get_global_position(), shell, t, _ship);

                    // Call TcpThreadPool.send_fire_gun
                    Node* tcp_pool = get_tree()->get_root()->get_node_or_null(NodePath("TcpThreadPool"));
                    if (tcp_pool) {
                        tcp_pool->call("send_fire_gun", id, dispersed_velocity, m->get_global_position(), t, _id);
                    }
                }
            }
        }
        reload = 0;
    }
}

void Gun::fire_client(const Vector3& vel, const Vector3& pos, double t, int _id) {
    Ref<Resource> shell = get_shell();
    if (!shell.is_valid()) {
        return;
    }

    Node* projectile_manager = get_tree()->get_root()->get_node_or_null(NodePath("ProjectileManager"));
    if (projectile_manager && barrel) {
        projectile_manager->call("fireBulletClient", pos, vel, t, _id, shell, _ship, true, barrel->get_global_basis());
    }
}

void Gun::fire_client2(const PackedByteArray& data) {
    if (data.size() != 36) {
        UtilityFunctions::print("Invalid fire_client2 data size: ", data.size());
        return;
    }

    Ref<StreamPeerBuffer> stream;
    stream.instantiate();
    stream->set_data_array(data);

    Vector3 vel = Vector3(stream->get_float(), stream->get_float(), stream->get_float());
    Vector3 pos = Vector3(stream->get_float(), stream->get_float(), stream->get_float());
    double t = stream->get_double();
    int _id = stream->get_32();

    Ref<Resource> shell = get_shell();
    if (!shell.is_valid()) {
        return;
    }

    Node* projectile_manager = get_tree()->get_root()->get_node_or_null(NodePath("ProjectileManager"));
    if (projectile_manager && barrel) {
        projectile_manager->call("fireBulletClient", pos, vel, t, _id, shell, _ship, true, barrel->get_global_basis());
    }
}

void Gun::initialize_armor_system() {
    // Don't run in editor
    if (Engine::get_singleton()->is_editor_hint()) {
        return;
    }

    if (!_ship) {
        return;
    }

    // Resolve the GLB path
    String resolved_glb_path = _ship->call("resolve_glb_path", ship_model_glb_path);
    if (resolved_glb_path.is_empty()) {
        UtilityFunctions::print("   Invalid or missing GLB path: ", ship_model_glb_path);
        return;
    }

    // Create armor system instance - load the ArmorSystemV2 script
    Ref<Script> armor_script = ResourceLoader::get_singleton()->load("res://src/armor/armor_system_v2.gd");
    if (!armor_script.is_valid()) {
        UtilityFunctions::print("   Failed to load ArmorSystemV2 script");
        return;
    }

    armor_system = memnew(Node);
    armor_system->set_script(armor_script);
    add_child(armor_system);

    // Determine paths
    String model_name = resolved_glb_path.get_file().get_basename();
    String ship_dir = resolved_glb_path.get_base_dir();
    String armor_json_path = ship_dir + "/" + model_name + "_armor.json";

    // Check if armor JSON already exists
    if (FileAccess::file_exists(armor_json_path)) {
        bool success = armor_system->call("load_armor_data", armor_json_path);
        if (!success) {
            UtilityFunctions::print("   Failed to load existing armor data");
        }
    } else if (auto_extract_armor) {
        extract_and_load_armor_data(resolved_glb_path, armor_json_path);
    } else {
        UtilityFunctions::print("   No armor data found and auto-extraction disabled");
    }

    enable_backface_collision_recursive(this);
    UtilityFunctions::print("done");
}

void Gun::extract_and_load_armor_data(const String& glb_path, const String& armor_json_path) {
    // Load the extractor script
    Ref<Script> extractor_script = ResourceLoader::get_singleton()->load("res://src/armor/enhanced_armor_extractor_v2.gd");
    if (!extractor_script.is_valid()) {
        UtilityFunctions::print("      Failed to load armor extractor script");
        return;
    }

    // Create extractor instance
    Node* extractor = memnew(Node);
    extractor->set_script(extractor_script);

    bool success = extractor->call("extract_armor_with_mapping_to_json", glb_path, armor_json_path);

    if (success && armor_system) {
        success = armor_system->call("load_armor_data", armor_json_path);
        if (!success) {
            UtilityFunctions::print("      Failed to load extracted armor data");
        }
    } else if (!success) {
        UtilityFunctions::print("      Armor extraction failed");
    }

    memdelete(extractor);
}

void Gun::enable_backface_collision_recursive(Node* node) {
    // Build path from node to this
    String path = "";
    Node* n = node;
    while (n != this) {
        path = String(n->get_name()) + "/" + path;
        n = n->get_parent();
        if (!n) break;
    }
    path = path.rstrip("/");

    // Check if this path is in armor_data
    if (armor_system) {
        Dictionary armor_data = armor_system->get("armor_data");
        MeshInstance3D* mesh_instance = Object::cast_to<MeshInstance3D>(node);

        if (armor_data.has(path) && mesh_instance) {
            StaticBody3D* static_body = Object::cast_to<StaticBody3D>(node->find_child("StaticBody3D", false));
            if (static_body) {
                CollisionShape3D* collision_shape = Object::cast_to<CollisionShape3D>(static_body->find_child("CollisionShape3D", false));
                if (collision_shape) {
                    static_body->remove_child(collision_shape);

                    Ref<ConcavePolygonShape3D> concave_shape = Object::cast_to<ConcavePolygonShape3D>(collision_shape->get_shape().ptr());
                    if (concave_shape.is_valid()) {
                        concave_shape->set_backface_collision_enabled(true);
                    }

                    static_body->queue_free();

                    // Create ArmorPart - load the script
                    Ref<Script> armor_part_script = ResourceLoader::get_singleton()->load("res://src/armor/armor_part.gd");
                    if (armor_part_script.is_valid()) {
                        StaticBody3D* armor_part = memnew(StaticBody3D);
                        armor_part->set_script(armor_part_script);
                        armor_part->add_child(collision_shape);
                        armor_part->set_collision_layer(1 << 1);
                        armor_part->set_collision_mask(0);
                        armor_part->set("armor_system", armor_system);
                        armor_part->set("armor_path", path);
                        armor_part->set("ship", _ship);

                        add_child(armor_part);

                        if (_ship) {
                            TypedArray<Node> parts = _ship->get_armor_parts();
                            parts.append(armor_part);
                            _ship->set_armor_parts(parts);
                        }
                    }
                }
            }
        }
    }

    // Recurse into children
    for (int i = 0; i < node->get_child_count(); i++) {
        enable_backface_collision_recursive(node->get_child(i));
    }
}

bool Gun::sim_can_shoot_over_terrain(const Vector3& aim_point) {
    Ref<Resource> shell = get_shell();
    if (!shell.is_valid()) {
        return false;
    }

    double speed = shell->get("speed");
    double drag = shell->get("drag");

    Vector3 muzzles_pos = get_muzzles_position();

    // Get projectile physics script for static method calls
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
        return false;
    }

    Array sol = projectile_physics->call("calculate_launch_vector", muzzles_pos, aim_point, speed, drag);

    if (sol.size() < 2 || sol[0].get_type() == Variant::NIL) {
        return false;
    }

    Vector3 launch_vector = sol[0];
    double flight_time = sol[1];

    Ref<ShootOver> can_shoot = sim_can_shoot_over_terrain_static(muzzles_pos, launch_vector, flight_time, drag, _ship);
    return can_shoot->get_can_shoot_over_terrain() && can_shoot->get_can_shoot_over_ship();
}

Ref<ShootOver> Gun::sim_can_shoot_over_terrain_static(
    const Vector3& pos,
    const Vector3& launch_vector,
    double flight_time,
    double drag,
    Ship* ship
) {
    Vector3 shell_sim_position = pos;

    // Get the space state from the main loop
    SceneTree* tree = Object::cast_to<SceneTree>(Engine::get_singleton()->get_main_loop());
    if (!tree) {
        Ref<ShootOver> result;
        result.instantiate();
        result->set_can_shoot_over_terrain(true);
        result->set_can_shoot_over_ship(true);
        return result;
    }

    Ref<World3D> world = tree->get_root()->get_world_3d();
    if (!world.is_valid()) {
        Ref<ShootOver> result;
        result.instantiate();
        result->set_can_shoot_over_terrain(true);
        result->set_can_shoot_over_ship(true);
        return result;
    }

    PhysicsDirectSpaceState3D* space_state = world->get_direct_space_state();
    if (!space_state) {
        Ref<ShootOver> result;
        result.instantiate();
        result->set_can_shoot_over_terrain(true);
        result->set_can_shoot_over_ship(true);
        return result;
    }

    // Get projectile physics script for static method calls
    Ref<GDScript> projectile_physics = get_projectile_physics_script();
    if (projectile_physics.is_null()) {
        Ref<ShootOver> result;
        result.instantiate();
        result->set_can_shoot_over_terrain(true);
        result->set_can_shoot_over_ship(true);
        return result;
    }

    Ref<PhysicsRayQueryParameters3D> ray;
    ray.instantiate();
    ray->set_collide_with_bodies(true);
    ray->set_collision_mask(1 | (1 << 1));  // Collide with terrain and armor parts

    double t = 0.5;
    while (t < flight_time + 0.5) {
        ray->set_from(shell_sim_position);

        Vector3 new_pos = projectile_physics->call("calculate_position_at_time", pos, launch_vector, t, drag);
        ray->set_to(new_pos);

        Dictionary result = space_state->intersect_ray(ray);

        if (!result.is_empty()) {
            if (result.has("collider")) {
                Object* collider = Object::cast_to<Object>(result["collider"]);
                if (collider) {
                    // Check if it's an ArmorPart by checking for the "ship" property
                    Variant ship_var = collider->get("ship");
                    if (ship_var.get_type() != Variant::NIL) {
                        // It's an ArmorPart
                        Node* armor_ship = Object::cast_to<Node>(ship_var);
                        if (armor_ship && ship) {
                            // Get team IDs
                            Node* armor_team = Object::cast_to<Node>(armor_ship->get("team"));
                            Node* our_team = Object::cast_to<Node>(ship->get_team());

                            int armor_team_id = -1;
                            int our_team_id = -2;

                            if (armor_team) {
                                armor_team_id = armor_team->get("team_id");
                            }
                            if (our_team) {
                                our_team_id = our_team->get("team_id");
                            }

                            if (armor_team_id != our_team_id) {
                                // Hit enemy ship - success
                                Ref<ShootOver> shoot_result;
                                shoot_result.instantiate();
                                shoot_result->set_can_shoot_over_terrain(true);
                                shoot_result->set_can_shoot_over_ship(true);
                                return shoot_result;
                            } else if (armor_ship == ship) {
                                // Hitting own ship, ignore
                            } else if (armor_team_id == our_team_id) {
                                // Don't hit friendly ships
                                Ref<ShootOver> shoot_result;
                                shoot_result.instantiate();
                                shoot_result->set_can_shoot_over_terrain(true);
                                shoot_result->set_can_shoot_over_ship(false);
                                return shoot_result;
                            }
                        }
                    } else {
                        // Not an armor part - check if it's terrain
                        Vector3 hit_pos = result["position"];
                        if (hit_pos.y > 0.00001) {
                            // Hit terrain
                            Ref<ShootOver> shoot_result;
                            shoot_result.instantiate();
                            shoot_result->set_can_shoot_over_terrain(false);
                            shoot_result->set_can_shoot_over_ship(true);
                            return shoot_result;
                        }
                    }
                }
            }
        }

        shell_sim_position = new_pos;
        t += 0.5;
    }

    Ref<ShootOver> shoot_result;
    shoot_result.instantiate();
    shoot_result->set_can_shoot_over_terrain(true);
    shoot_result->set_can_shoot_over_ship(true);
    return shoot_result;
}
