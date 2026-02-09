#include "projectile_manager.h"
#include "projectile_physics_with_drag_v2.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/scene_tree_timer.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/stream_peer_buffer.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/gd_script.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

void _ProjectileManager::_bind_methods() {
	// Bind enum
	BIND_ENUM_CONSTANT(PENETRATION);
	BIND_ENUM_CONSTANT(RICOCHET);
	BIND_ENUM_CONSTANT(OVERPENETRATION);
	BIND_ENUM_CONSTANT(SHATTER);
	BIND_ENUM_CONSTANT(NOHIT);
	BIND_ENUM_CONSTANT(CITADEL);
	BIND_ENUM_CONSTANT(WATER);

	// Bind initialization methods
	ClassDB::bind_method(D_METHOD("_init_compute_trails"), &_ProjectileManager::_init_compute_trails);
	ClassDB::bind_method(D_METHOD("_find_particle_system"), &_ProjectileManager::_find_particle_system);

	// Bind calculation methods
	ClassDB::bind_method(D_METHOD("calculate_penetration_power", "shell_params", "velocity"),
						 &_ProjectileManager::calculate_penetration_power);
	ClassDB::bind_method(D_METHOD("calculate_impact_angle", "velocity", "surface_normal"),
						 &_ProjectileManager::calculate_impact_angle);
	ClassDB::bind_static_method("_ProjectileManager", D_METHOD("next_pow_of_2", "value"), &_ProjectileManager::next_pow_of_2);
	ClassDB::bind_method(D_METHOD("find_ship", "node"), &_ProjectileManager::find_ship);

	// Bind process methods
	ClassDB::bind_method(D_METHOD("_process_trails_only", "current_time"),
						 &_ProjectileManager::_process_trails_only);

	// Bind fire bullet methods (snake_case)
	ClassDB::bind_method(D_METHOD("fire_bullet", "vel", "pos", "shell", "t", "owner", "exclude"),
						 &_ProjectileManager::fire_bullet, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("fire_bullet_client", "pos", "vel", "t", "id", "shell", "owner",
								  "muzzle_blast", "basis"),
						 &_ProjectileManager::fire_bullet_client, DEFVAL(true), DEFVAL(Basis()));

	// Bind fire bullet methods (camelCase aliases for backward compatibility)
	ClassDB::bind_method(D_METHOD("fireBullet", "vel", "pos", "shell", "t", "owner", "exclude"),
						 &_ProjectileManager::fire_bullet, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("fireBulletClient", "pos", "vel", "t", "id", "shell", "owner",
								  "muzzle_blast", "basis"),
						 &_ProjectileManager::fire_bullet_client, DEFVAL(true), DEFVAL(Basis()));

	// Bind destroy bullet RPC methods (snake_case)
	ClassDB::bind_method(D_METHOD("destroy_bullet_rpc", "id", "position", "hit_result", "normal"),
						 &_ProjectileManager::destroy_bullet_rpc);
	ClassDB::bind_method(D_METHOD("destroy_bullet_rpc2", "id", "pos", "hit_result", "normal"),
						 &_ProjectileManager::destroy_bullet_rpc2);
	ClassDB::bind_method(D_METHOD("destroy_bullet_rpc3", "data"), &_ProjectileManager::destroy_bullet_rpc3);

	// Bind destroy bullet RPC methods (camelCase aliases for backward compatibility)
	ClassDB::bind_method(D_METHOD("destroyBulletRpc", "id", "position", "hit_result", "normal"),
						 &_ProjectileManager::destroy_bullet_rpc);
	ClassDB::bind_method(D_METHOD("destroyBulletRpc2", "id", "pos", "hit_result", "normal"),
						 &_ProjectileManager::destroy_bullet_rpc2);
	ClassDB::bind_method(D_METHOD("destroyBulletRpc3", "data"), &_ProjectileManager::destroy_bullet_rpc3);

	// Bind damage methods
	ClassDB::bind_method(D_METHOD("apply_fire_damage", "projectile", "ship", "hit_position"),
						 &_ProjectileManager::apply_fire_damage);
	ClassDB::bind_method(D_METHOD("print_armor_debug", "armor_result", "ship"),
						 &_ProjectileManager::print_armor_debug);
	ClassDB::bind_method(D_METHOD("validate_penetration_formula"),
						 &_ProjectileManager::validate_penetration_formula);

	// Bind ricochet RPC methods (snake_case)
	ClassDB::bind_method(D_METHOD("create_ricochet_rpc", "original_shell_id", "new_shell_id",
								  "ricochet_position", "ricochet_velocity", "ricochet_time"),
						 &_ProjectileManager::create_ricochet_rpc);
	ClassDB::bind_method(D_METHOD("create_ricochet_rpc2", "data"), &_ProjectileManager::create_ricochet_rpc2);

	// Bind ricochet RPC methods (camelCase aliases for backward compatibility)
	ClassDB::bind_method(D_METHOD("createRicochetRpc", "original_shell_id", "new_shell_id",
								  "ricochet_position", "ricochet_velocity", "ricochet_time"),
						 &_ProjectileManager::create_ricochet_rpc);
	ClassDB::bind_method(D_METHOD("createRicochetRpc2", "data"), &_ProjectileManager::create_ricochet_rpc2);

	// Bind getters
	ClassDB::bind_method(D_METHOD("get_shell_time_multiplier"), &_ProjectileManager::get_shell_time_multiplier);
	ClassDB::bind_method(D_METHOD("get_next_id"), &_ProjectileManager::get_next_id);
	ClassDB::bind_method(D_METHOD("get_projectiles"), &_ProjectileManager::get_projectiles);
	ClassDB::bind_method(D_METHOD("get_ids_reuse"), &_ProjectileManager::get_ids_reuse);
	ClassDB::bind_method(D_METHOD("get_shell_param_ids"), &_ProjectileManager::get_shell_param_ids);
	ClassDB::bind_method(D_METHOD("get_bullet_id"), &_ProjectileManager::get_bullet_id);
	ClassDB::bind_method(D_METHOD("get_gpu_renderer"), &_ProjectileManager::get_gpu_renderer);
	ClassDB::bind_method(D_METHOD("get_compute_particle_system"), &_ProjectileManager::get_compute_particle_system);
	ClassDB::bind_method(D_METHOD("get_trail_template_id"), &_ProjectileManager::get_trail_template_id);
	ClassDB::bind_method(D_METHOD("get_camera"), &_ProjectileManager::get_camera);

	// Bind find_ship with camelCase alias for backward compatibility
	ClassDB::bind_method(D_METHOD("findShip", "node"), &_ProjectileManager::find_ship);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_shell_time_multiplier", "value"), &_ProjectileManager::set_shell_time_multiplier);
	ClassDB::bind_method(D_METHOD("set_next_id", "value"), &_ProjectileManager::set_next_id);
	ClassDB::bind_method(D_METHOD("set_projectiles", "value"), &_ProjectileManager::set_projectiles);
	ClassDB::bind_method(D_METHOD("set_ids_reuse", "value"), &_ProjectileManager::set_ids_reuse);
	ClassDB::bind_method(D_METHOD("set_shell_param_ids", "value"), &_ProjectileManager::set_shell_param_ids);
	ClassDB::bind_method(D_METHOD("set_bullet_id", "value"), &_ProjectileManager::set_bullet_id);
	ClassDB::bind_method(D_METHOD("set_gpu_renderer", "value"), &_ProjectileManager::set_gpu_renderer);
	ClassDB::bind_method(D_METHOD("set_compute_particle_system", "value"), &_ProjectileManager::set_compute_particle_system);
	ClassDB::bind_method(D_METHOD("set_trail_template_id", "value"), &_ProjectileManager::set_trail_template_id);
	ClassDB::bind_method(D_METHOD("set_camera", "value"), &_ProjectileManager::set_camera);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "shell_time_multiplier"),
				 "set_shell_time_multiplier", "get_shell_time_multiplier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "next_id"), "set_next_id", "get_next_id");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "projectiles"), "set_projectiles", "get_projectiles");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "ids_reuse"), "set_ids_reuse", "get_ids_reuse");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "shell_param_ids"), "set_shell_param_ids", "get_shell_param_ids");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "bullet_id"), "set_bullet_id", "get_bullet_id");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "gpu_renderer", PROPERTY_HINT_NODE_TYPE, "Node"),
				 "set_gpu_renderer", "get_gpu_renderer");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "compute_particle_system", PROPERTY_HINT_NODE_TYPE, "Node"),
				 "set_compute_particle_system", "get_compute_particle_system");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "trail_template_id"), "set_trail_template_id", "get_trail_template_id");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "camera", PROPERTY_HINT_NODE_TYPE, "Camera3D"),
				 "set_camera", "get_camera");
}

