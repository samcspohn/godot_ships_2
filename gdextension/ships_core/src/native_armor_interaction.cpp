#include "native_armor_interaction.h"

#include "projectile_physics_with_drag_v2.h"

#include <godot_cpp/classes/collision_object3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr double INF_DIST = 1.0e300;
constexpr double DEG_TO_RAD = Math_PI / 180.0;

static double clampd(double v, double lo, double hi) {
	return std::max(lo, std::min(v, hi));
}

static Vector3 basis_xform(const Basis &basis, const Vector3 &v) {
	return Vector3(
		basis.rows[0].dot(v),
		basis.rows[1].dot(v),
		basis.rows[2].dot(v));
}

static Vector3 basis_xform_inv(const Basis &basis, const Vector3 &v) {
	Basis inv = basis.inverse();
	return basis_xform(inv, v);
}
} // namespace

void NativeArmorInteraction::ShellState::calc_end_position() {
	double fuze_left = params.is_valid() ? (double)params->get("fuze_delay") - fuze : 0.0;
	if (fuze < 0.0) {
		fuze_left = 1.0;
	}
	end_position = position + velocity * fuze_left;
}

double NativeArmorInteraction::ShellState::get_speed() const {
	return velocity.length();
}

ArmorHitResult NativeArmorInteraction::make_result(HitResult type,
		const Vector3 &position,
		Object *armor_part,
		const Vector3 &velocity,
		Object *ship,
		const Vector3 &normal,
		double integrity) {
	ArmorHitResult result;
	result.hit = true;
	result.result_type = (int)type;
	result.explosion_position = position;
	result.armor_part = armor_part;
	result.velocity = velocity;
	result.ship = ship;
	result.collision_normal = normal;
	result.shell_integrity = integrity;
	return result;
}

double NativeArmorInteraction::calculate_de_marre_penetration(double mass_kg, double velocity_ms, double caliber_mm) {
	if (velocity_ms < 1.0) {
		return 0.0;
	}
	return DE_MARRE_K * std::pow(mass_kg, 0.55) * std::pow(velocity_ms, 1.43) / std::pow(caliber_mm, 0.65);
}

double NativeArmorInteraction::calculate_effective_thickness(double thickness_mm, double impact_angle_rad) {
	double cos_angle = std::max(std::cos(impact_angle_rad), 0.05);
	return thickness_mm / cos_angle;
}

double NativeArmorInteraction::calculate_exit_velocity(double entry_speed, double pen_capability_mm, double effective_armor_mm) {
	if (pen_capability_mm <= 0.0) {
		return 0.0;
	}
	double pen_ratio = effective_armor_mm / pen_capability_mm;
	if (pen_ratio >= 1.0) {
		return 0.0;
	}
	return entry_speed * (1.0 - pen_ratio);
}

double NativeArmorInteraction::calculate_shell_integrity(double pen_ratio, double current_integrity) {
	return clampd(current_integrity - pen_ratio * 0.4, 0.1, 1.0);
}

Vector3 NativeArmorInteraction::calculate_deflected_direction(const Vector3 &entry_dir, const Vector3 &armor_normal, double pen_ratio) {
	double deflection_amount = DEFLECTION_ALPHA * pen_ratio * 0.5;
	return entry_dir.slerp(-armor_normal, deflection_amount).normalized();
}

Vector3 NativeArmorInteraction::calculate_ricochet_velocity(const Vector3 &velocity, const Vector3 &normal, double energy_loss_fraction) {
	Vector3 n = normal.normalized();
	double v_normal_mag = velocity.dot(n);
	Vector3 v_normal = n * v_normal_mag;
	Vector3 v_tangential = velocity - v_normal;
	return v_tangential + (-v_normal * (1.0 - energy_loss_fraction));
}

double NativeArmorInteraction::calculate_impact_angle(const Vector3 &velocity_dir, const Vector3 &surface_normal) {
	double cos_angle = std::abs(velocity_dir.dot(surface_normal));
	return std::acos(clampd(cos_angle, 0.0, 1.0));
}

double NativeArmorInteraction::get_k_nose(const Ref<Resource> &params) {
	if (params.is_valid() && (int)params->get("type") == 0) {
		return K_NOSE_COMMON;
	}
	return K_NOSE_APC;
}

