#include "ship.h"
#include "gun.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/multiplayer_peer.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>

using namespace godot;

void Ship::_bind_methods() {
    // Signals
    ADD_SIGNAL(MethodInfo("reset_mods"));
    ADD_SIGNAL(MethodInfo("reset_dynamic_mods"));

    // Methods
    ClassDB::bind_method(D_METHOD("add_static_mod", "mod_func"), &Ship::add_static_mod);
    ClassDB::bind_method(D_METHOD("remove_static_mod", "mod_func"), &Ship::remove_static_mod);
    ClassDB::bind_method(D_METHOD("add_dynamic_mod", "mod_func"), &Ship::add_dynamic_mod);
    ClassDB::bind_method(D_METHOD("remove_dynamic_mod", "mod_func"), &Ship::remove_dynamic_mod);
    ClassDB::bind_method(D_METHOD("_update_static_mods"), &Ship::_update_static_mods);
    ClassDB::bind_method(D_METHOD("_update_dynamic_mods"), &Ship::_update_dynamic_mods);
    ClassDB::bind_method(D_METHOD("_enable_guns"), &Ship::_enable_guns);
    ClassDB::bind_method(D_METHOD("_disable_guns"), &Ship::_disable_guns);
    ClassDB::bind_method(D_METHOD("set_input", "input_array", "aim_point"), &Ship::set_input);
    ClassDB::bind_method(D_METHOD("get_aabb"), &Ship::get_aabb);
    ClassDB::bind_method(D_METHOD("sync_ship_data2", "vs", "friendly"), &Ship::sync_ship_data2);
    ClassDB::bind_method(D_METHOD("sync_ship_transform"), &Ship::sync_ship_transform);
    ClassDB::bind_method(D_METHOD("parse_ship_transform", "b"), &Ship::parse_ship_transform);
    ClassDB::bind_method(D_METHOD("sync_player_data"), &Ship::sync_player_data);
    ClassDB::bind_method(D_METHOD("initialized_client"), &Ship::initialized_client);
    ClassDB::bind_method(D_METHOD("sync2", "b", "friendly"), &Ship::sync2);
    ClassDB::bind_method(D_METHOD("sync_player", "b"), &Ship::sync_player);
    ClassDB::bind_method(D_METHOD("_hide"), &Ship::_hide);
    ClassDB::bind_method(D_METHOD("enable_backface_collision_recursive", "node"), &Ship::enable_backface_collision_recursive);
    ClassDB::bind_method(D_METHOD("initialize_armor_system"), &Ship::initialize_armor_system);
    ClassDB::bind_method(D_METHOD("resolve_glb_path", "path"), &Ship::resolve_glb_path);
    ClassDB::bind_method(D_METHOD("extract_and_load_armor_data", "glb_path", "armor_json_path"), &Ship::extract_and_load_armor_data);
    ClassDB::bind_method(D_METHOD("get_armor_at_hit_point", "hit_node", "face_index"), &Ship::get_armor_at_hit_point);
    ClassDB::bind_method(D_METHOD("calculate_damage_from_hit", "hit_node", "face_index", "shell_penetration"), &Ship::calculate_damage_from_hit);

    // Property getters/setters
    ClassDB::bind_method(D_METHOD("get_initialized"), &Ship::get_initialized);
    ClassDB::bind_method(D_METHOD("set_initialized", "initialized"), &Ship::set_initialized);
    ClassDB::bind_method(D_METHOD("get_visible_to_enemy"), &Ship::get_visible_to_enemy);
    ClassDB::bind_method(D_METHOD("set_visible_to_enemy", "visible"), &Ship::set_visible_to_enemy);
    ClassDB::bind_method(D_METHOD("get_peer_id"), &Ship::get_peer_id);
    ClassDB::bind_method(D_METHOD("set_peer_id", "peer_id"), &Ship::set_peer_id);
    ClassDB::bind_method(D_METHOD("get_ship_model_glb_path"), &Ship::get_ship_model_glb_path);
    ClassDB::bind_method(D_METHOD("set_ship_model_glb_path", "path"), &Ship::set_ship_model_glb_path);
    ClassDB::bind_method(D_METHOD("get_auto_extract_armor"), &Ship::get_auto_extract_armor);
    ClassDB::bind_method(D_METHOD("set_auto_extract_armor", "auto"), &Ship::set_auto_extract_armor);
    ClassDB::bind_method(D_METHOD("get_citadel"), &Ship::get_citadel);
    ClassDB::bind_method(D_METHOD("set_citadel", "citadel"), &Ship::set_citadel);
    ClassDB::bind_method(D_METHOD("get_hull"), &Ship::get_hull);
    ClassDB::bind_method(D_METHOD("set_hull", "hull"), &Ship::set_hull);
    ClassDB::bind_method(D_METHOD("get_static_mods"), &Ship::get_static_mods);
    ClassDB::bind_method(D_METHOD("set_static_mods", "mods"), &Ship::set_static_mods);
    ClassDB::bind_method(D_METHOD("get_dynamic_mods"), &Ship::get_dynamic_mods);
    ClassDB::bind_method(D_METHOD("set_dynamic_mods", "mods"), &Ship::set_dynamic_mods);
    ClassDB::bind_method(D_METHOD("get_armor_parts"), &Ship::get_armor_parts);
    ClassDB::bind_method(D_METHOD("set_armor_parts", "parts"), &Ship::set_armor_parts);

    // Component accessors
    ClassDB::bind_method(D_METHOD("get_movement_controller"), &Ship::get_movement_controller);
    ClassDB::bind_method(D_METHOD("get_artillery_controller"), &Ship::get_artillery_controller);
    ClassDB::bind_method(D_METHOD("get_secondary_controller"), &Ship::get_secondary_controller);
    ClassDB::bind_method(D_METHOD("get_health_controller"), &Ship::get_health_controller);
    ClassDB::bind_method(D_METHOD("get_consumable_manager"), &Ship::get_consumable_manager);
    ClassDB::bind_method(D_METHOD("get_fire_manager"), &Ship::get_fire_manager);
    ClassDB::bind_method(D_METHOD("get_upgrades"), &Ship::get_upgrades);
    ClassDB::bind_method(D_METHOD("get_skills"), &Ship::get_skills);
    ClassDB::bind_method(D_METHOD("get_torpedo_launcher"), &Ship::get_torpedo_launcher);
    ClassDB::bind_method(D_METHOD("get_stats"), &Ship::get_stats);
    ClassDB::bind_method(D_METHOD("get_armor_system"), &Ship::get_armor_system);
    ClassDB::bind_method(D_METHOD("get_control"), &Ship::get_control);
    ClassDB::bind_method(D_METHOD("set_control", "control"), &Ship::set_control);
    ClassDB::bind_method(D_METHOD("get_team"), &Ship::get_team);
    ClassDB::bind_method(D_METHOD("set_team", "team"), &Ship::set_team);
    ClassDB::bind_method(D_METHOD("get_frustum_planes"), &Ship::get_frustum_planes);
    ClassDB::bind_method(D_METHOD("set_frustum_planes", "planes"), &Ship::set_frustum_planes);

    // Properties
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "initialized"), "set_initialized", "get_initialized");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "visible_to_enemy"), "set_visible_to_enemy", "get_visible_to_enemy");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "peer_id"), "set_peer_id", "get_peer_id");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "ship_model_glb_path", PROPERTY_HINT_FILE, "*.glb"), "set_ship_model_glb_path", "get_ship_model_glb_path");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_extract_armor"), "set_auto_extract_armor", "get_auto_extract_armor");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "citadel", PROPERTY_HINT_NODE_TYPE, "StaticBody3D"), "set_citadel", "get_citadel");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "hull", PROPERTY_HINT_NODE_TYPE, "StaticBody3D"), "set_hull", "get_hull");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "static_mods"), "set_static_mods", "get_static_mods");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "dynamic_mods"), "set_dynamic_mods", "get_dynamic_mods");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "armor_parts"), "set_armor_parts", "get_armor_parts");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "control", PROPERTY_HINT_NODE_TYPE, "Node"), "set_control", "get_control");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "team", PROPERTY_HINT_NODE_TYPE, "Node"), "set_team", "get_team");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "frustum_planes"), "set_frustum_planes", "get_frustum_planes");

    // Component accessors as read-only properties (for GDScript property-style access)
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "movement_controller", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_movement_controller");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "artillery_controller", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_artillery_controller");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "secondary_controller", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_secondary_controller");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "health_controller", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_health_controller");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "consumable_manager", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_consumable_manager");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "fire_manager", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_fire_manager");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "upgrades", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_upgrades");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "skills", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_skills");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "torpedo_launcher", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_torpedo_launcher");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "stats", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_stats");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "armor_system", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_armor_system");
}