_ProjectileManager::_ProjectileManager() {
	shell_time_multiplier = 2.0;
	next_id = 0;
	bullet_id = 0;
	gpu_renderer = nullptr;
	compute_particle_system = nullptr;
	trail_template_id = -1;
	camera = nullptr;
	armor_interaction = nullptr;
	tcp_thread_pool = nullptr;
	sound_effect_manager = nullptr;

	ray_query.instantiate();
	mesh_ray_query.instantiate();
}

_ProjectileManager::~_ProjectileManager() {
	// Clean up if needed
}

void _ProjectileManager::_ready() {
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
		UtilityFunctions::print("running server");

		ray_query->set_collide_with_areas(true);
		ray_query->set_collide_with_bodies(true);
		ray_query->set_collision_mask(1 | (1 << 1)); // world and detailed mesh collision
		ray_query->set_hit_back_faces(true);

		// Configure mesh ray query for detailed armor intersection
		mesh_ray_query->set_collide_with_areas(false);
		mesh_ray_query->set_collide_with_bodies(true);
		mesh_ray_query->set_collision_mask(1 << 1); // Second physics layer for detailed mesh collision
		mesh_ray_query->set_hit_back_faces(true);

		// Cache ArmorInteraction autoload reference
		if (has_node("/root/ArmorInteraction")) {
			armor_interaction = get_node<Node>("/root/ArmorInteraction");
			UtilityFunctions::print("Cached ArmorInteraction autoload");
		} else {
			UtilityFunctions::push_warning("ArmorInteraction autoload not found!");
		}

		// Cache TcpThreadPool autoload reference
		if (has_node("/root/TcpThreadPool")) {
			tcp_thread_pool = get_node<Node>("/root/TcpThreadPool");
			UtilityFunctions::print("Cached TcpThreadPool autoload");
		} else {
			UtilityFunctions::push_warning("TcpThreadPool autoload not found!");
		}

		set_process(false);
	} else {
		UtilityFunctions::print("running client");
		set_physics_process(false);

		// Cache SoundEffectManager autoload reference
		if (has_node("/root/SoundEffectManager")) {
			sound_effect_manager = get_node<Node>("/root/SoundEffectManager");
			UtilityFunctions::print("Cached SoundEffectManager autoload");
		} else {
			UtilityFunctions::push_warning("SoundEffectManager autoload not found!");
		}

		// Initialize GPU-based renderer
		Ref<Resource> gpu_renderer_script = ResourceLoader::get_singleton()->load(
			"res://src/artillary/GPUProjectileRenderer.gd");
		if (gpu_renderer_script.is_valid()) {
			Ref<Script> script = gpu_renderer_script;
			if (script.is_valid()) {
				Variant instance = script->call("new");
				gpu_renderer = Object::cast_to<Node>(instance);
				if (gpu_renderer) {
					gpu_renderer->call("set_time_multiplier", shell_time_multiplier);
					add_child(gpu_renderer);
					UtilityFunctions::print("Using GPU-based projectile rendering");
				}
			}
		}

		// Initialize compute particle system for trails (deferred to ensure it exists)
		Ref<SceneTreeTimer> timer = get_tree()->create_timer(0.5);
		timer->connect("timeout", Callable(this, "_init_compute_trails"));
	}

	projectiles.resize(1);
}