NativeArmorInteraction::ArmorEval NativeArmorInteraction::evaluate_armor_interaction(const ShellState &shell,
		const Ref<Resource> &params,
		double impact_angle,
		double armor_mm,
		double e_armor) {
	ArmorEval eval;
	double caliber = params.is_valid() ? (double)params->get("caliber") : 1.0;
	double k_nose = get_k_nose(params);
	double cos_a = std::max(std::cos(impact_angle), 0.05);
	double tan_a = std::tan(clampd(impact_angle, 0.0, 89.0 * DEG_TO_RAD));
	double geometric = std::pow(1.0 / cos_a, OBLIQUITY_ALPHA);
	double td_ratio = armor_mm / std::max(caliber, 1.0);
	double engagement = std::pow(clampd(td_ratio / TD_ENGAGE_REF, 0.0, 1.0), TD_ENGAGE_POWER);
	double f_td = 1.0 + TD_MOD_SCALE * clampd(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX);
	double raw_deflection = k_nose * std::pow(tan_a, DEFLECTION_GAMMA) * f_td;
	double deflection = 1.0 + engagement * raw_deflection;

	eval.deflection_mult = deflection;
	eval.physics_armor = e_armor * deflection;
	double pen_ratio = shell.pen / std::max(eval.physics_armor, 0.1);

	if (pen_ratio >= 1.0) {
		eval.result = ARMOR_PEN;
		eval.pen_ratio = e_armor / std::max(shell.pen, 0.1);
		return eval;
	}

	bool would_pen_without_deflection = shell.pen >= e_armor;
	bool is_deflection_dominated = deflection >= DEFLECTION_RICOCHET_THRESHOLD;
	if (is_deflection_dominated && (would_pen_without_deflection || impact_angle > 55.0 * DEG_TO_RAD)) {
		eval.result = ARMOR_RICOCHET;
		eval.pen_ratio = pen_ratio;
		eval.energy_loss_fraction = clampd(shell.pen * std::cos(impact_angle) / std::max(eval.physics_armor, 0.1), 0.0, 0.8);
		return eval;
	}

	eval.result = ARMOR_SHATTER;
	eval.pen_ratio = shell.pen / std::max(e_armor, 0.1);
	return eval;
}

bool NativeArmorInteraction::same_object(Object *a, Object *b) {
	if (a == nullptr || b == nullptr) {
		return false;
	}
	return a == b || a->get_instance_id() == b->get_instance_id();
}

bool NativeArmorInteraction::object_array_contains(const Array &array, Object *object) {
	for (int i = 0; i < array.size(); i++) {
		if (same_object(Object::cast_to<Object>(array[i]), object)) {
			return true;
		}
	}
	return false;
}

bool NativeArmorInteraction::is_owner_or_excluded(Object *ship, Object *owner, const Array &exclude) {
	return ship == nullptr || same_object(ship, owner) || object_array_contains(exclude, ship);
}

Array NativeArmorInteraction::build_obb_excludes(const Ref<ProjectileData> &projectile, Node *precision_physics_world) {
	Array obb_rids;
	if (!projectile.is_valid() || precision_physics_world == nullptr) {
		return obb_rids;
	}

	auto append_ship_obb = [&](Object *ship) {
		if (ship == nullptr) {
			return;
		}
		Dictionary entry = precision_physics_world->call("get_ship_entry", ship);
		if (entry.is_empty() || !entry.has("obb_body")) {
			return;
		}
		CollisionObject3D *obb_body = Object::cast_to<CollisionObject3D>(entry["obb_body"]);
		if (obb_body != nullptr) {
			obb_rids.append(obb_body->get_rid());
		}
	};

	append_ship_obb(projectile->get_owner());
	Array exclude = projectile->get_exclude();
	for (int i = 0; i < exclude.size(); i++) {
		append_ship_obb(Object::cast_to<Object>(exclude[i]));
	}
	return obb_rids;
}

Ref<Resource> NativeArmorInteraction::duplicate_shell_params_with_drag(const Ref<Resource> &params, double drag_multiplier) {
	if (!params.is_valid()) {
		return Ref<Resource>();
	}
	Ref<Resource> dup = params->duplicate(true);
	if (dup.is_valid()) {
		double drag = dup->get("drag");
		dup->set("drag", drag * drag_multiplier);
	}
	return dup;
}