Ship::Ship() {
    // Constructor
}

Ship::~Ship() {
    // Destructor
}

// Called when node enters the scene tree
// Handle notifications for proper initialization timing
void Ship::_notification(int p_what) {
    if (Engine::get_singleton()->is_editor_hint()) {
        return;
    }

    switch (p_what) {
        case NOTIFICATION_ENTER_TREE:
            // Set ship references on child modules BEFORE their _ready() is called
            // This is critical because children's _ready() runs before parent's _ready()
            // but ENTER_TREE fires on parent first, then propagates to children
            // _set_ship_references_on_children();
            break;
        case NOTIFICATION_READY:
            _initialize_onready_vars();
            _set_ship_references_on_children();

            _on_ready();
            break;
        case NOTIFICATION_PHYSICS_PROCESS:
            _physics_process(get_physics_process_delta_time());
            break;
    }
}

// Game logic called from NOTIFICATION_READY
void Ship::_on_ready() {
    // Enable physics processing first
    set_physics_process(true);

    // Game logic starts here
    // @onready vars are already initialized
    // Ship references on children were already set during _enter_tree()

    UtilityFunctions::print("Ship::_ready() called for: ", get_path());

    // Configure RPC methods (equivalent to @rpc annotations in GDScript)
    // sync_player: @rpc("authority", "call_remote", "unreliable_ordered", 1)
    {
        Dictionary config;
        config["rpc_mode"] = MultiplayerAPI::RPC_MODE_AUTHORITY;
        config["call_local"] = false;
        config["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_UNRELIABLE_ORDERED;
        config["channel"] = 1;
        rpc_config(StringName("sync_player"), config);
        UtilityFunctions::print("  Configured RPC: sync_player");
    }

    // initialized_client: @rpc("any_peer", "reliable")
    {
        Dictionary config;
        config["rpc_mode"] = MultiplayerAPI::RPC_MODE_ANY_PEER;
        config["call_local"] = false;
        config["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_RELIABLE;
        config["channel"] = 0;
        rpc_config(StringName("initialized_client"), config);
        UtilityFunctions::print("  Configured RPC: initialized_client");
    }

    // _hide: @rpc("any_peer", "reliable")
    {
        Dictionary config;
        config["rpc_mode"] = MultiplayerAPI::RPC_MODE_ANY_PEER;
        config["call_local"] = false;
        config["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_RELIABLE;
        config["channel"] = 0;
        rpc_config(StringName("_hide"), config);
        UtilityFunctions::print("  Configured RPC: _hide");
    }

    // Verify RPC config was set
    Variant rpc_cfg = get_node_rpc_config();
    UtilityFunctions::print("  Node RPC config: ", rpc_cfg);

    UtilityFunctions::print("Upgrades node: ", upgrades);

    // Create and add Stats node
    Ref<Script> stats_script = ResourceLoader::get_singleton()->load("res://src/Player/stats.gd");
    if (stats_script.is_valid()) {
        stats = Object::cast_to<Node>(ClassDB::instantiate("Node"));
        if (stats != nullptr) {
            stats->set_script(stats_script);
            Node* modules = get_node_or_null(NodePath("Modules"));
            if (modules != nullptr) {
                modules->add_child(stats);
            }
        }
    }

    // Initialize armor system
    initialize_armor_system();

    initialized = true;

    // Check if we're not the authority
    Ref<MultiplayerAPI> mp = get_multiplayer();
    bool is_authority = mp.is_valid() && mp->is_server();

    if (is_authority) {
        // Authority keeps physics processing enabled
        set_physics_process(true);
    } else {
        // Call RPC to notify server
        rpc_id(1, "initialized_client");
        set_physics_process(false);
        set_freeze_enabled(true);

        // Disable all collision shapes
        TypedArray<Node> children = get_children();
        for (int i = 0; i < children.size(); i++) {
            CollisionShape3D* shape = Object::cast_to<CollisionShape3D>(children[i]);
            if (shape != nullptr) {
                shape->set_disabled(true);
            }
        }
    }

    set_collision_layer(1 << 2);
    set_collision_mask(1 | (1 << 2));
}

// Set ship reference on child modules that need it
// Called during ENTER_TREE so modules have the reference before their _ready() runs
void Ship::_set_ship_references_on_children() {
    // Get references to child nodes (they exist at ENTER_TREE time)
    Node* cm = get_node_or_null(NodePath("Modules/ConsumableManager"));
    Node* fm = get_node_or_null(NodePath("Modules/FireManager"));
    Node* sk = get_node_or_null(NodePath("Modules/Skills"));
    Node* ac = get_node_or_null(NodePath("Modules/ArtilleryController"));
    Node* sc = get_node_or_null(NodePath("Modules/SecondaryController"));
    Node* tl = get_node_or_null(NodePath("TorpedoLauncher"));

    if (cm != nullptr) {
        cm->set("ship", this);
    }
    if (fm != nullptr) {
        fm->set("_ship", this);
    }
    if (sk != nullptr) {
        sk->set("_ship", this);
    }
    if (ac != nullptr) {
        ac->set("_ship", this);
    }
    if (sc != nullptr) {
        sc->set("_ship", this);
    }
    if (tl != nullptr) {
        tl->set("_ship", this);
    }
}

// Initialize all @onready equivalent member variables
// Called from _notification(NOTIFICATION_READY) before _ready() runs
void Ship::_initialize_onready_vars() {
    if (onready_initialized) {
        return;
    }

    // These match the GDScript @onready declarations exactly
    movement_controller = get_node_or_null(NodePath("Modules/MovementController"));
    artillery_controller = get_node_or_null(NodePath("Modules/ArtilleryController"));
    secondary_controller = get_node_or_null(NodePath("Modules/SecondaryController"));
    health_controller = get_node_or_null(NodePath("Modules/HPManager"));
    consumable_manager = get_node_or_null(NodePath("Modules/ConsumableManager"));
    fire_manager = get_node_or_null(NodePath("Modules/FireManager"));
    upgrades = get_node_or_null(NodePath("Modules/Upgrades"));
    skills = get_node_or_null(NodePath("Modules/Skills"));
    torpedo_launcher = get_node_or_null(NodePath("TorpedoLauncher"));

    onready_initialized = true;
}

// Fallback lazy initialization - ensures vars are available even if accessed before _ready
void Ship::_ensure_onready() {
    if (!onready_initialized && is_inside_tree()) {
        _initialize_onready_vars();
    }
}

// Lazy-initialized component accessors (simulate @onready access pattern)
Node* Ship::get_movement_controller() {
    _ensure_onready();
    return movement_controller;
}

Node* Ship::get_artillery_controller() {
    _ensure_onready();
    return artillery_controller;
}

Node* Ship::get_secondary_controller() {
    _ensure_onready();
    return secondary_controller;
}

Node* Ship::get_health_controller() {
    _ensure_onready();
    return health_controller;
}

Node* Ship::get_consumable_manager() {
    _ensure_onready();
    return consumable_manager;
}

Node* Ship::get_fire_manager() {
    _ensure_onready();
    return fire_manager;
}

Node* Ship::get_upgrades() {
    _ensure_onready();
    return upgrades;
}

Node* Ship::get_skills() {
    _ensure_onready();
    return skills;
}

Node* Ship::get_torpedo_launcher() {
    _ensure_onready();
    return torpedo_launcher;
}

Node* Ship::get_stats() {
    // Stats is created dynamically in _ready(), not a true @onready
    return stats;
}

void Ship::set_team(Node* p_team) {
    UtilityFunctions::print("Ship::set_team called on ", get_name(), " with team: ", p_team);
    team = p_team;
    UtilityFunctions::print("Ship::set_team result - team is now: ", team);
}

void Ship::_physics_process(double delta) {
    // Check if we're the authority
    Ref<MultiplayerAPI> mp = get_multiplayer();
    bool is_authority = mp.is_valid() && mp->is_server();

    if (!is_authority) {
        return;
    }

    // Update torpedo launcher aim
    if (torpedo_launcher != nullptr && artillery_controller != nullptr) {
        Vector3 aim_point = artillery_controller->get("aim_point");
        torpedo_launcher->call("_aim", aim_point, delta);
    }

    // Process skills
    if (skills != nullptr) {
        Array skill_list = skills->get("skills");
        for (int i = 0; i < skill_list.size(); i++) {
            Object* skill = Object::cast_to<Object>(skill_list[i]);
            if (skill != nullptr) {
                skill->call("_proc", delta);
            }
        }
    }

    // Update mods if flagged
    if (update_static_mods_flag) {
        _update_static_mods();
        update_static_mods_flag = false;
    }
    if (update_dynamic_mods_flag) {
        _update_dynamic_mods();
        update_dynamic_mods_flag = false;
    }
}

void Ship::add_static_mod(const Callable& mod_func) {
    static_mods.append(mod_func);
    update_static_mods_flag = true;
}

void Ship::remove_static_mod(const Callable& mod_func) {
    int idx = static_mods.find(mod_func);
    if (idx >= 0) {
        static_mods.remove_at(idx);
    }
    update_static_mods_flag = true;
}

void Ship::add_dynamic_mod(const Callable& mod_func) {
    dynamic_mods.append(mod_func);
    update_dynamic_mods_flag = true;
}

void Ship::remove_dynamic_mod(const Callable& mod_func) {
    int idx = dynamic_mods.find(mod_func);
    if (idx >= 0) {
        dynamic_mods.remove_at(idx);
    }
    update_dynamic_mods_flag = true;
}

void Ship::_update_static_mods() {

    emit_signal("reset_mods");
    for (int i = 0; i < static_mods.size(); i++) {
        Callable mod = static_mods[i];
        mod.call(this);
    }
    _update_dynamic_mods();
}

void Ship::_update_dynamic_mods() {

    emit_signal("reset_dynamic_mods");
    for (int i = 0; i < dynamic_mods.size(); i++) {
        Callable mod = dynamic_mods[i];
        mod.call(this);
    }
}

void Ship::_enable_guns() {
	UtilityFunctions::print("Ship::_enable_guns called");
    if (!initialized) {
        // Defer the call to next frame, similar to GDScript's await
        UtilityFunctions::print("Deferring _enable_guns call");
        call_deferred("_enable_guns");
        return;
    }
    UtilityFunctions::print("Artillery is : ", artillery_controller == nullptr ? "null" : "some");
    if (artillery_controller != nullptr) {
    	UtilityFunctions::print("  enabling guns on artillery_controller");
        Array guns = artillery_controller->get("guns");
        for (int i = 0; i < guns.size(); i++) {
            Object* gun = Object::cast_to<Object>(guns[i]);
            if (gun != nullptr) {
                gun->set("disabled", false);
            }
        }
    } else {
		UtilityFunctions::print("  artillery_controller is null");
		call_deferred("_enable_guns");
		return;
	}

    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        for (int i = 0; i < sub_controllers.size(); i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                Array guns = controller->get("guns");
                for (int j = 0; j < guns.size(); j++) {
                    Object* gun = Object::cast_to<Object>(guns[j]);
                    if (gun != nullptr) {
                        gun->set("disabled", false);
                    }
                }
            }
        }
    }
}

void Ship::_disable_guns() {


    if (!initialized) {
        return;
    }

    if (artillery_controller != nullptr) {
        Array guns = artillery_controller->get("guns");
        for (int i = 0; i < guns.size(); i++) {
            Object* gun = Object::cast_to<Object>(guns[i]);
            if (gun != nullptr) {
                gun->set("disabled", true);
            }
        }
    }

    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        for (int i = 0; i < sub_controllers.size(); i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                Array guns = controller->get("guns");
                for (int j = 0; j < guns.size(); j++) {
                    Object* gun = Object::cast_to<Object>(guns[j]);
                    if (gun != nullptr) {
                        gun->set("disabled", true);
                    }
                }
            }
        }
    }
}