void _ProjectileManager::_init_compute_trails() {
	UtilityFunctions::print("ProjectileManager: Initializing compute trails...");

	// Find the UnifiedParticleSystem in the scene tree
	compute_particle_system = _find_particle_system();

	if (compute_particle_system == nullptr) {
		UtilityFunctions::push_warning("ProjectileManager: UnifiedParticleSystem not found, trails disabled");
		return;
	}

	UtilityFunctions::print("ProjectileManager: Found UnifiedParticleSystem");

	// Get or register the shell trail template
	// The template should be pre-registered by ParticleSystemInit with align_to_velocity = true
	Variant template_manager_var = compute_particle_system->get("template_manager");
	if (template_manager_var.get_type() != Variant::NIL) {
		Object *template_manager = Object::cast_to<Object>(template_manager_var);
		if (template_manager) {
			trail_template_id = template_manager->call("get_template_id", "shell_trail");
			UtilityFunctions::print(String("ProjectileManager: shell_trail template_id = %d").replace("%d",
				String::num_int64(trail_template_id)));
			if (trail_template_id < 0) {
				UtilityFunctions::push_warning("ProjectileManager: 'shell_trail' template not found, trails disabled");
				return;
			}
		}
	} else {
		UtilityFunctions::push_warning("ProjectileManager: Template manager not found, trails disabled");
		return;
	}

	UtilityFunctions::print(String("ProjectileManager: Using compute shader trails (template_id=%d)").replace("%d",
		String::num_int64(trail_template_id)));
}

Node *_ProjectileManager::_find_particle_system() {
	// Make sure we're in the scene tree before trying to access nodes
	if (!is_inside_tree()) {
		UtilityFunctions::push_warning("ProjectileManager: Not in scene tree, cannot find particle system");
		return nullptr;
	}

	SceneTree *tree = get_tree();
	if (tree == nullptr) {
		UtilityFunctions::push_warning("ProjectileManager: No scene tree available");
		return nullptr;
	}

	Window *root = tree->get_root();
	if (root == nullptr) {
		UtilityFunctions::push_warning("ProjectileManager: No root window available");
		return nullptr;
	}

	// Check common locations using the root node
	if (root->has_node("UnifiedParticleSystem")) {
		return root->get_node<Node>("UnifiedParticleSystem");
	}

	// Search in root children
	TypedArray<Node> children = root->get_children();
	for (int i = 0; i < children.size(); i++) {
		Node *child = Object::cast_to<Node>(children[i]);
		if (child && child->get_class() == "UnifiedParticleSystem") {
			return child;
		}
		// Check one level deeper
		TypedArray<Node> grandchildren = child->get_children();
		for (int j = 0; j < grandchildren.size(); j++) {
			Node *grandchild = Object::cast_to<Node>(grandchildren[j]);
			if (grandchild && grandchild->get_class() == "UnifiedParticleSystem") {
				return grandchild;
			}
		}
	}

	return nullptr;
}

double _ProjectileManager::calculate_penetration_power(const Ref<Resource> &shell_params, double velocity) {
	if (!shell_params.is_valid()) {
		return 0.0;
	}

	// Get shell parameters
	double weight_kg = shell_params->get("mass");
	double caliber_mm = shell_params->get("caliber");
	double velocity_ms = velocity;
	int shell_type = shell_params->get("type");
	double penetration_modifier = shell_params->get("penetration_modifier");

	// Modified naval armor penetration formula based on historical data
	// This version uses empirically derived constants for realistic results
	// Penetration (mm) = K * W^0.55 * V^1.1 / D^0.65
	double naval_constant_metric = 0.55664;

	double base_penetration = naval_constant_metric * std::pow(weight_kg, 0.55) *
							  std::pow(velocity_ms, 1.1) / std::pow(caliber_mm, 0.65);

	// Apply shell type modifiers
	double shell_quality_factor = 1.0;
	if (shell_type == 1) { // AP shell (assuming AP = 1)
		shell_quality_factor = 1.0; // AP shells are the baseline
	} else { // HE shell
		shell_quality_factor = 0.4; // HE shells have much reduced penetration
	}

	// Apply shell-specific penetration modifier
	shell_quality_factor *= penetration_modifier;

	double final_penetration = base_penetration * shell_quality_factor;

	return final_penetration;
}

