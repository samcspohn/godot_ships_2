#ifndef SHIP_H
#define SHIP_H

#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/stream_peer_buffer.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/callable.hpp>

namespace godot {

// Forward declarations for GDScript classes that need to be wrapped
// These would need to be either GDExtension classes or accessed via Object*
class ShipMovementV2;
class ArtilleryController;
class SecondaryController_;
class HitPointsManager;
class ConsumableManager;
class FireManager;
class Upgrades;
class SkillsManager;
class TorpedoLauncher;
class Stats;
class TeamEntity;
class ArmorSystemV2;
class ArmorPart;
class Gun;

class Ship : public RigidBody3D {
    GDCLASS(Ship, RigidBody3D)

private:
    bool initialized = false;
    bool onready_initialized = false;  // Track if @onready vars are set

    // Child components (accessed via get_node) - equivalent to @onready
    Node* movement_controller = nullptr;
    Node* artillery_controller = nullptr;
    Node* secondary_controller = nullptr;
    Node* health_controller = nullptr;
    Node* consumable_manager = nullptr;
    Node* fire_manager = nullptr;
    Node* upgrades = nullptr;
    Node* skills = nullptr;
    Node* torpedo_launcher = nullptr;
    Node* stats = nullptr;
    Node* control = nullptr;
    Node* team = nullptr;

    bool visible_to_enemy = false;
    Node* armor_system = nullptr;
    StaticBody3D* citadel = nullptr;
    StaticBody3D* hull = nullptr;
    TypedArray<Node> armor_parts;
    AABB aabb;

    Array static_mods;  // applied on _init and when reset_static_mods signal is emitted
    Array dynamic_mods; // checked every frame for changes, affects _params

    int peer_id = -1;  // our unique peer ID assigned by server

    TypedArray<Plane> frustum_planes;

    // Armor system configuration
    String ship_model_glb_path;
    bool auto_extract_armor = true;

    bool update_static_mods_flag = false;
    bool update_dynamic_mods_flag = false;

    // Private helper to initialize @onready equivalent variables
    void _initialize_onready_vars();
    void _ensure_onready();  // Lazy initialization fallback
    void _set_ship_references_on_children();  // Sets ship ref on children during ENTER_TREE
    void _on_ready();  // Game logic called from notification

protected:
    static void _bind_methods();
    void _notification(int p_what);

public:
    Ship();
    ~Ship();

    // Godot lifecycle
    void _physics_process(double delta) override;

    // Modifier system
    void add_static_mod(const Callable& mod_func);
    void remove_static_mod(const Callable& mod_func);
    void add_dynamic_mod(const Callable& mod_func);
    void remove_dynamic_mod(const Callable& mod_func);
    void _update_static_mods();
    void _update_dynamic_mods();

    // Gun control
    void _enable_guns();
    void _disable_guns();

    // Input handling
    void set_input(const Array& input_array, const Vector3& aim_point);

    // AABB
    AABB get_aabb() const;

    // Network synchronization
    PackedByteArray sync_ship_data2(bool vs, bool friendly);
    PackedByteArray sync_ship_transform();
    void parse_ship_transform(const PackedByteArray& b);
    PackedByteArray sync_player_data();
    void initialized_client();  // RPC
    void sync2(const PackedByteArray& b, bool friendly);
    void sync_player(const PackedByteArray& b);  // RPC
    void _hide();  // RPC

    // Armor system
    void enable_backface_collision_recursive(Node* node);
    void initialize_armor_system();
    String resolve_glb_path(const String& path);
    void extract_and_load_armor_data(const String& glb_path, const String& armor_json_path);
    int get_armor_at_hit_point(Node3D* hit_node, int face_index);
    Dictionary calculate_damage_from_hit(Node3D* hit_node, int face_index, int shell_penetration);

    // Property getters/setters
    bool get_initialized() const { return initialized; }
    void set_initialized(bool p_initialized) { initialized = p_initialized; }

    bool get_visible_to_enemy() const { return visible_to_enemy; }
    void set_visible_to_enemy(bool p_visible) { visible_to_enemy = p_visible; }

    int get_peer_id() const { return peer_id; }
    void set_peer_id(int p_peer_id) { peer_id = p_peer_id; }

    String get_ship_model_glb_path() const { return ship_model_glb_path; }
    void set_ship_model_glb_path(const String& p_path) { ship_model_glb_path = p_path; }

    bool get_auto_extract_armor() const { return auto_extract_armor; }
    void set_auto_extract_armor(bool p_auto) { auto_extract_armor = p_auto; }

    StaticBody3D* get_citadel() const { return citadel; }
    void set_citadel(StaticBody3D* p_citadel) { citadel = p_citadel; }

    StaticBody3D* get_hull() const { return hull; }
    void set_hull(StaticBody3D* p_hull) { hull = p_hull; }

    AABB get_aabb_property() const { return aabb; }
    void set_aabb_property(const AABB& p_aabb) { aabb = p_aabb; }

    Array get_static_mods() const { return static_mods; }
    void set_static_mods(const Array& p_mods) { static_mods = p_mods; }

    Array get_dynamic_mods() const { return dynamic_mods; }
    void set_dynamic_mods(const Array& p_mods) { dynamic_mods = p_mods; }

    TypedArray<Node> get_armor_parts() const { return armor_parts; }
    void set_armor_parts(const TypedArray<Node>& p_parts) { armor_parts = p_parts; }

    // Component accessors - use lazy initialization to ensure availability
    // These simulate @onready behavior by initializing on first access if needed
    Node* get_movement_controller();
    Node* get_artillery_controller();
    Node* get_secondary_controller();
    Node* get_health_controller();
    Node* get_consumable_manager();
    Node* get_fire_manager();
    Node* get_upgrades();
    Node* get_skills();
    Node* get_torpedo_launcher();
    Node* get_stats();
    Node* get_armor_system() const { return armor_system; }

    Node* get_control() const { return control; }
    void set_control(Node* p_control) { control = p_control; }

    Node* get_team() const { return team; }
    void set_team(Node* p_team);

    TypedArray<Plane> get_frustum_planes() const { return frustum_planes; }
    void set_frustum_planes(const TypedArray<Plane>& p_planes) { frustum_planes = p_planes; }
};

} // namespace godot

#endif // SHIP_H