void Ship::set_input(const Array& input_array, const Vector3& aim_point) {

    if (movement_controller != nullptr) {
        Array movement_input;
        movement_input.append(input_array[0]);
        movement_input.append(input_array[1]);
        movement_controller->call("set_movement_input", movement_input);
    }

    if (artillery_controller != nullptr) {
        artillery_controller->call("set_aim_input", aim_point);
    }
}

AABB Ship::get_aabb() const {
    // Transform the AABB by the global transform
    Transform3D transform = get_global_transform();
    AABB transformed_aabb;
    transformed_aabb.position = transform.xform(aabb.position);
    transformed_aabb.size = transform.basis.xform(aabb.size);
    return transformed_aabb;
}

PackedByteArray Ship::sync_ship_data2(bool vs, bool friendly) {

    Ref<StreamPeerBuffer> writer;
    writer.instantiate();

    writer->put_var(get_linear_velocity());
    Vector3 euler = get_global_basis().get_euler();
    writer->put_var(euler);
    writer->put_var(get_global_position());

    if (health_controller != nullptr) {
        float current_hp = health_controller->get("current_hp");
        writer->put_float(current_hp);
    } else {
        writer->put_float(0.0f);
    }

    // Consumables data
    if (friendly && consumable_manager != nullptr) {
        PackedByteArray cons_bytes = consumable_manager->call("to_bytes");
        writer->put_var(cons_bytes);
    }

    // Artillery/Guns data
    if (artillery_controller != nullptr) {
        Array guns = artillery_controller->get("guns");
        writer->put_32(guns.size());
        for (int i = 0; i < guns.size(); i++) {
            Object* gun = Object::cast_to<Object>(guns[i]);
            if (gun != nullptr) {
                PackedByteArray gun_bytes = gun->call("to_bytes", false);
                writer->put_var(gun_bytes);
            }
        }
    } else {
        writer->put_32(0);
    }

    // Secondary controllers data
    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        writer->put_32(sub_controllers.size());
        for (int i = 0; i < sub_controllers.size(); i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                Array guns = controller->get("guns");
                writer->put_32(guns.size());
                for (int j = 0; j < guns.size(); j++) {
                    Object* gun = Object::cast_to<Object>(guns[j]);
                    if (gun != nullptr) {
                        PackedByteArray gun_bytes = gun->call("to_bytes", false);
                        writer->put_var(gun_bytes);
                    }
                }
            } else {
                writer->put_32(0);
            }
        }
    } else {
        writer->put_32(0);
    }

    // Torpedo launcher data
    torpedo_launcher = get_node_or_null(NodePath("TorpedoLauncher"));
    writer->put_32(torpedo_launcher != nullptr ? 1 : 0);
    if (torpedo_launcher != nullptr) {
        Node3D* tl = Object::cast_to<Node3D>(torpedo_launcher);
        if (tl != nullptr) {
            Vector3 euler_tl = tl->get_global_basis().get_euler();
            writer->put_var(euler_tl);
        }
    }

    Ref<MultiplayerAPI> mp = get_multiplayer();
    if (mp.is_valid()) {
        writer->put_32(mp->get_unique_id());
    } else {
        writer->put_32(0);
    }

    writer->put_u8(vs ? 1 : 0);

    return writer->get_data_array();
}