Vector3 NativeArmorInteraction::handle_water_entry(const Vector3 &water_hit, const Vector3 &entry_vel, const Ref<Resource> &params) {
	Ref<Resource> water_params = duplicate_shell_params_with_drag(params, WATER_DRAG);
	if (!water_params.is_valid()) {
		return water_hit;
	}
	double fuze_delay = water_params->get("fuze_delay");
	return ProjectilePhysicsWithDragV2::calculate_position_at_time(water_hit, entry_vel, fuze_delay, water_params);
}

bool NativeArmorInteraction::try_get_water_plane_hit(const Vector3 &prev_pos, const Vector3 &curr_pos, Vector3 &water_hit) {
	if (prev_pos.y < 0.0 || curr_pos.y >= 0.0) {
		return false;
	}
	double dy = (double)curr_pos.y - (double)prev_pos.y;
	if (std::abs(dy) <= 0.000001) {
		return false;
	}
	double alpha = -(double)prev_pos.y / dy;
	if (alpha < 0.0 || alpha > 1.0) {
		return false;
	}
	water_hit = prev_pos + (curr_pos - prev_pos) * alpha;
	water_hit.y = 0.0;
	return true;
}

Dictionary NativeArmorInteraction::find_valid_obb_hit(PhysicsDirectSpaceState3D *space_state,
		const Ref<PhysicsRayQueryParameters3D> &obb_ray,
		Node *precision_physics_world,
		Object *owner,
		const Array &exclude,
		Object **out_ship) {
	if (out_ship != nullptr) {
		*out_ship = nullptr;
	}
	if (space_state == nullptr || !obb_ray.is_valid() || precision_physics_world == nullptr) {
		return Dictionary();
	}

	Array dynamic_excludes = obb_ray->get_exclude();
	for (int i = 0; i < 16; i++) {
		Dictionary hit = space_state->intersect_ray(obb_ray);
		if (hit.is_empty()) {
			return Dictionary();
		}

		Object *ship = Object::cast_to<Object>(precision_physics_world->call("get_ship_from_obb", hit["collider"]));
		if (!is_owner_or_excluded(ship, owner, exclude)) {
			if (out_ship != nullptr) {
				*out_ship = ship;
			}
			return hit;
		}

		if (hit.has("rid")) {
			dynamic_excludes.append(hit["rid"]);
			obb_ray->set_exclude(dynamic_excludes);
		} else {
			return Dictionary();
		}
	}
	return Dictionary();
}

bool NativeArmorInteraction::should_raycast_terrain(const Ref<NavigationMap> &nav_map,
		const Vector3 &from,
		const Vector3 &to) {
	if (!nav_map.is_valid() || !nav_map->is_built()) {
		return true;
	}

	Vector3 delta = to - from;
	double horizontal_len = std::sqrt((double)delta.x * delta.x + (double)delta.z * delta.z);
	float cell_size = nav_map->get_cell_size_value();
	double margin = std::max(2.0, (double)cell_size * 0.5);
	double terrain_step = std::max(5.0, (double)cell_size * 0.5);

	float start_sdf = nav_map->get_distance((float)from.x, (float)from.z);
	if (start_sdf > horizontal_len + margin) {
		return false;
	}

	int steps = horizontal_len > 0.001 ? std::max(2, (int)std::ceil(horizontal_len / terrain_step)) : 1;
	for (int i = 1; i <= steps; i++) {
		double alpha = (double)i / (double)steps;
		Vector3 pos = from + delta * alpha;
		float sdf = nav_map->get_distance((float)pos.x, (float)pos.z);
		if (sdf > margin) {
			continue;
		}

		float terrain_height = nav_map->get_terrain_height((float)pos.x, (float)pos.z);
		if (terrain_height > 0.001f && pos.y <= (double)terrain_height + margin) {
			return true;
		}
	}
	return false;
}

bool NativeArmorInteraction::is_citadel(Object *armor_part) {
	return armor_part != nullptr && (bool)armor_part->get("is_citadel");
}

int NativeArmorInteraction::armor_type(Object *armor_part) {
	return armor_part != nullptr ? (int)armor_part->get("type") : -1;
}

double NativeArmorInteraction::get_armor(Object *armor_part, int face_index) {
	if (armor_part == nullptr) {
		return 0.0;
	}
	return (double)armor_part->call("get_armor", face_index);
}

