#ifndef PROJECTILE_PHYSICS_REGISTER_TYPES_H
#define PROJECTILE_PHYSICS_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_projectile_physics_module(ModuleInitializationLevel p_level);
void uninitialize_projectile_physics_module(ModuleInitializationLevel p_level);

#endif // PROJECTILE_PHYSICS_REGISTER_TYPES_H