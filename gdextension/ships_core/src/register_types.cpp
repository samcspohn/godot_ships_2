#include "register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

// From projectile_physics
#include "projectile_physics.h"
#include "projectile_physics_with_drag.h"
#include "projectile_physics_with_drag_v2.h"

// From game_systems
#include "projectile_data.h"
#include "shell_data.h"
#include "emitter_data.h"
#include "emission_request.h"
#include "emitter_init_request.h"
#include "projectile_manager.h"
#include "compute_particle_system.h"

using namespace godot;

void initialize_ships_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Register projectile physics classes
	GDREGISTER_CLASS(ProjectilePhysics);
	GDREGISTER_CLASS(ProjectilePhysicsWithDrag);
	GDREGISTER_CLASS(ProjectilePhysicsWithDragV2);

	// Register data classes (they are dependencies)
	GDREGISTER_CLASS(ProjectileData);
	GDREGISTER_CLASS(ShellData);
	GDREGISTER_CLASS(EmitterData);
	GDREGISTER_CLASS(EmissionRequest);
	GDREGISTER_CLASS(EmitterInitRequest);

	// Register main system classes
	GDREGISTER_CLASS(_ProjectileManager);
	GDREGISTER_CLASS(ComputeParticleSystem);
}

void uninitialize_ships_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT ships_core_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_ships_core_module);
	init_obj.register_terminator(uninitialize_ships_core_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}