double _ProjectileManager::calculate_impact_angle(const Vector3 &velocity, const Vector3 &surface_normal) {
	// Calculate angle between velocity vector and surface normal (returns radians)
	double angle_rad = velocity.normalized().angle_to(surface_normal);
	return std::min(angle_rad, Math_PI - angle_rad);
}

int _ProjectileManager::next_pow_of_2(int value) {
	if (value <= 0) {
		return 1;
	}

	// Bit manipulation to find next power of 2
	int result = value;
	result -= 1;
	result |= result >> 1;
	result |= result >> 2;
	result |= result >> 4;
	result |= result >> 8;
	result |= result >> 16;
	result += 1;
	return result;
}

Object *_ProjectileManager::find_ship(Node *node) {
	if (node == nullptr) {
		return nullptr;
	}
	if (node->get_class() == "Ship") {
		return node;
	}
	return find_ship(node->get_parent());
}

void _ProjectileManager::_process(double delta) {
	double current_time = Time::get_singleton()->get_unix_time_from_system();

	if (camera == nullptr) {
		return;
	}

	// Update shell positions in GPU renderer and trail particles
	_process_trails_only(current_time);
}

void _ProjectileManager::_process_trails_only(double current_time) {
	for (int i = 0; i < projectiles.size(); i++) {
		Variant p_var = projectiles[i];
		if (p_var.get_type() == Variant::NIL) {
			continue;
		}

		Ref<ProjectileData> p = p_var;
		if (!p.is_valid()) {
			continue;
		}

		Ref<Resource> shell_params = p->get_params();
		if (!shell_params.is_valid()) {
			continue;
		}
		double t = (current_time - p->get_start_time()) * shell_time_multiplier;
		// t = _ProjectileManager::time_warp(t,shell_params) * shell_time_multiplier;

		// Calculate position for rendering and trail emission
		// Use native ProjectilePhysicsWithDragV2 static method directly
		Vector3 new_position = ProjectilePhysicsWithDragV2::calculate_position_at_time(
			p->get_start_position(), p->get_launch_velocity(), t, shell_params);

		p->set_position(new_position);

		// Update GPU renderer with new position
		int gpu_id = p->get_frame_count();  // GPU slot ID stored in frame_count
		if (gpu_renderer != nullptr && gpu_id >= 0) {
			gpu_renderer->call("update_shell_position", gpu_id, new_position);
		}

		// Skip trail emission near spawn point
		if ((p->get_position() - p->get_start_position()).length_squared() < 80) {
			continue;
		}

		// Use GPU emitter system for trails if available
		if (compute_particle_system != nullptr && p->get_emitter_id() >= 0) {
			// Simply update the emitter position - GPU handles emission automatically
			compute_particle_system->call("update_emitter_position", p->get_emitter_id(), p->get_position());
		}
	}
}

