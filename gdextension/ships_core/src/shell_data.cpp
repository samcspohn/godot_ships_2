#include "shell_data.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void ShellData::_bind_methods() {
	// Bind getters
	ClassDB::bind_method(D_METHOD("get_params"), &ShellData::get_params);
	ClassDB::bind_method(D_METHOD("get_velocity"), &ShellData::get_velocity);
	ClassDB::bind_method(D_METHOD("get_position"), &ShellData::get_position);
	ClassDB::bind_method(D_METHOD("get_end_position"), &ShellData::get_end_position);
	ClassDB::bind_method(D_METHOD("get_fuse"), &ShellData::get_fuse);
	ClassDB::bind_method(D_METHOD("get_hit_result"), &ShellData::get_hit_result);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_params", "params"), &ShellData::set_params);
	ClassDB::bind_method(D_METHOD("set_velocity", "velocity"), &ShellData::set_velocity);
	ClassDB::bind_method(D_METHOD("set_position", "position"), &ShellData::set_position);
	ClassDB::bind_method(D_METHOD("set_end_position", "end_position"), &ShellData::set_end_position);
	ClassDB::bind_method(D_METHOD("set_fuse", "fuse"), &ShellData::set_fuse);
	ClassDB::bind_method(D_METHOD("set_hit_result", "hit_result"), &ShellData::set_hit_result);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "params", PROPERTY_HINT_RESOURCE_TYPE, "Resource"), "set_params", "get_params");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "velocity"), "set_velocity", "get_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "end_position"), "set_end_position", "get_end_position");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fuse"), "set_fuse", "get_fuse");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "hit_result"), "set_hit_result", "get_hit_result");
}

ShellData::ShellData() {
	velocity = Vector3();
	position = Vector3();
	end_position = Vector3();
	fuse = 0.0;
	hit_result = 0;
}

ShellData::~ShellData() {
}

// Getters
Ref<Resource> ShellData::get_params() const {
	return params;
}

Vector3 ShellData::get_velocity() const {
	return velocity;
}

Vector3 ShellData::get_position() const {
	return position;
}

Vector3 ShellData::get_end_position() const {
	return end_position;
}

double ShellData::get_fuse() const {
	return fuse;
}

int ShellData::get_hit_result() const {
	return hit_result;
}

// Setters
void ShellData::set_params(const Ref<Resource> &p_params) {
	params = p_params;
}

void ShellData::set_velocity(const Vector3 &p_velocity) {
	velocity = p_velocity;
}

void ShellData::set_position(const Vector3 &p_position) {
	position = p_position;
}

void ShellData::set_end_position(const Vector3 &p_end_position) {
	end_position = p_end_position;
}

void ShellData::set_fuse(double p_fuse) {
	fuse = p_fuse;
}

void ShellData::set_hit_result(int p_hit_result) {
	hit_result = p_hit_result;
}