PackedByteArray Ship::sync_ship_transform() {

    Ref<StreamPeerBuffer> writer;
    writer.instantiate();

    writer->put_float(get_rotation().y);
    writer->put_float(get_global_position().x);
    writer->put_float(get_global_position().z);

    return writer->get_data_array();
}

void Ship::parse_ship_transform(const PackedByteArray& b) {
    Ref<StreamPeerBuffer> reader;
    reader.instantiate();
    reader->set_data_array(b);

    Vector3 rot = get_rotation();
    rot.y = reader->get_float();
    set_rotation(rot);

    Vector3 pos = get_global_position();
    pos.x = reader->get_float();
    pos.z = reader->get_float();
    set_global_position(pos);
}

PackedByteArray Ship::sync_player_data() {

    Ref<StreamPeerBuffer> writer;
    writer.instantiate();

    if (movement_controller != nullptr) {
        int throttle_level = movement_controller->get("throttle_level");
        float rudder_input = movement_controller->get("rudder_input");
        writer->put_32(throttle_level);
        writer->put_float(rudder_input);
    } else {
        writer->put_32(0);
        writer->put_float(0.0f);
    }

    writer->put_var(get_linear_velocity());
    Vector3 euler = get_global_basis().get_euler();
    writer->put_var(euler);
    writer->put_var(get_global_position());

    if (health_controller != nullptr) {
        float current_hp = health_controller->get("current_hp");
        writer->put_float(current_hp);
    } else {
        writer->put_float(0.0f);
    }

    // Consumables data
    if (consumable_manager != nullptr) {
        PackedByteArray cons_bytes = consumable_manager->call("to_bytes");
        writer->put_var(cons_bytes);
    }

    // Artillery data
    if (artillery_controller != nullptr) {
        PackedByteArray art_bytes = artillery_controller->call("to_bytes");
        writer->put_var(art_bytes);

        Array guns = artillery_controller->get("guns");
        for (int i = 0; i < guns.size(); i++) {
            Object* gun = Object::cast_to<Object>(guns[i]);
            if (gun != nullptr) {
                PackedByteArray gun_bytes = gun->call("to_bytes", true);
                writer->put_var(gun_bytes);
            }
        }
    }

    // Secondary controllers data
    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        for (int i = 0; i < sub_controllers.size(); i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                PackedByteArray sc_bytes = controller->call("to_bytes");
                writer->put_var(sc_bytes);

                Array guns = controller->get("guns");
                for (int j = 0; j < guns.size(); j++) {
                    Object* gun = Object::cast_to<Object>(guns[j]);
                    if (gun != nullptr) {
                        PackedByteArray gun_bytes = gun->call("to_bytes", true);
                        writer->put_var(gun_bytes);
                    }
                }
            }
        }
    }

    // Torpedo launcher data
    torpedo_launcher = get_node_or_null(NodePath("TorpedoLauncher"));
    if (torpedo_launcher != nullptr) {
        Node3D* tl = Object::cast_to<Node3D>(torpedo_launcher);
        if (tl != nullptr) {
            Vector3 euler_tl = tl->get_global_basis().get_euler();
            writer->put_var(euler_tl);
        }
    }

    Ref<MultiplayerAPI> mp = get_multiplayer();
    if (mp.is_valid()) {
        writer->put_32(mp->get_unique_id());
    } else {
        writer->put_32(0);
    }

    // Stats data
    if (stats != nullptr) {
        PackedByteArray stats_bytes = stats->call("to_bytes");
        writer->put_var(stats_bytes);
    }

    return writer->get_data_array();
}

