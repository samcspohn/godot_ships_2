#include "example_class.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void ExampleClass::_bind_methods() {
    // Bind methods
    ClassDB::bind_method(D_METHOD("get_speed"), &ExampleClass::get_speed);
    ClassDB::bind_method(D_METHOD("set_speed", "p_speed"), &ExampleClass::set_speed);
    ClassDB::bind_method(D_METHOD("get_health"), &ExampleClass::get_health);
    ClassDB::bind_method(D_METHOD("set_health", "p_health"), &ExampleClass::set_health);
    ClassDB::bind_method(D_METHOD("take_damage", "amount"), &ExampleClass::take_damage);

    // Register properties (these show up in the Godot editor)
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "speed"), "set_speed", "get_speed");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "health"), "set_health", "get_health");

    // Register signals
    ADD_SIGNAL(MethodInfo("health_changed", PropertyInfo(Variant::FLOAT, "new_health")));
    ADD_SIGNAL(MethodInfo("died"));
}

ExampleClass::ExampleClass() {
    // Constructor
}

ExampleClass::~ExampleClass() {
    // Destructor
}

void ExampleClass::_ready() {
    UtilityFunctions::print("ExampleClass ready!");
}

void ExampleClass::_process(double delta) {
    // Called every frame
    // Example: rotate the node
    // rotate_y(delta * speed * 0.1);
}

void ExampleClass::set_speed(float p_speed) {
    speed = p_speed;
}

float ExampleClass::get_speed() const {
    return speed;
}

void ExampleClass::set_health(float p_health) {
    health = p_health;
    emit_signal("health_changed", health);
}

float ExampleClass::get_health() const {
    return health;
}

void ExampleClass::take_damage(float amount) {
    health -= amount;
    emit_signal("health_changed", health);
    
    if (health <= 0) {
        emit_signal("died");
        UtilityFunctions::print("ExampleClass died!");
    }
}