NativeArmorInteraction::HitResult NativeArmorInteraction::resolve_hit_result(ArmorResult armor_result, Object *final_part, bool hit_cit, bool over_pen) {
	if (armor_result == ARMOR_SHATTER) {
		return SHATTER;
	}
	if (armor_result == ARMOR_PARTIAL_PEN) {
		return PARTIAL_PEN;
	}

	bool in_citadel = final_part != nullptr && armor_type(final_part) == 1;
	if (in_citadel) {
		return CITADEL;
	}
	if (hit_cit && over_pen) {
		return CITADEL_OVERPEN;
	}
	if (final_part != nullptr) {
		return PENETRATION;
	}
	if (over_pen) {
		return OVERPENETRATION;
	}
	if (armor_result == ARMOR_RICOCHET) {
		return RICOCHET;
	}
	return OVERPENETRATION;
}

ArmorHitResult NativeArmorInteraction::process_travel(const Ref<ProjectileData> &projectile,
		const Vector3 &prev_pos,
		double t,
		PhysicsDirectSpaceState3D *space_state,
		Node *precision_physics_world,
		const Ref<NavigationMap> &nav_map) {
	if (!projectile.is_valid()) {
		return ArmorHitResult();
	}
	if (prev_pos.y < 0.0) {
		UtilityFunctions::print(String("[ERROR] process_travel: prev_pos is underwater (y=%f) — projectile should have been destroyed on a previous frame").replace("%f", String::num_real(prev_pos.y)));
		return make_result(WATER, prev_pos, nullptr, Vector3(), nullptr, Vector3());
	}

	Vector3 curr_pos = projectile->get_position();
	Vector3 travel = curr_pos - prev_pos;
	Vector3 extended_from = prev_pos;
	if (projectile->get_frame_count() != 0 && travel.length_squared() > 0.0) {
		extended_from = prev_pos - travel.normalized() * 10.0;
	}

	if (space_state == nullptr) {
		return ArmorHitResult();
	}

	Vector3 water_hit_pos;
	bool water_hit = try_get_water_plane_hit(prev_pos, curr_pos, water_hit_pos);
	bool skip_obb_for_height = std::min((double)prev_pos.y, (double)curr_pos.y) > SHIP_CLEAR_HEIGHT;

	bool use_terrain_physics = should_raycast_terrain(nav_map, extended_from, curr_pos);

	Ref<PhysicsRayQueryParameters3D> terrain_ray;
	if (use_terrain_physics) {
		terrain_ray.instantiate();
		terrain_ray->set_from(extended_from);
		terrain_ray->set_to(curr_pos);
		terrain_ray->set_hit_back_faces(true);
		terrain_ray->set_hit_from_inside(false);
		terrain_ray->set_collision_mask(1);
	}

	Ref<PhysicsRayQueryParameters3D> obb_ray;
	if (!skip_obb_for_height) {
		Array obb_excludes = build_obb_excludes(projectile, precision_physics_world);
		obb_ray.instantiate();
		obb_ray->set_from(extended_from);
		obb_ray->set_to(curr_pos);
		obb_ray->set_hit_back_faces(true);
		obb_ray->set_hit_from_inside(true);
		obb_ray->set_collision_mask(OBB_COLLISION_LAYER);
		obb_ray->set_exclude(obb_excludes);
	}

	Array projectile_exclude = projectile->get_exclude();
	Object *projectile_owner = projectile->get_owner();

	Dictionary terrain_result;
	if (use_terrain_physics) {
		terrain_result = space_state->intersect_ray(terrain_ray);
	}
	Dictionary obb_result;
	Object *precision_ship = nullptr;
	if (!skip_obb_for_height) {
		if (projectile_owner == nullptr) {
			obb_result = space_state->intersect_ray(obb_ray);
		} else {
			obb_result = find_valid_obb_hit(space_state, obb_ray, precision_physics_world,
				projectile_owner, projectile_exclude, &precision_ship);
		}
	}

	if (projectile_owner == nullptr) {
		double terrain_dist = INF_DIST;
		double water_dist = INF_DIST;
		double obb_dist = INF_DIST;
		if (!terrain_result.is_empty()) terrain_dist = prev_pos.distance_squared_to((Vector3)terrain_result["position"]);
		if (water_hit) water_dist = prev_pos.distance_squared_to(water_hit_pos);
		if (!obb_result.is_empty()) obb_dist = prev_pos.distance_squared_to((Vector3)obb_result["position"]);

		if (terrain_dist <= water_dist && terrain_dist <= obb_dist && terrain_dist < INF_DIST) {
			return make_result(TERRAIN, terrain_result["position"], nullptr, Vector3(), nullptr, terrain_result["normal"]);
		}
		if (water_dist <= obb_dist && water_dist < INF_DIST) {
			return make_result(WATER, water_hit_pos, nullptr, Vector3(), nullptr, Vector3());
		}
		return ArmorHitResult();
	}

	Dictionary precision_hit;
	if (!obb_result.is_empty() && precision_physics_world != nullptr && precision_ship != nullptr) {
		precision_physics_world->call("notify_obb_hit", precision_ship);
		precision_hit = precision_physics_world->call("narrowphase_hit", precision_ship, extended_from, curr_pos);
	}

	double terrain_dist = INF_DIST;
	double precision_dist = INF_DIST;
	double water_dist = INF_DIST;
	if (!terrain_result.is_empty() && ((Vector3)terrain_result["position"]).y > EPSILON) {
		terrain_dist = prev_pos.distance_squared_to((Vector3)terrain_result["position"]);
	}
	if (!precision_hit.is_empty()) {
		precision_dist = prev_pos.distance_squared_to((Vector3)precision_hit["world_pos"]);
	}
	if (water_hit) {
		water_dist = prev_pos.distance_squared_to(water_hit_pos);
	}

	if (terrain_dist <= precision_dist && terrain_dist <= water_dist && terrain_dist < INF_DIST) {
		return make_result(TERRAIN, terrain_result["position"], nullptr, Vector3(), nullptr, terrain_result["normal"]);
	}

	Vector3 precision_hit_pos;
	Vector3 precision_vel;
	double fuze = -1.0;
	if (!precision_hit.is_empty()) {
		precision_hit_pos = precision_hit["world_pos"];
		precision_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time(projectile->get_launch_velocity(), t, projectile->get_params());
	}

	bool hit_water = false;
	if (water_dist <= precision_dist && water_dist < INF_DIST) {
		hit_water = true;
		Vector3 water_pos = water_hit_pos;
		Vector3 fuzed_position = handle_water_entry(water_pos, precision_vel, projectile->get_params());
		obb_ray->set_from(water_pos);
		obb_ray->set_to(fuzed_position);
		Dictionary obb_result_underwater = find_valid_obb_hit(space_state, obb_ray, precision_physics_world,
			projectile_owner, projectile_exclude, &precision_ship);
		if (!obb_result_underwater.is_empty() && precision_physics_world != nullptr && precision_ship != nullptr) {
			precision_physics_world->call("notify_obb_hit", precision_ship);
			precision_hit = precision_physics_world->call("narrowphase_hit", precision_ship, water_pos, fuzed_position);
			if (precision_hit.is_empty()) {
				return make_result(WATER, water_pos, nullptr, Vector3(), nullptr, Vector3(0, 1, 0));
			}
			precision_hit_pos = precision_hit["world_pos"];
			precision_dist = prev_pos.distance_squared_to(precision_hit_pos);
			double total_dist = (fuzed_position - water_pos).length();
			double hit_dist = (precision_hit_pos - water_pos).length();
			double fuze_delay = projectile->get_params().is_valid() ? (double)projectile->get_params()->get("fuze_delay") : 0.0;
			double t_impact = fuze_delay * (hit_dist / std::max(total_dist, 0.001));
			Ref<Resource> water_params = duplicate_shell_params_with_drag(projectile->get_params(), WATER_DRAG);
			precision_vel = ProjectilePhysicsWithDragV2::calculate_velocity_at_time(precision_vel, t_impact, water_params);
			fuze = t_impact;
		} else {
			return make_result(WATER, water_pos, nullptr, Vector3(), nullptr, Vector3());
		}
	}

	if (precision_dist < INF_DIST && precision_ship != nullptr && !precision_hit.is_empty()) {
		return process_hit(Object::cast_to<Object>(precision_hit["armor"]),
			precision_hit["world_pos"],
			precision_hit["world_normal"],
			precision_hit["local_pos"],
			precision_hit["local_normal"],
			projectile,
			precision_vel,
			(int)precision_hit["face_index"],
			fuze,
			hit_water,
			precision_physics_world);
	}

	return ArmorHitResult();
}

