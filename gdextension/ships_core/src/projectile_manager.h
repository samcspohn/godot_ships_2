#ifndef PROJECTILE_MANAGER_H
#define PROJECTILE_MANAGER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>

#include <vector>
#include <unordered_map>
#include <godot_cpp/variant/vector2.hpp>

#include "projectile_data.h"
#include "shell_data.h"

namespace godot {

class _ProjectileManager : public Node {
	GDCLASS(_ProjectileManager, Node)

public:
	// Hit result enum - matches GDScript HitResult
	enum HitResult {
		PENETRATION = 0,
		RICOCHET = 1,
		OVERPENETRATION = 2,
		SHATTER = 3,
		NOHIT = 4,
		CITADEL = 5,
		WATER = 6,
	};

private:
	// Time multiplier for shell speed display
	double shell_time_multiplier;
	double current_time;

	// Projectile tracking
	int next_id;
	TypedArray<ProjectileData> projectiles;
	Array ids_reuse; // Array of ints for ID reuse
	Dictionary shell_param_ids; // Dictionary[int, ShellParams]
	int bullet_id;

	// GPU renderer (GPUProjectileRenderer)
	Node *gpu_renderer;

	// Physics query objects
	Ref<PhysicsRayQueryParameters3D> ray_query;
	Ref<PhysicsRayQueryParameters3D> mesh_ray_query;

	// Compute particle system for trails
	Node *compute_particle_system; // UnifiedParticleSystem
	int trail_template_id;
	Camera3D *camera;

	// Cached autoload references
	Node *armor_interaction;
	Node *tcp_thread_pool;
	Node *sound_effect_manager;

	// --- Shell landing spatial grid (for bot shell dodging) ---
	struct ShellLandingEntry {
		int shell_id;
		float landing_x;       // world X of predicted impact
		float landing_z;       // world Z of predicted impact
		float time_to_impact;  // total flight time in shell-time units
		float fire_time;       // current_time when shell was fired
		float caliber;         // shell caliber in mm (for damage priority)
		int team_id;           // firing team (-1 if unknown)
	};

	static constexpr float SHELL_GRID_CELL = 500.0f;
	static constexpr float SHELL_GRID_MIN  = -17500.0f;
	static constexpr float SHELL_GRID_MAX  =  17500.0f;
	static constexpr int   SHELL_GRID_DIM  = 70; // (SHELL_GRID_MAX - SHELL_GRID_MIN) / SHELL_GRID_CELL

	std::vector<std::vector<int>> shell_grid;
	std::unordered_map<int, ShellLandingEntry> shell_landings;

	int  shell_grid_index(float wx, float wz) const;
	void shell_grid_insert(int shell_id, float wx, float wz);
	void shell_grid_remove(int shell_id);

protected:
	static void _bind_methods();

public:
	_ProjectileManager();
	~_ProjectileManager();

	// Godot lifecycle methods
	void _ready() override;
	void _process(double delta) override;
	void _physics_process(double delta) override;

	// Initialization methods
	void _init_compute_trails();
	Node *_find_particle_system();

	// Penetration calculations
	double calculate_penetration_power(const Ref<Resource> &shell_params, double velocity);
	double calculate_impact_angle(const Vector3 &velocity, const Vector3 &surface_normal);

	// Utility functions
	static int next_pow_of_2(int value);
	Object *find_ship(Node *node);

	// Process methods
	void _process_trails_only(double current_time);

	// sync time method for client-side projectile updates
	void sync_time(double server_time);

	// Fire bullet methods
	int fire_bullet(const Vector3 &vel, const Vector3 &pos, const Ref<Resource> &shell,
					double t, Object *owner, const Array &exclude = Array());
	void fire_bullet_client(const Vector3 &pos, const Vector3 &vel, double t, int id,
							const Ref<Resource> &shell, Object *owner,
							bool muzzle_blast = true, const Basis &basis = Basis());

	// Destroy bullet RPC methods
	void destroy_bullet_rpc(int id, const Vector3 &position, int hit_result, const Vector3 &normal);
	void destroy_bullet_rpc2(int id, const Vector3 &pos, int hit_result, const Vector3 &normal);
	void destroy_bullet_rpc3(const PackedByteArray &data);

	// Damage and fire methods
	void apply_fire_damage(const Ref<ProjectileData> &projectile, Object *ship, const Vector3 &hit_position);
	void print_armor_debug(const Dictionary &armor_result, Object *ship);

	// Validation
	void validate_penetration_formula();

	// Ricochet RPC methods
	void create_ricochet_rpc(int original_shell_id, int new_shell_id, const Vector3 &ricochet_position,
							 const Vector3 &ricochet_velocity, double ricochet_time);
	void create_ricochet_rpc2(const PackedByteArray &data);

	// Getters
	double get_current_time() const;
	double get_shell_time_multiplier() const;
	int get_next_id() const;
	TypedArray<ProjectileData> get_projectiles() const;
	Array get_ids_reuse() const;
	Dictionary get_shell_param_ids() const;
	int get_bullet_id() const;
	Node *get_gpu_renderer() const;
	Node *get_compute_particle_system() const;
	int get_trail_template_id() const;
	Camera3D *get_camera() const;

	// Shell landing query (for bot shell dodging)
	Array get_shells_near_position(Vector2 position, float radius, int exclude_team_id) const;

	// Setters
	void set_shell_time_multiplier(double value);
	void set_next_id(int value);
	void set_projectiles(const TypedArray<ProjectileData> &value);
	void set_ids_reuse(const Array &value);
	void set_shell_param_ids(const Dictionary &value);
	void set_bullet_id(int value);
	void set_gpu_renderer(Node *value);
	void set_compute_particle_system(Node *value);
	void set_trail_template_id(int value);
	void set_camera(Camera3D *value);
};

} // namespace godot

VARIANT_ENUM_CAST(_ProjectileManager::HitResult);

#endif // PROJECTILE_MANAGER_H
