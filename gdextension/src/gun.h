#ifndef GUN_H
#define GUN_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/stream_peer_buffer.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/gd_script.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Forward declarations for GDScript classes
class Ship;
class ArmorSystemV2;
class GunParams;
class ShellParams;
class ArmorPart;
class TargetMod;

// Inner class SimShell - exposed to GDScript
class SimShell : public RefCounted {
    GDCLASS(SimShell, RefCounted)

private:
    Vector3 start_position;
    Vector3 position;

protected:
    static void _bind_methods();

public:
    SimShell();
    ~SimShell();

    Vector3 get_start_position() const { return start_position; }
    void set_start_position(const Vector3& p_pos) { start_position = p_pos; }

    Vector3 get_position() const { return position; }
    void set_position(const Vector3& p_pos) { position = p_pos; }
};

// Inner class ShootOver - exposed to GDScript
class ShootOver : public RefCounted {
    GDCLASS(ShootOver, RefCounted)

private:
    bool can_shoot_over_terrain;
    bool can_shoot_over_ship;

protected:
    static void _bind_methods();

public:
    ShootOver();
    ShootOver(bool terrain, bool ship);
    ~ShootOver();

    bool get_can_shoot_over_terrain() const { return can_shoot_over_terrain; }
    void set_can_shoot_over_terrain(bool p_val) { can_shoot_over_terrain = p_val; }

    bool get_can_shoot_over_ship() const { return can_shoot_over_ship; }
    void set_can_shoot_over_ship(bool p_val) { can_shoot_over_ship = p_val; }
};

class Gun : public Node3D {
    GDCLASS(Gun, Node3D)

private:
    // Export properties
    int barrel_count = 1;
    double barrel_spacing = 0.5;
    bool rotation_limits_enabled = true;
    double min_rotation_angle;  // deg_to_rad(90)
    double max_rotation_angle;  // deg_to_rad(180)

    // @onready equivalent
    Node3D* barrel = nullptr;
    bool onready_initialized = false;

    // Member variables
    Vector3 _aim_point;
    double reload = 0.0;
    bool can_fire = false;
    bool _valid_target = false;
    TypedArray<Node3D> muzzles;
    int gun_id = 0;
    bool disabled = true;
    double base_rotation = 0.0;

    Ship* _ship = nullptr;
    int id = -1;

    // Armor system configuration
    Node* armor_system = nullptr;  // ArmorSystemV2
    String ship_model_glb_path;
    bool auto_extract_armor = true;

    Node* controller = nullptr;

    // Shell simulation
    Ref<SimShell> shell_sim;
    bool sim_shell_in_flight = false;

    // Private helpers
    void _initialize_onready_vars();
    void _ensure_onready();
    void _on_ready();  // Game logic called from notification
    
    // Helper to get ProjectilePhysicsWithDrag script for static method calls
    static Ref<GDScript> get_projectile_physics_script();

protected:
    static void _bind_methods();
    void _notification(int p_what);

public:
    Gun();
    ~Gun();

    // Godot lifecycle
    void _physics_process(double delta) override;

    // Serialization
    Dictionary to_dict() const;
    PackedByteArray to_bytes(bool full) const;
    void from_dict(const Dictionary& d);
    void from_bytes(const PackedByteArray& b, bool full);

    // Params accessors (delegate to controller)
    Ref<Resource> get_params() const;
    Ref<Resource> get_shell() const;

    // Notification
    void notify_gun_updated();

    // Cleanup/initialization
    void cleanup();
    void update_barrels();

    // Angle normalization functions
    static double normalize_angle_0_2pi(double angle);
    static double normalize_angle_0_2pi_simple(double angle);
    static double normalize_angle(double angle);

    // Rotation limit functions
    Array apply_rotation_limits(double current_angle, double desired_delta) const;
    void clamp_to_rotation_limits();
    Array apply_rotation_limits_simple(double current_angle, double desired_delta) const;
    void clamp_to_rotation_limits_simple();

    // Movement
    void return_to_base(double delta);

    // Targeting
    double get_angle_to_target(const Vector3& target) const;
    bool valid_target(const Vector3& target) const;
    bool valid_target_leading(const Vector3& target, const Vector3& target_velocity) const;
    Vector3 get_muzzles_position() const;