void _ProjectileManager::_physics_process(double delta) {
	double current_time = Time::get_singleton()->get_unix_time_from_system();

	Window *root = get_tree()->get_root();
	Ref<World3D> world = root->get_world_3d();
	if (!world.is_valid()) {
		return;
	}

	PhysicsDirectSpaceState3D *space_state = world->get_direct_space_state();
	if (space_state == nullptr) {
		UtilityFunctions::push_warning("ProjectileManager: No PhysicsDirectSpaceState3D available");
	}

	int id = 0;
	for (int i = 0; i < projectiles.size(); i++) {
		Variant p_var = projectiles[i];
		if (p_var.get_type() == Variant::NIL) {
			id++;
			continue;
		}

		Ref<ProjectileData> p = p_var;
		if (!p.is_valid()) {
			id++;
			continue;
		}

		p->increment_frame_count();

		double t = (current_time - p->get_start_time()) * shell_time_multiplier;
		// t = _ProjectileManager::time_warp(t, p->get_params()) * shell_time_multiplier;


		ray_query->set_from(p->get_position());

		// Calculate new position using native ProjectilePhysicsWithDragV2 static method
		Ref<Resource> shell_params = p->get_params();
		if (!shell_params.is_valid()) {
			UtilityFunctions::push_warning("ProjectileManager: Projectile has invalid shell_params, skipping");
			id++;
			continue;
		}
		Vector3 new_position = ProjectilePhysicsWithDragV2::calculate_position_at_time(
			p->get_start_position(), p->get_launch_velocity(), t, shell_params);
		p->set_position(new_position);
		ray_query->set_to(p->get_position());

		// Process travel through ArmorInteraction - using cached autoload reference
		Variant hit_result;
		if (armor_interaction != nullptr) {
			hit_result = armor_interaction->call("process_travel", p, ray_query->get_from(), t, space_state);
		} else {
			UtilityFunctions::push_warning("ProjectileManager: ArmorInteraction autoload not cached");
		}

		if (hit_result.get_type() == Variant::NIL) {
			id++;
			continue;
		}

		// Process the hit result - hit_result is an ArmorResultData object, not a Dictionary
		// ArmorInteraction.HitResult enum values:
		// PENETRATION=0, PARTIAL_PEN=1, RICOCHET=2, OVERPENETRATION=3, SHATTER=4,
		// CITADEL=5, CITADEL_OVERPEN=6, WATER=7, TERRAIN=8
		// _ProjectileManager::HitResult enum values (for RPC):
		// PENETRATION=0, RICOCHET=1, OVERPENETRATION=2, SHATTER=3, NOHIT=4, CITADEL=5, WATER=6

		Object *hit_obj = Object::cast_to<Object>(hit_result);
		if (hit_obj == nullptr) {
			id++;
			continue;
		}

		int armor_result_type = hit_obj->get("result_type");
		Vector3 explosion_position = hit_obj->get("explosion_position");
		Vector3 collision_normal = hit_obj->get("collision_normal");
		Variant ship_var = hit_obj->get("ship");
		Variant armor_part_var = hit_obj->get("armor_part");
		Vector3 ricochet_velocity = hit_obj->get("velocity");
		Object *owner = p->get_owner();

		// Handle water and terrain hits (no ship involved)
		if (armor_result_type == 7) { // WATER
			destroy_bullet_rpc(id, explosion_position, WATER, collision_normal);
			id++;
			continue;
		} else if (armor_result_type == 8) { // TERRAIN
			destroy_bullet_rpc(id, explosion_position, PENETRATION, collision_normal);
			id++;
			continue;
		}

		// Handle ship hits
		if (ship_var.get_type() != Variant::NIL && owner != nullptr) {
			Node *ship = Object::cast_to<Node>(ship_var);
			Array exclude = p->get_exclude();

			bool in_exclude = false;
			for (int j = 0; j < exclude.size(); j++) {
				if (Object::cast_to<Object>(exclude[j]) == ship) {
					in_exclude = true;
					break;
				}
			}

			if (!in_exclude && ship != owner) {
				Ref<Resource> params = p->get_params();
				double base_damage = 0.0;
				if (params.is_valid()) {
					base_damage = params->get("damage");
				}

				double damage = 0.0;
				int rpc_result_type = NOHIT;

				// Map ArmorInteraction result to damage and RPC result type
				switch (armor_result_type) {
					case 0: // PENETRATION
						damage = base_damage / 3.0;
						rpc_result_type = PENETRATION;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 1: // PARTIAL_PENETRATION
						damage = base_damage / 8.0;
						rpc_result_type = PENETRATION;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 5: // CITADEL
						damage = base_damage;
						rpc_result_type = CITADEL;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 6: // CITADEL_OVERPEN
						damage = base_damage * 0.5;
						rpc_result_type = PENETRATION;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 3: // OVERPENETRATION
						damage = base_damage * 0.1;
						rpc_result_type = OVERPENETRATION;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 4: // SHATTER
						damage = 0.0;
						rpc_result_type = SHATTER;
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					case 2: { // RICOCHET
						damage = 0.0;
						rpc_result_type = RICOCHET;
						Vector3 ricochet_position = explosion_position + collision_normal * 0.2 + ricochet_velocity.normalized() * 0.2;

						// Create ricochet projectile with ship added to exclude list
						Array new_exclude = exclude.duplicate();
						new_exclude.append(ship);
						int ricochet_id = fire_bullet(ricochet_velocity, ricochet_position, params, current_time, nullptr, new_exclude);

						// Send ricochet RPC via TcpThreadPool
						if (tcp_thread_pool != nullptr) {
							tcp_thread_pool->call("send_ricochet", id, ricochet_id, ricochet_position, ricochet_velocity, current_time);
						}

						// Destroy the original shell
						destroy_bullet_rpc(id, explosion_position, rpc_result_type, collision_normal);
						break;
					}
					default:
						break;
				}

				// Apply damage to ship if alive
				Variant health_controller_var = ship->get("health_controller");
				if (health_controller_var.get_type() != Variant::NIL) {
					Object *health_controller = Object::cast_to<Object>(health_controller_var);
					if (health_controller && health_controller->call("is_alive")) {
						bool is_penetration = (rpc_result_type == PENETRATION || rpc_result_type == CITADEL); // PENETRATION
						Array dmg_sunk = health_controller->call("apply_damage", damage, base_damage, armor_part_var, is_penetration, p->get_params()->get("caliber"));

						Object* team = Object::cast_to<Object>(ship->get("team"));
						Object* owner_team = Object::cast_to<Object>(owner->get("team"));
						int owner_team_id = owner_team->get("team_id");
						int team_id = team->get("team_id");
						if (team_id != owner_team_id) {

							// Apply fire damage
							apply_fire_damage(p, ship, explosion_position);

							// Delegate all stat tracking to GDScript Stats.record_hit()
							if (dmg_sunk.size() > 0) {
								Variant stats_var = owner->get("stats");
								if (stats_var.get_type() != Variant::NIL) {
									Object *stats = Object::cast_to<Object>(stats_var);
									if (stats) {
										Ref<Resource> params = p->get_params();
										bool is_secondary = params.is_valid() && (bool)params->get("_secondary");
										bool sunk = dmg_sunk.size() > 1 && (bool)dmg_sunk[1];
										Vector3 hit_position = ship->call("get_global_position");
										double hit_damage = dmg_sunk[0];

										stats->call("record_hit", armor_result_type, hit_damage, is_secondary, hit_position, sunk, ship);
									}
								}
							}
						}
					}
				} else {
					UtilityFunctions::push_error("ProjectileManager: Ship does NOT have health_controller member variable");
				}
			}
		}

		id++;
	}
}