void Ship::initialized_client() {
    initialized = true;
}

void Ship::sync2(const PackedByteArray& b, bool friendly) {

    if (!initialized) {
        return;
    }
    set_visible(true);

    Ref<StreamPeerBuffer> reader;
    reader.instantiate();
    reader->set_data_array(b);

    set_linear_velocity(reader->get_var());
    Vector3 euler = reader->get_var();
    set_global_basis(Basis::from_euler(euler));
    set_global_position(reader->get_var());

    if (health_controller != nullptr) {
        health_controller->set("current_hp", reader->get_float());
    } else {
        reader->get_float(); // consume the value
    }

    // Consumables data
    if (friendly && consumable_manager != nullptr) {
        PackedByteArray cons_bytes = reader->get_var();
        consumable_manager->call("from_bytes", cons_bytes);
    }

    // Guns data
    int gun_count = reader->get_32();
    if (artillery_controller != nullptr) {
        Array guns = artillery_controller->get("guns");
        for (int i = 0; i < guns.size() && i < gun_count; i++) {
            Gun* gun = Object::cast_to<Gun>(guns[i]);
            if (gun != nullptr) {
                PackedByteArray gun_bytes = reader->get_var();
                gun->from_bytes(gun_bytes, false);
                // gun->call("from_bytes", gun_bytes, false);
            }
        }
    }

    // Secondary controllers data
    int sc_count = reader->get_32();
    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        for (int i = 0; i < sub_controllers.size() && i < sc_count; i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                int sc_gun_count = reader->get_32();
                Array guns = controller->get("guns");
                for (int j = 0; j < guns.size() && j < sc_gun_count; j++) {
                    Gun* gun = Object::cast_to<Gun>(guns[j]);
                    if (gun != nullptr) {
                        PackedByteArray gun_bytes = reader->get_var();
                        gun->from_bytes(gun_bytes, false);
                        // gun->call("from_bytes", gun_bytes, false);
                    }
                }
            }
        }
    }

    // Torpedo launcher data
    torpedo_launcher = get_node_or_null(NodePath("TorpedoLauncher"));
    int has_torpedo = reader->get_32();
    if (has_torpedo && torpedo_launcher != nullptr) {
        Node3D* tl = Object::cast_to<Node3D>(torpedo_launcher);
        if (tl != nullptr) {
            Vector3 euler_tl = reader->get_var();
            tl->set_global_basis(Basis::from_euler(euler_tl));
        }
    }

    reader->get_32(); // peer_id - consumed but not used here
    visible_to_enemy = reader->get_u8() == 1;
}

