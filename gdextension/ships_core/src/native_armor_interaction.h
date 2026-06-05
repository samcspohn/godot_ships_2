#ifndef NATIVE_ARMOR_INTERACTION_H
#define NATIVE_ARMOR_INTERACTION_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "projectile_data.h"
#include "navigation_map.h"

namespace godot {

struct ArmorHitResult {
	bool hit = false;
	int result_type = 0;
	Vector3 explosion_position;
	Object *armor_part = nullptr;
	Vector3 velocity;
	Object *ship = nullptr;
	Vector3 collision_normal;
	double shell_integrity = 1.0;
	bool overmatch_first_armor = false;
};

class NativeArmorInteraction {
public:
	enum HitResult {
		PENETRATION = 0,
		PARTIAL_PEN = 1,
		RICOCHET = 2,
		OVERPENETRATION = 3,
		SHATTER = 4,
		CITADEL = 5,
		CITADEL_OVERPEN = 6,
		WATER = 7,
		TERRAIN = 8,
	};

	enum ArmorResult {
		ARMOR_RICOCHET = 0,
		ARMOR_OVERPEN = 1,
		ARMOR_PEN = 2,
		ARMOR_PARTIAL_PEN = 3,
		ARMOR_SHATTER = 4,
	};

	static double calculate_de_marre_penetration(double mass_kg, double velocity_ms, double caliber_mm);
	static ArmorHitResult process_travel(const Ref<ProjectileData> &projectile,
		const Vector3 &prev_pos,
		double t,
		PhysicsDirectSpaceState3D *space_state,
		Node *precision_physics_world,
		const Ref<NavigationMap> &nav_map);

private:
	struct ShellState {
		Vector3 position;
		Vector3 end_position;
		Vector3 velocity;
		Ref<Resource> params;
		double fuze = -1.0;
		double pen = 0.0;
		double integrity = 1.0;

		void calc_end_position();
		double get_speed() const;
	};

	struct ArmorEval {
		ArmorResult result = ARMOR_SHATTER;
		double pen_ratio = 0.0;
		double deflection_mult = 1.0;
		double energy_loss_fraction = 0.0;
		double physics_armor = 0.0;
	};

	static constexpr double DE_MARRE_K = 0.06;
	static constexpr double MIN_VELOCITY = 10.0;
	static constexpr double DEFLECTION_ALPHA = 0.35;
	static constexpr double OBLIQUITY_ALPHA = 1.0;
	static constexpr double DEFLECTION_GAMMA = 3.0;
	static constexpr double K_NOSE_APC = 0.06;
	static constexpr double K_NOSE_COMMON = 0.10;
	static constexpr double TD_MOD_SCALE = 0.3;
	static constexpr double TD_MOD_ONSET = 0.5;
	static constexpr double TD_MOD_MAX = 1.5;
	static constexpr double TD_ENGAGE_REF = 0.5;
	static constexpr double TD_ENGAGE_POWER = 1.5;
	static constexpr double DEFLECTION_RICOCHET_THRESHOLD = 1.15;
	static constexpr double WATER_DRAG = 2500.0;
	static constexpr double EPSILON = 0.0002;
	static constexpr uint32_t OBB_COLLISION_LAYER = 1u << 4;
	static constexpr double SHIP_CLEAR_HEIGHT = 200.0;

	static ArmorHitResult make_result(HitResult type,
		const Vector3 &position,
		Object *armor_part,
		const Vector3 &velocity,
		Object *ship,
		const Vector3 &normal,
		double integrity = 1.0);

	static Array build_obb_excludes(const Ref<ProjectileData> &projectile, Node *precision_physics_world);
	static bool object_array_contains(const Array &array, Object *object);
	static Ref<Resource> duplicate_shell_params_with_drag(const Ref<Resource> &params, double drag_multiplier);
	static Vector3 handle_water_entry(const Vector3 &water_hit, const Vector3 &entry_vel, const Ref<Resource> &params);
	static bool try_get_water_plane_hit(const Vector3 &prev_pos, const Vector3 &curr_pos, Vector3 &water_hit);
	static bool try_get_terrain_map_hit(const Ref<NavigationMap> &nav_map,
		const Vector3 &from,
		const Vector3 &to,
		Vector3 &terrain_hit,
		Vector3 &terrain_normal);

	static ArmorHitResult process_hit(Object *hit_node,
		const Vector3 &world_hit_position,
		const Vector3 &world_hit_normal,
		const Vector3 &local_hit_position,
		const Vector3 &local_hit_normal,
		const Ref<ProjectileData> &projectile,
		const Vector3 &impact_velocity,
		int face_index,
		double fuze,
		bool hit_water,
		Node *precision_physics_world);

	static double calculate_effective_thickness(double thickness_mm, double impact_angle_rad);
	static double calculate_exit_velocity(double entry_speed, double pen_capability_mm, double effective_armor_mm);
	static double calculate_shell_integrity(double pen_ratio, double current_integrity);
	static Vector3 calculate_deflected_direction(const Vector3 &entry_dir, const Vector3 &armor_normal, double pen_ratio);
	static Vector3 calculate_ricochet_velocity(const Vector3 &velocity, const Vector3 &normal, double energy_loss_fraction);
	static double calculate_impact_angle(const Vector3 &velocity_dir, const Vector3 &surface_normal);
	static double get_k_nose(const Ref<Resource> &params);
	static ArmorEval evaluate_armor_interaction(const ShellState &shell,
		const Ref<Resource> &params,
		double impact_angle,
		double armor_mm,
		double e_armor);
	static HitResult resolve_hit_result(ArmorResult armor_result, Object *final_part, bool hit_cit, bool over_pen);
	static bool is_citadel(Object *armor_part);
	static int armor_type(Object *armor_part);
	static double get_armor(Object *armor_part, int face_index);
};

} // namespace godot

#endif // NATIVE_ARMOR_INTERACTION_H