ArmorHitResult NativeArmorInteraction::process_hit(Object *hit_node,
		const Vector3 &world_hit_position,
		const Vector3 &world_hit_normal,
		const Vector3 &local_hit_position,
		const Vector3 &local_hit_normal,
		const Ref<ProjectileData> &projectile,
		const Vector3 &impact_velocity,
		int face_index,
		double fuze,
		bool hit_water,
		Node *precision_physics_world) {
	if (hit_node == nullptr || !projectile.is_valid()) {
		return ArmorHitResult();
	}
	Ref<Resource> params = projectile->get_params();
	if (!params.is_valid()) {
		return ArmorHitResult();
	}

	Object *ship = Object::cast_to<Object>(hit_node->get("ship"));
	Node3D *ship_node = Object::cast_to<Node3D>(ship);
	if (ship == nullptr || ship_node == nullptr) {
		return ArmorHitResult();
	}

	Vector3 first_hit_normal = world_hit_normal;
	Vector3 first_hit_pos = world_hit_position;
	Object *first_hit_node = hit_node;
	bool overmatch_first_armor = false;

	Transform3D ship_xform = ship_node->get_global_transform();
	Basis ship_basis = ship_xform.basis;
	Basis ship_basis_inv = ship_basis.inverse();
	Vector3 hit_position = local_hit_position;
	Vector3 hit_normal = local_hit_normal.normalized();

	ShellState shell;
	shell.position = hit_position;
	shell.velocity = basis_xform(ship_basis_inv, impact_velocity);
	shell.fuze = fuze;
	shell.params = params;
	shell.calc_end_position();

	if (hit_water && (int)params->get("type") == 0) {
		return make_result(WATER, first_hit_pos, nullptr, impact_velocity, nullptr, first_hit_normal);
	}

	if ((int)params->get("type") == 0) {
		double armor_mm = get_armor(hit_node, face_index);
		HitResult he_result = ((double)params->get("overmatch") >= armor_mm) ? (is_citadel(hit_node) ? CITADEL : PENETRATION) : SHATTER;
		return make_result(he_result, first_hit_pos, hit_node, impact_velocity, ship, first_hit_normal);
	}

	ArmorResult result = ARMOR_OVERPEN;
	bool hit_cit = false;
	bool over_pen = false;
	int iteration = 0;
	const int max_iterations = 20;
	Vector3 offset;

	while (shell.fuze <= (double)params->get("fuze_delay") && result != ARMOR_SHATTER &&
		Object::cast_to<Object>(hit_node->get("ship")) == ship && iteration < max_iterations) {
		iteration++;
		double armor_mm = get_armor(hit_node, face_index);
		double speed = shell.get_speed();
		double impact_angle = calculate_impact_angle(shell.velocity.normalized(), hit_normal);
		double e_armor = calculate_effective_thickness(armor_mm, impact_angle);
		shell.pen = calculate_de_marre_penetration((double)params->get("mass"), speed, (double)params->get("caliber")) * (double)params->get("penetration_modifier");
		shell.position = hit_position + offset;
		offset = Vector3();

		if (armor_mm <= (double)params->get("overmatch")) {
			if (is_citadel(hit_node)) hit_cit = true;
			result = ARMOR_OVERPEN;
			over_pen = true;
			if (iteration == 1) overmatch_first_armor = true;
			double pen_ratio = e_armor / std::max(shell.pen, 1.0);
			shell.velocity *= (1.0 - pen_ratio);
			shell.integrity = calculate_shell_integrity(pen_ratio, shell.integrity);
			if (shell.velocity.length_squared() > 0.0) offset += shell.velocity.normalized() * EPSILON;
			if (shell.fuze < 0.0 && e_armor > (double)params->get("arming_threshold")) shell.fuze = 0.0;
		} else if (impact_angle >= (double)params->get("auto_bounce")) {
			result = ARMOR_RICOCHET;
			double k_nose = get_k_nose(params);
			double cos_a = std::max(std::cos(impact_angle), 0.05);
			double tan_a = std::tan(clampd(impact_angle, 0.0, 89.0 * DEG_TO_RAD));
			double td_ratio = armor_mm / std::max((double)params->get("caliber"), 1.0);
			double engagement = std::pow(clampd(td_ratio / TD_ENGAGE_REF, 0.0, 1.0), TD_ENGAGE_POWER);
			double f_td = 1.0 + TD_MOD_SCALE * clampd(td_ratio - TD_MOD_ONSET, 0.0, TD_MOD_MAX);
			double deflection_mult = 1.0 + engagement * k_nose * std::pow(tan_a, DEFLECTION_GAMMA) * f_td;
			double physics_armor = e_armor * deflection_mult;
			double energy_loss = clampd(shell.pen * cos_a / std::max(physics_armor, 0.1), 0.0, 0.8);
			shell.velocity = calculate_ricochet_velocity(shell.velocity, hit_normal, energy_loss);
			offset += hit_normal * EPSILON;
			if (shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD) shell.fuze = 0.0;
		} else {
			ArmorEval interaction = evaluate_armor_interaction(shell, params, impact_angle, armor_mm, e_armor);
			result = interaction.result;
			switch (result) {
				case ARMOR_RICOCHET:
					shell.velocity = calculate_ricochet_velocity(shell.velocity, hit_normal, interaction.energy_loss_fraction);
					offset += hit_normal * EPSILON;
					if (shell.fuze < 0.0 && impact_angle > 70.0 * DEG_TO_RAD) shell.fuze = 0.0;
					break;
				case ARMOR_SHATTER:
					shell.velocity = Vector3();
					shell.fuze = params->get("fuze_delay");
					shell.position += hit_normal * EPSILON;
					break;
				case ARMOR_PARTIAL_PEN:
					shell.velocity *= 0.1;
					shell.integrity *= 0.5;
					if (shell.velocity.length_squared() > 0.0) offset += shell.velocity.normalized() * EPSILON;
					break;
				case ARMOR_PEN:
				case ARMOR_OVERPEN: {
					if (is_citadel(hit_node)) hit_cit = true;
					over_pen = true;
					double exit_speed = calculate_exit_velocity(speed, shell.pen, e_armor);
					Vector3 exit_dir = calculate_deflected_direction(shell.velocity.normalized(), hit_normal, interaction.pen_ratio);
					shell.velocity = exit_dir * exit_speed;
					shell.integrity = calculate_shell_integrity(interaction.pen_ratio, shell.integrity);
					if (shell.velocity.length_squared() > 0.0) offset += shell.velocity.normalized() * EPSILON;
					if (shell.fuze < 0.0 && e_armor > (double)params->get("arming_threshold")) shell.fuze = 0.0;
					break;
				}
			}
		}

		if (result == ARMOR_SHATTER || result == ARMOR_PARTIAL_PEN || shell.get_speed() < MIN_VELOCITY) {
			shell.calc_end_position();
			break;
		}

		Vector3 next_ray_from = shell.position + offset;
		shell.calc_end_position();
		Vector3 next_ray_to = shell.end_position;
		Dictionary next_hit;
		if (precision_physics_world != nullptr) {
			next_hit = precision_physics_world->call("precision_get_next_hit", ship, next_ray_from, next_ray_to);
		}
		if (next_hit.is_empty()) {
			if (shell.fuze >= 0.0) shell.fuze = params->get("fuze_delay");
			break;
		}

		Vector3 old_pos = hit_position;
		hit_node = Object::cast_to<Object>(next_hit["armor"]);
		hit_position = next_hit["position"];
		hit_normal = ((Vector3)next_hit["normal"]).normalized();
		face_index = (int)next_hit["face_index"];
		double fuze_elapsed = old_pos.distance_to(hit_position) / std::max(shell.get_speed(), 0.001);
		if (shell.fuze >= 0.0) shell.fuze += fuze_elapsed;
		if (hit_node == nullptr) break;
	}

	Object *final_part = nullptr;
	if (precision_physics_world != nullptr) {
		final_part = Object::cast_to<Object>(precision_physics_world->call("precision_get_part_hit", ship, shell.end_position));
	}
	HitResult damage_result = resolve_hit_result(result, final_part, hit_cit, over_pen);
	if (damage_result == CITADEL_OVERPEN) {
		Variant citadel = ship->get("citadel");
		if (citadel.get_type() != Variant::NIL) {
			final_part = Object::cast_to<Object>(citadel);
		}
	}

	Vector3 final_world_vel = basis_xform(ship_basis, shell.velocity);
	ArmorHitResult hit_result = make_result(damage_result,
		first_hit_pos,
		final_part != nullptr ? final_part : first_hit_node,
		final_world_vel,
		ship,
		first_hit_normal,
		shell.integrity);
	hit_result.overmatch_first_armor = overmatch_first_armor;
	return hit_result;
}