void Ship::sync_player(const PackedByteArray& b) {

    if (!initialized) {
        return;
    }
    set_visible(true);

    Ref<StreamPeerBuffer> reader;
    reader.instantiate();
    reader->set_data_array(b);

    if (movement_controller != nullptr) {
        movement_controller->set("throttle_level", reader->get_32());
        movement_controller->set("rudder_input", reader->get_float());
    } else {
        reader->get_32();
        reader->get_float();
    }

    set_linear_velocity(reader->get_var());
    Vector3 euler = reader->get_var();
    set_global_basis(Basis::from_euler(euler));
    set_global_position(reader->get_var());

    if (health_controller != nullptr) {
        health_controller->set("current_hp", reader->get_float());
    } else {
        reader->get_float();
    }

    // Consumables data
    if (consumable_manager != nullptr) {
        PackedByteArray cons_bytes = reader->get_var();
        consumable_manager->call("from_bytes", cons_bytes);
    }

    // Artillery data
    if (artillery_controller != nullptr) {
        PackedByteArray art_bytes = reader->get_var();
        artillery_controller->call("from_bytes", art_bytes);

        Array guns = artillery_controller->get("guns");
        for (int i = 0; i < guns.size(); i++) {
            Object* gun = Object::cast_to<Object>(guns[i]);
            if (gun != nullptr) {
                PackedByteArray gun_bytes = reader->get_var();
                gun->call("from_bytes", gun_bytes, true);
            }
        }
    }

    // Secondary controllers data
    if (secondary_controller != nullptr) {
        Array sub_controllers = secondary_controller->get("sub_controllers");
        for (int i = 0; i < sub_controllers.size(); i++) {
            Object* controller = Object::cast_to<Object>(sub_controllers[i]);
            if (controller != nullptr) {
                PackedByteArray sc_bytes = reader->get_var();
                controller->call("from_bytes", sc_bytes);

                Array guns = controller->get("guns");
                for (int j = 0; j < guns.size(); j++) {
                    Object* gun = Object::cast_to<Object>(guns[j]);
                    if (gun != nullptr) {
                        PackedByteArray gun_bytes = reader->get_var();
                        gun->call("from_bytes", gun_bytes, true);
                    }
                }
            }
        }
    }

    // Torpedo launcher data
    torpedo_launcher = get_node_or_null(NodePath("TorpedoLauncher"));
    if (torpedo_launcher != nullptr) {
        Node3D* tl = Object::cast_to<Node3D>(torpedo_launcher);
        if (tl != nullptr) {
            Vector3 euler_tl = reader->get_var();
            tl->set_global_basis(Basis::from_euler(euler_tl));
        }
    }

    reader->get_32(); // peer_id

    if (stats != nullptr) {
        PackedByteArray stats_bytes = reader->get_var();
        stats->call("from_bytes", stats_bytes);
    }
}