int _ProjectileManager::fire_bullet(const Vector3 &vel, const Vector3 &pos, const Ref<Resource> &shell,
								   double t, Object *owner, const Array &exclude) {
	int id;
	if (ids_reuse.size() > 0) {
		id = ids_reuse[ids_reuse.size() - 1];
		ids_reuse.resize(ids_reuse.size() - 1);
	} else {
		id = next_id;
		next_id++;
	}

	if (id >= projectiles.size()) {
		int np2 = next_pow_of_2(id + 1);
		projectiles.resize(np2);
	}

	Ref<ProjectileData> bullet;
	bullet.instantiate();
	bullet->initialize(pos, vel, t, shell, owner, exclude);

	projectiles[id] = bullet;

	return id;
}

void _ProjectileManager::fire_bullet_client(const Vector3 &pos, const Vector3 &vel, double t, int id,
										   const Ref<Resource> &shell, Object *owner,
										   bool muzzle_blast, const Basis &basis) {
	Ref<ProjectileData> bullet;
	bullet.instantiate();

	// Determine shell color based on type (matches original shell colors)
	Color shell_color;
	int shell_type = 1; // Default to AP
	if (shell.is_valid()) {
		shell_type = shell->get("type");
	}

	if (shell_type == 1) { // AP
		shell_color = Color(0.05, 0.1, 1.0, 1.0); // Blue for AP
	} else {
		shell_color = Color(1.0, 0.2, 0.05, 1.0); // Orange for HE
	}

	// Fire shell through GPU renderer (it manages its own IDs internally)
	int gpu_id = -1;
	if (gpu_renderer != nullptr) {
		double drag = 0.009;
		double size = 1.0;
		if (shell.is_valid()) {
			drag = shell->get("drag");
			size = shell->get("size");
		}
		gpu_id = gpu_renderer->call("fire_shell", pos, vel, drag, size, shell_type, shell_color);
	}

	// Still track in projectiles array for trail emission and ID mapping
	if (id >= projectiles.size()) {
		int np2 = next_pow_of_2(id + 1);
		projectiles.resize(np2);
	}

	bullet->initialize(pos, vel, t, shell, owner);
	bullet->set_frame_count(gpu_id); // Store GPU renderer ID in frame_count for mapping

	// Allocate GPU emitter for trail emission
	if (compute_particle_system != nullptr && trail_template_id >= 0) {
		double size = 1.0;
		if (shell.is_valid()) {
			size = shell->get("size");
		}
		double width_scale = size * 0.9;
		// emit_rate = 0.05 means 1 particle per 20 units (matching old step_size)
		int emitter_id = compute_particle_system->call("allocate_emitter",
			trail_template_id,  // template_id
			pos,                // starting_position
			width_scale,        // size_multiplier
			0.05,               // emit_rate (1/20 = 0.05 particles per unit)
			1.0,                // speed_scale
			0.0                 // velocity_boost
		);
		bullet->set_emitter_id(emitter_id);
	}

	projectiles[id] = bullet;

	if (muzzle_blast) {
		// Call HitEffects.muzzle_blast_effect - this is a GDScript autoload
		if (has_node("/root/HitEffects")) {
			Node *hit_effects = get_node<Node>("/root/HitEffects");
			double size = 1.0;
			if (shell.is_valid()) {
				size = shell->get("size");
			}
			hit_effects->call("muzzle_blast_effect", pos, basis, size * size);
		}

		// // Play gun firing sound via SoundEffectManager
		// if (sound_effect_manager != nullptr) {
		// 	double caliber = 100.0;
		// 	if (shell.is_valid()) {
		// 		caliber = shell->get("caliber");
		// 	}
		// 	double size_factor = pow(caliber, 2.3) / 10000.0;
		// 	double pitch_scale = 30.0 / size_factor;

		// 	// Add some randomness to pitch
		// 	double random_variation = (static_cast<double>(rand()) / RAND_MAX) * 0.2 - 0.1; // -0.1 to 0.1
		// 	double final_pitch = pitch_scale + (pitch_scale * pitch_scale) * random_variation;
		// 	// Calculate volume
		// 	double vol_variation = (static_cast<double>(rand()) / RAND_MAX) * 0.6 - 0.3; // -0.3 to 0.3
		// 	double final_vol = (caliber / 400 + vol_variation) / 30.0;
		// 	sound_effect_manager->call("play_explosion", pos, final_pitch, final_vol);
		// }
	}
}

void _ProjectileManager::destroy_bullet_rpc(int id, const Vector3 &position, int hit_result, const Vector3 &normal) {
	projectiles[id] = Variant();
	ids_reuse.append(id);

	// Send destroy message through TcpThreadPool
	if (has_node("/root/TcpThreadPool")) {
		Node *tcp_pool = get_node<Node>("/root/TcpThreadPool");
		tcp_pool->call("send_destroy_shell", id, position, hit_result, normal);
	} else {
		UtilityFunctions::push_warning("TcpThreadPool not found, cannot send destroy_shell message");
	}
}

