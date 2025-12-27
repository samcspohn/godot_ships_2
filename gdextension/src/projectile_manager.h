#ifndef PROJECTILE_MANAGER_H
#define PROJECTILE_MANAGER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/gpu_particles3d.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Forward declarations
class Ship;
class ShellParams;
// Note: UnifiedParticleSystem is a GDScript class, accessed via Node*

// ProjectileData - inner class exposed to GDScript
class ProjectileData : public RefCounted {
    GDCLASS(ProjectileData, RefCounted)

private:
    Vector3 position;
    Vector3 start_position;
    double start_time;
    Vector3 launch_velocity;
    Ref<Resource> params;  // ShellParams
    Vector3 trail_pos;
    Ship* owner;
    int frame_count;
    TypedArray<Ship> exclude;

protected:
    static void _bind_methods();

public:
    ProjectileData();
    ~ProjectileData();

    void initialize(const Vector3& pos, const Vector3& vel, double t, const Ref<Resource>& p, Ship* _owner, const TypedArray<Ship>& _exclude = TypedArray<Ship>());

    // Getters and setters
    Vector3 get_position() const { return position; }
    void set_position(const Vector3& p_pos) { position = p_pos; }

    Vector3 get_start_position() const { return start_position; }
    void set_start_position(const Vector3& p_pos) { start_position = p_pos; }

    double get_start_time() const { return start_time; }
    void set_start_time(double p_time) { start_time = p_time; }

    Vector3 get_launch_velocity() const { return launch_velocity; }
    void set_launch_velocity(const Vector3& p_vel) { launch_velocity = p_vel; }

    Ref<Resource> get_params() const { return params; }
    void set_params(const Ref<Resource>& p_params) { params = p_params; }

    Vector3 get_trail_pos() const { return trail_pos; }
    void set_trail_pos(const Vector3& p_pos) { trail_pos = p_pos; }

    Ship* get_owner() const { return owner; }
    void set_owner(Ship* p_owner) { owner = p_owner; }

    int get_frame_count() const { return frame_count; }
    void set_frame_count(int p_count) { frame_count = p_count; }

    TypedArray<Ship> get_exclude() const { return exclude; }
    void set_exclude(const TypedArray<Ship>& p_exclude) { exclude = p_exclude; }
};

// ShellData - inner class for shell state during armor penetration
class ShellData : public RefCounted {
    GDCLASS(ShellData, RefCounted)

private:
    Ref<Resource> params;  // ShellParams
    Vector3 velocity;
    Vector3 position;
    Vector3 end_position;
    double fuse;
    int hit_result;

protected:
    static void _bind_methods();

public:
    ShellData();
    ~ShellData();

    Ref<Resource> get_params() const { return params; }
    void set_params(const Ref<Resource>& p_params) { params = p_params; }

    Vector3 get_velocity() const { return velocity; }
    void set_velocity(const Vector3& p_vel) { velocity = p_vel; }

    Vector3 get_position() const { return position; }
    void set_position(const Vector3& p_pos) { position = p_pos; }

    Vector3 get_end_position() const { return end_position; }
    void set_end_position(const Vector3& p_pos) { end_position = p_pos; }

    double get_fuse() const { return fuse; }
    void set_fuse(double p_fuse) { fuse = p_fuse; }

    int get_hit_result() const { return hit_result; }
    void set_hit_result(int p_result) { hit_result = p_result; }

    // Utility method to get speed from velocity
    double get_speed() const { return velocity.length(); }
};

// Main ProjectileManager class
class ProjectileManager : public Node {
    GDCLASS(ProjectileManager, Node)

public:
    // Hit result types enum - must match ArmorInteraction.gd HitResult
    enum HitResult {
        PENETRATION,
        PARTIAL_PEN,
        RICOCHET,
        OVERPENETRATION,
        SHATTER,
        CITADEL,
        CITADEL_OVERPEN,
        WATER,
        TERRAIN,
    };

private:
    // Member variables
    double shell_time_multiplier;
    int nextId;
    TypedArray<ProjectileData> projectiles;
    Array ids_reuse;
    Dictionary shell_param_ids;
    int bulletId;

    // Node references (onready equivalents)
    GPUParticles3D* particles;
    MultiMeshInstance3D* multi_mesh;
    Node* gpu_renderer;
    bool use_gpu_renderer;
    Ref<PhysicsRayQueryParameters3D> ray_query;
    Ref<PhysicsRayQueryParameters3D> mesh_ray_query;

    // Compute particle system (GDScript class, accessed via Node*)
    Node* _compute_particle_system;
    int _trail_template_id;
    bool use_compute_trails;

    // Rendering data
    PackedFloat32Array transforms;
    PackedColorArray colors;
    Camera3D* camera;

    bool onready_initialized;

    // Private helper methods
    void _initialize_onready_vars();
    void _ensure_onready();
    void _on_ready();
    Node* _find_particle_system();
    Ship* find_ship(Node* node);

protected:
    static void _bind_methods();

public:
    void _ready() override;

public:
    ProjectileManager();
    ~ProjectileManager();