void Ship::_hide() {
    set_visible(false);
    visible_to_enemy = false;
}

void Ship::enable_backface_collision_recursive(Node* node) {
    // Build path from node to this ship
    String path = "";
    Node* n = node;
    while (n != this && n != nullptr) {
        if (!path.is_empty()) {
            path = n->get_name() + String("/") + path;
        } else {
            path = n->get_name();
        }
        n = n->get_parent();
    }

    // Check if armor_system has data for this path
    if (armor_system != nullptr) {
        Dictionary armor_data = armor_system->get("armor_data");

        if (armor_data.has(path)) {
            MeshInstance3D* mesh_instance = Object::cast_to<MeshInstance3D>(node);
            StaticBody3D* static_body_node = Object::cast_to<StaticBody3D>(node);

            if (mesh_instance != nullptr) {
                // Handle MeshInstance3D case
                StaticBody3D* static_body = Object::cast_to<StaticBody3D>(mesh_instance->find_child("StaticBody3D", false));
                if (static_body != nullptr) {
                    CollisionShape3D* collision_shape = Object::cast_to<CollisionShape3D>(static_body->find_child("CollisionShape3D", false));
                    if (collision_shape != nullptr) {
                        static_body->remove_child(collision_shape);

                        ConcavePolygonShape3D* concave = Object::cast_to<ConcavePolygonShape3D>(collision_shape->get_shape().ptr());
                        if (concave != nullptr) {
                            concave->set_backface_collision_enabled(true);
                        }
                        static_body->queue_free();

                        // Create ArmorPart - this requires the ArmorPart class to be defined in C++ or accessed via script
                        Ref<Script> armor_part_script = ResourceLoader::get_singleton()->load("res://src/armor/armor_part.gd");
                        if (armor_part_script.is_valid()) {
                            Node* armor_part = Object::cast_to<Node>(ClassDB::instantiate("StaticBody3D"));
                            if (armor_part != nullptr) {
                                armor_part->set_script(armor_part_script);
                                armor_part->add_child(collision_shape);
                                armor_part->set("collision_layer", 1 << 1);
                                armor_part->set("collision_mask", 0);
                                armor_part->set("armor_system", armor_system);
                                armor_part->set("armor_path", path);
                                armor_part->set("ship", this);
                                mesh_instance->add_child(armor_part);
                                armor_parts.append(armor_part);

                                aabb = aabb.merge(mesh_instance->get_aabb());

                                if (node->get_name() == String("Hull")) {
                                    hull = Object::cast_to<StaticBody3D>(armor_part);
                                } else if (node->get_name() == String("Citadel")) {
                                    citadel = Object::cast_to<StaticBody3D>(armor_part);
                                }
                            }
                        }
                    }
                }
            } else if (static_body_node != nullptr) {
                // Handle StaticBody3D case
                CollisionShape3D* collision_shape = Object::cast_to<CollisionShape3D>(static_body_node->find_child("CollisionShape3D", false));
                if (collision_shape != nullptr) {
                    ConcavePolygonShape3D* concave = Object::cast_to<ConcavePolygonShape3D>(collision_shape->get_shape().ptr());
                    if (concave != nullptr) {
                        concave->set_backface_collision_enabled(true);
                    }

                    Ref<Script> armor_part_script = ResourceLoader::get_singleton()->load("res://src/armor/armor_part.gd");
                    if (armor_part_script.is_valid()) {
                        Node* armor_part = Object::cast_to<Node>(ClassDB::instantiate("StaticBody3D"));
                        if (armor_part != nullptr) {
                            armor_part->set_script(armor_part_script);
                            armor_part->add_child(collision_shape);
                            armor_part->set("collision_layer", 1 << 1);
                            armor_part->set("collision_mask", 0);
                            armor_part->set("armor_system", armor_system);
                            armor_part->set("armor_path", path);
                            armor_part->set("ship", this);
                            static_body_node->get_parent()->add_child(armor_part);
                            armor_parts.append(armor_part);

                            aabb = aabb.merge(static_body_node->call("get_aabb"));

                            if (node->get_name() == String("Hull")) {
                                hull = Object::cast_to<StaticBody3D>(armor_part);
                            } else if (node->get_name() == String("Citadel")) {
                                citadel = Object::cast_to<StaticBody3D>(armor_part);
                            }
                        }
                    }
                }
            }
        }
    }

    // Recurse to children
    TypedArray<Node> children = node->get_children();
    for (int i = 0; i < children.size(); i++) {
        Node* child = Object::cast_to<Node>(children[i]);
        if (child != nullptr) {
            enable_backface_collision_recursive(child);
        }
    }
}