void _ProjectileManager::destroy_bullet_rpc2(int id, const Vector3 &pos, int hit_result, const Vector3 &normal) {
	if (id >= projectiles.size()) {
		UtilityFunctions::print("bullet is null: ", id);
		return;
	}

	Variant bullet_var = projectiles[id];
	if (bullet_var.get_type() == Variant::NIL) {
		UtilityFunctions::print("bullet is null: ", id);
		return;
	}

	Ref<ProjectileData> bullet = bullet_var;
	if (!bullet.is_valid()) {
		UtilityFunctions::print("bullet is null: ", id);
		return;
	}

	double radius = 1.0;
	Ref<Resource> params = bullet->get_params();
	if (params.is_valid()) {
		radius = params->get("size");
	}

	// Free the GPU emitter if one was allocated
	if (bullet->get_emitter_id() >= 0 && compute_particle_system != nullptr) {
		compute_particle_system->call("free_emitter", bullet->get_emitter_id());
		bullet->set_emitter_id(-1);
	}

	// Destroy in GPU renderer
	int gpu_id = bullet->get_frame_count(); // GPU renderer ID was stored here
	if (gpu_renderer != nullptr) {
		gpu_renderer->call("destroy_shell", gpu_id);
	}

	projectiles[id] = Variant();

	// Create hit effects
	if (has_node("/root/HitEffects")) {
		// UtilityFunctions::print("Creating hit effects for bullet id: ", id);
		Node *hit_effects = get_node<Node>("/root/HitEffects");

		switch (hit_result) {
			case WATER:
				hit_effects->call("splash_effect", pos, radius);
				break;
			case PENETRATION:
				hit_effects->call("he_explosion_effect", pos, radius * 0.8, normal);
				hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
				if (sound_effect_manager != nullptr) {
					float volume = (radius) / 8.0 / 10.0;
					float pitch = 1.3 / (radius * 0.4);
					sound_effect_manager->call("play_explosion", pos, pitch, volume);
				}
				break;
			case CITADEL:
				hit_effects->call("he_explosion_effect", pos, radius * 1.2, normal);
				hit_effects->call("sparks_effect", pos, radius * 0.6, normal);
				if (sound_effect_manager != nullptr) {
					float volume = (radius) / 4.0 / 10.0;
					float pitch = 1.0 / (radius * 0.45);
					sound_effect_manager->call("play_explosion", pos, pitch, volume);
				}
				break;
			case RICOCHET:
			case OVERPENETRATION:
			case SHATTER:
				hit_effects->call("sparks_effect", pos, radius * 0.5, normal);
				if (sound_effect_manager != nullptr) {
					float volume = (0.1 + (radius) / 15.0) / 15.0;
					float pitch = 2.0 / (radius * 0.4);
					sound_effect_manager->call("play_explosion", pos, pitch, volume);
				}
				break;
			case NOHIT:
				// No explosion for NOHIT
				break;
		}
	} else {
		UtilityFunctions::push_warning("HitEffects not found, cannot create hit effects");
	}
}

void _ProjectileManager::destroy_bullet_rpc3(const PackedByteArray &data) {
	if (data.size() < 17) {
		UtilityFunctions::print("Invalid data size for destroy_bullet_rpc3");
		return;
	}

	Ref<StreamPeerBuffer> stream;
	stream.instantiate();
	stream->set_data_array(data);

	int id = stream->get_32();
	Vector3 pos(stream->get_float(), stream->get_float(), stream->get_float());
	int hit_result = stream->get_8();
	Vector3 normal(stream->get_float(), stream->get_float(), stream->get_float());

	destroy_bullet_rpc2(id, pos, hit_result, normal);
}

void _ProjectileManager::apply_fire_damage(const Ref<ProjectileData> &projectile, Object *ship,
										  const Vector3 &hit_position) {
	if (!projectile.is_valid() || ship == nullptr) {
		return;
	}

	Ref<Resource> params = projectile->get_params();
	if (!params.is_valid()) {
		return;
	}

	double fire_buildup = params->get("fire_buildup");
	if (fire_buildup <= 0) {
		return;
	}

	// Get fire manager from ship
	Variant fire_manager_var = ship->get("fire_manager");
	if (fire_manager_var.get_type() == Variant::NIL) {
		return;
	}

	Object *fire_manager = Object::cast_to<Object>(fire_manager_var);
	if (fire_manager == nullptr) {
		return;
	}

	// Find closest fire
	Array fires = fire_manager->get("fires");
	Object *closest_fire = nullptr;
	double closest_fire_dist = 1e9;

	for (int i = 0; i < fires.size(); i++) {
		Object *f = Object::cast_to<Object>(fires[i]);
		if (f == nullptr) continue;

		Vector3 fire_pos = f->get("global_position");
		double dist = fire_pos.distance_squared_to(hit_position);
		if (dist < closest_fire_dist) {
			closest_fire_dist = dist;
			closest_fire = f;
		}
	}

	if (closest_fire != nullptr) {
		closest_fire->call("_apply_build_up", fire_buildup, projectile->get_owner());
	}
}

void _ProjectileManager::print_armor_debug(const Dictionary &armor_result, Object *ship) {
	// Implementation for debug printing
	if (ship == nullptr) {
		return;
	}

	String ship_class = "Unknown";
	Variant health_controller_var = ship->get("health_controller");
	if (health_controller_var.get_type() != Variant::NIL) {
		Object *health_controller = Object::cast_to<Object>(health_controller_var);
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
	}

	int result_type = armor_result.get("result_type", 0);
	String result_name;
	switch (result_type) {
		case PENETRATION: result_name = "PENETRATION"; break;
		case RICOCHET: result_name = "RICOCHET"; break;
		case OVERPENETRATION: result_name = "OVERPENETRATION"; break;
		case SHATTER: result_name = "SHATTER"; break;
		case NOHIT: result_name = "NOHIT"; break;
		case CITADEL: result_name = "CITADEL"; break;
		case WATER: result_name = "WATER"; break;
		default: result_name = "UNKNOWN"; break;
	}

	UtilityFunctions::print(String("Armor Debug: %s vs %s").replace("%s", result_name).replace("%s", ship_class));
}