    // Aiming
    void _aim(const Vector3& aim_point, double delta, bool return_to_base = false);
    void _aim_leading(const Vector3& aim_point, const Vector3& vel, double delta);

    // Firing
    void fire(Object* mod = nullptr);
    void fire_client(const Vector3& vel, const Vector3& pos, double t, int _id);
    void fire_client2(const PackedByteArray& data);

    // Armor system
    void initialize_armor_system();
    void extract_and_load_armor_data(const String& glb_path, const String& armor_json_path);
    void enable_backface_collision_recursive(Node* node);

    // Terrain/ship shooting simulation
    bool sim_can_shoot_over_terrain(const Vector3& aim_point);
    static Ref<ShootOver> sim_can_shoot_over_terrain_static(
        const Vector3& pos,
        const Vector3& launch_vector,
        double flight_time,
        double drag,
        Ship* ship
    );

    // Property getters/setters for exports
    int get_barrel_count() const { return barrel_count; }
    void set_barrel_count(int p_count) { barrel_count = p_count; }

    double get_barrel_spacing() const { return barrel_spacing; }
    void set_barrel_spacing(double p_spacing) { barrel_spacing = p_spacing; }

    bool get_rotation_limits_enabled() const { return rotation_limits_enabled; }
    void set_rotation_limits_enabled(bool p_enabled) { rotation_limits_enabled = p_enabled; }

    double get_min_rotation_angle() const { return min_rotation_angle; }
    void set_min_rotation_angle(double p_angle) { min_rotation_angle = p_angle; }

    double get_max_rotation_angle() const { return max_rotation_angle; }
    void set_max_rotation_angle(double p_angle) { max_rotation_angle = p_angle; }

    // Member variable getters/setters
    Vector3 get_aim_point() const { return _aim_point; }
    void set_aim_point(const Vector3& p_aim) { _aim_point = p_aim; }

    double get_reload() const { return reload; }
    void set_reload(double p_reload) { reload = p_reload; }

    bool get_can_fire() const { return can_fire; }
    void set_can_fire(bool p_can_fire) { can_fire = p_can_fire; }

    bool get_valid_target() const { return _valid_target; }
    void set_valid_target(bool p_valid) { _valid_target = p_valid; }

    TypedArray<Node3D> get_muzzles() const { return muzzles; }
    void set_muzzles(const TypedArray<Node3D>& p_muzzles) { muzzles = p_muzzles; }

    int get_gun_id() const { return gun_id; }
    void set_gun_id(int p_id) { gun_id = p_id; }

    bool get_disabled() const { return disabled; }
    void set_disabled(bool p_disabled) { disabled = p_disabled; }

    double get_base_rotation() const { return base_rotation; }
    void set_base_rotation(double p_rotation) { base_rotation = p_rotation; }

    Ship* get_ship() const { return _ship; }
    void set_ship(Ship* p_ship) { _ship = p_ship; }

    int get_id() const { return id; }
    void set_id(int p_id) { id = p_id; }

    Node* get_armor_system() const { return armor_system; }
    void set_armor_system(Node* p_armor) { armor_system = p_armor; }

    String get_ship_model_glb_path() const { return ship_model_glb_path; }
    void set_ship_model_glb_path(const String& p_path) { ship_model_glb_path = p_path; }

    bool get_auto_extract_armor() const { return auto_extract_armor; }
    void set_auto_extract_armor(bool p_auto) { auto_extract_armor = p_auto; }

    Node* get_controller() const { return controller; }
    void set_controller(Node* p_controller) { controller = p_controller; }

    Ref<SimShell> get_shell_sim() const { return shell_sim; }
    void set_shell_sim(const Ref<SimShell>& p_shell) { shell_sim = p_shell; }

    bool get_sim_shell_in_flight() const { return sim_shell_in_flight; }
    void set_sim_shell_in_flight(bool p_in_flight) { sim_shell_in_flight = p_in_flight; }

    // Barrel accessor (for @onready simulation)
    Node3D* get_barrel();
    void set_barrel(Node3D* p_barrel) { barrel = p_barrel; }
};

} // namespace godot

#endif // GUN_H