void Ship:: initialize_armor_system() {
    // Validate and resolve the GLB path
    String resolved_glb_path = resolve_glb_path(ship_model_glb_path);
    if (resolved_glb_path.is_empty()) {
        UtilityFunctions::print("   Invalid or missing GLB path: ", ship_model_glb_path);
        return;
    }

    // Create armor system instance
    Ref<Script> armor_system_script = ResourceLoader::get_singleton()->load("res://src/armor/armor_system_v2.gd");
    if (armor_system_script.is_valid()) {
        armor_system = Object::cast_to<Node>(ClassDB::instantiate("Node"));
        if (armor_system != nullptr) {
            armor_system->set_script(armor_system_script);
            add_child(armor_system);
        }
    }

    if (armor_system == nullptr) {
        return;
    }

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
    }

    enable_backface_collision_recursive(this);
    UtilityFunctions::print("done");
}

String Ship::resolve_glb_path(const String& path) {
    if (path.is_empty()) {
        return "";
    }

    // Check if it's a UID (starts with "uid://")
    if (path.begins_with("uid://")) {
        Ref<Resource> resource = ResourceLoader::get_singleton()->load(path);
        if (resource.is_valid()) {
            String resource_path = resource->get_path();
            if (resource_path.ends_with(".glb")) {
                return resource_path;
            } else {
                return "";
            }
        } else {
            UtilityFunctions::print("   Failed to resolve UID: ", path);
            return "";
        }
    }

    // Direct path - validate it exists and is GLB
    if (path.ends_with(".glb") && FileAccess::file_exists(path)) {
        return path;
    } else {
        UtilityFunctions::print("   Invalid GLB path: ", path);
        return "";
    }
}

void Ship::extract_and_load_armor_data(const String& glb_path, const String& armor_json_path) {
    // Load the extractor
    Ref<Script> extractor_script = ResourceLoader::get_singleton()->load("res://src/armor/enhanced_armor_extractor_v2.gd");
    if (!extractor_script.is_valid()) {
        UtilityFunctions::print("      Failed to load armor extractor script");
        return;
    }

    // Create extractor instance
    Object* extractor = ClassDB::instantiate("RefCounted");
    if (extractor == nullptr) {
        return;
    }
    extractor->set_script(extractor_script);

    UtilityFunctions::print("      Extracting armor data from GLB...");
    bool success = extractor->call("extract_armor_with_mapping_to_json", glb_path, armor_json_path);

    if (success) {
        UtilityFunctions::print("      Armor extraction completed");
        UtilityFunctions::print("      Saved to: ", armor_json_path);

        // Load the newly extracted data
        if (armor_system != nullptr) {
            success = armor_system->call("load_armor_data", armor_json_path);
            if (success) {
                UtilityFunctions::print("      Armor system initialized successfully");
            } else {
                UtilityFunctions::print("      Failed to load extracted armor data");
            }
        }
    } else {
        UtilityFunctions::print("      Armor extraction failed");
    }

    memdelete(extractor);
}

int Ship::get_armor_at_hit_point(Node3D* hit_node, int face_index) {
    if (armor_system == nullptr) {
        return 0;
    }

    String node_path = armor_system->call("get_node_path_from_scene", hit_node, get_name());
    return armor_system->call("get_face_armor_thickness", node_path, face_index);
}

Dictionary Ship::calculate_damage_from_hit(Node3D* hit_node, int face_index, int shell_penetration) {
    if (armor_system == nullptr) {
        Dictionary result;
        result["penetrated"] = true;
        result["damage_ratio"] = 1.0;
        result["damage_type"] = "no_armor";
        return result;
    }

    String node_path = armor_system->call("get_node_path_from_scene", hit_node, get_name());
    return armor_system->call("calculate_penetration_damage", node_path, face_index, shell_penetration);
}