void _ProjectileManager::validate_penetration_formula() {
	UtilityFunctions::print("=== Penetration Formula Validation ===");

	// Create test shell params using Resource
	// Note: In real usage, these would be ShellParams resources

	// Test 380mm BB shell
	double bb_caliber = 380.0;
	double bb_mass = 800.0;
	double bb_velocity = 820.0;

	double bb_penetration = 0.55664 * std::pow(bb_mass, 0.55) *
							std::pow(bb_velocity, 1.1) / std::pow(bb_caliber, 0.65);

	UtilityFunctions::print(String("380mm AP shell at 820 m/s: ") + String::num(bb_penetration) + "mm penetration");
	UtilityFunctions::print("Expected: ~700-800mm for battleship shells");

	// Test 203mm CA shell
	double ca_caliber = 203.0;
	double ca_mass = 118.0;
	double ca_velocity = 760.0;

	double ca_penetration = 0.55664 * std::pow(ca_mass, 0.55) *
							std::pow(ca_velocity, 1.1) / std::pow(ca_caliber, 0.65);

	UtilityFunctions::print(String("203mm AP shell at 760 m/s: ") + String::num(ca_penetration) + "mm penetration");
	UtilityFunctions::print("Expected: ~200-300mm for cruiser shells");

	UtilityFunctions::print("=== End of Penetration Formula Validation ===");
}

void _ProjectileManager::create_ricochet_rpc(int original_shell_id, int new_shell_id,
											const Vector3 &ricochet_position,
											const Vector3 &ricochet_velocity, double ricochet_time) {
	if (original_shell_id >= projectiles.size()) {
		UtilityFunctions::print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet");
		return;
	}

	Variant p_var = projectiles[original_shell_id];
	if (p_var.get_type() == Variant::NIL) {
		UtilityFunctions::print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet");
		return;
	}

	Ref<ProjectileData> p = p_var;
	if (!p.is_valid()) {
		UtilityFunctions::print("Warning: Could not find original shell with ID ", original_shell_id, " for ricochet");
		return;
	}

	fire_bullet_client(ricochet_position, ricochet_velocity, ricochet_time, new_shell_id,
					   p->get_params(), nullptr, false);
}

void _ProjectileManager::create_ricochet_rpc2(const PackedByteArray &data) {
	if (data.size() < 32) {
		UtilityFunctions::print("Warning: Invalid ricochet data size");
		return;
	}

	Ref<StreamPeerBuffer> stream;
	stream.instantiate();
	stream->set_data_array(data);

	int original_shell_id = stream->get_32();
	int new_shell_id = stream->get_32();
	Vector3 ricochet_position(stream->get_float(), stream->get_float(), stream->get_float());
	Vector3 ricochet_velocity(stream->get_float(), stream->get_float(), stream->get_float());
	double ricochet_time = stream->get_double();

	create_ricochet_rpc(original_shell_id, new_shell_id, ricochet_position, ricochet_velocity, ricochet_time);
}

// Getters
double _ProjectileManager::get_shell_time_multiplier() const {
	return shell_time_multiplier;
}

int _ProjectileManager::get_next_id() const {
	return next_id;
}

TypedArray<ProjectileData> _ProjectileManager::get_projectiles() const {
	return projectiles;
}

Array _ProjectileManager::get_ids_reuse() const {
	return ids_reuse;
}

Dictionary _ProjectileManager::get_shell_param_ids() const {
	return shell_param_ids;
}

int _ProjectileManager::get_bullet_id() const {
	return bullet_id;
}

Node *_ProjectileManager::get_gpu_renderer() const {
	return gpu_renderer;
}

Node *_ProjectileManager::get_compute_particle_system() const {
	return compute_particle_system;
}

int _ProjectileManager::get_trail_template_id() const {
	return trail_template_id;
}

Camera3D *_ProjectileManager::get_camera() const {
	return camera;
}

// Setters
void _ProjectileManager::set_shell_time_multiplier(double value) {
	shell_time_multiplier = value;
}

void _ProjectileManager::set_next_id(int value) {
	next_id = value;
}

void _ProjectileManager::set_projectiles(const TypedArray<ProjectileData> &value) {
	projectiles = value;
}

void _ProjectileManager::set_ids_reuse(const Array &value) {
	ids_reuse = value;
}

void _ProjectileManager::set_shell_param_ids(const Dictionary &value) {
	shell_param_ids = value;
}

void _ProjectileManager::set_bullet_id(int value) {
	bullet_id = value;
}

void _ProjectileManager::set_gpu_renderer(Node *value) {
	gpu_renderer = value;
}

void _ProjectileManager::set_compute_particle_system(Node *value) {
	compute_particle_system = value;
}

void _ProjectileManager::set_trail_template_id(int value) {
	trail_template_id = value;
}

void _ProjectileManager::set_camera(Camera3D *value) {
	camera = value;
}