    // Godot lifecycle
    void _process(double delta) override;
    void _physics_process(double delta) override;

    // Custom process method (can be connected to signals)
    void __process(double delta);

    // Initialize compute trails (public so it can be connected to timer signal)
    void _init_compute_trails();

    // Trail processing
    void _process_trails_only(double current_time);

    // Utility functions
    static int next_pow_of_2(int value);
    static PackedFloat32Array transform_to_packed_float32array(const Transform3D& transform);
    void update_transform_pos(int idx, const Vector3& pos);
    void update_transform_scale(int idx, double scale);
    void update_transform(int idx, const Transform3D& trans);
    void set_color(int idx, const Color& color);
    void resize_multimesh_buffers(int new_count);

    // Armor calculation functions
    static double calculate_penetration_power(const Ref<Resource>& shell_params, double velocity);
    static double calculate_impact_angle(const Vector3& velocity, const Vector3& surface_normal);

    // Firing functions
    int fireBullet(const Vector3& vel, const Vector3& pos, const Ref<Resource>& shell, double t, Ship* _owner, const TypedArray<Ship>& exclude = TypedArray<Ship>());
    void fireBulletClient(const Vector3& pos, const Vector3& vel, double t, int id, const Ref<Resource>& shell, Ship* _owner, bool muzzle_blast = true, const Basis& basis = Basis());

    // Destruction functions
    void destroyBulletRpc2(int id, const Vector3& pos, int hit_result, const Vector3& normal);
    void destroyBulletRpc(int id, const Vector3& position, int hit_result, const Vector3& normal);
    void destroyBulletRpc3(const PackedByteArray& data);

    // Fire damage
    void apply_fire_damage(const Ref<ProjectileData>& projectile, Ship* ship, const Vector3& hit_position);

    // Debug functions
    void print_armor_debug(const Dictionary& armor_result, Ship* ship);
    void validate_penetration_formula();

    // Stat tracking
    void track_damage_dealt(const Ref<ProjectileData>& p, double damage);
    void track_damage_event(const Ref<ProjectileData>& p, double damage, const Vector3& position, int type);
    void track_penetration(const Ref<ProjectileData>& p);
    void track_citadel(const Ref<ProjectileData>& p);
    void track_overpenetration(const Ref<ProjectileData>& p);
    void track_shatter(const Ref<ProjectileData>& p);
    void track_ricochet(const Ref<ProjectileData>& p);
    void track_frag(const Ref<ProjectileData>& p);

    // Ricochet RPC functions
    void createRicochetRpc(int original_shell_id, int new_shell_id, const Vector3& ricochet_position, const Vector3& ricochet_velocity, double ricochet_time);
    void createRicochetRpc2(const PackedByteArray& data);

    // Property getters/setters
    double get_shell_time_multiplier() const { return shell_time_multiplier; }
    void set_shell_time_multiplier(double p_mult) { shell_time_multiplier = p_mult; }

    int get_next_id() const { return nextId; }
    void set_next_id(int p_id) { nextId = p_id; }

    TypedArray<ProjectileData> get_projectiles() const { return projectiles; }
    void set_projectiles(const TypedArray<ProjectileData>& p_projectiles) { projectiles = p_projectiles; }

    Array get_ids_reuse() const { return ids_reuse; }
    void set_ids_reuse(const Array& p_ids) { ids_reuse = p_ids; }

    Dictionary get_shell_param_ids() const { return shell_param_ids; }
    void set_shell_param_ids(const Dictionary& p_dict) { shell_param_ids = p_dict; }

    int get_bullet_id() const { return bulletId; }
    void set_bullet_id(int p_id) { bulletId = p_id; }

    GPUParticles3D* get_particles() const { return particles; }
    void set_particles(GPUParticles3D* p_particles) { particles = p_particles; }

    MultiMeshInstance3D* get_multi_mesh() const { return multi_mesh; }
    void set_multi_mesh(MultiMeshInstance3D* p_mesh) { multi_mesh = p_mesh; }

    Node* get_gpu_renderer() const { return gpu_renderer; }
    void set_gpu_renderer(Node* p_renderer) { gpu_renderer = p_renderer; }

    bool get_use_gpu_renderer() const { return use_gpu_renderer; }
    void set_use_gpu_renderer(bool p_use) { use_gpu_renderer = p_use; }

    bool get_use_compute_trails() const { return use_compute_trails; }
    void set_use_compute_trails(bool p_use) { use_compute_trails = p_use; }

    PackedFloat32Array get_transforms() const { return transforms; }
    void set_transforms(const PackedFloat32Array& p_transforms) { transforms = p_transforms; }

    PackedColorArray get_colors() const { return colors; }
    void set_colors(const PackedColorArray& p_colors) { colors = p_colors; }

    Camera3D* get_camera() const { return camera; }
    void set_camera(Camera3D* p_camera) { camera = p_camera; }
};

} // namespace godot

VARIANT_ENUM_CAST(ProjectileManager::HitResult);

#endif // PROJECTILE_MANAGER_H