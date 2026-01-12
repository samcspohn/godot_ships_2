#include "projectile_data.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void ProjectileData::_bind_methods() {
	// Bind the initialize method
	ClassDB::bind_method(D_METHOD("initialize", "pos", "vel", "t", "p", "_owner", "_exclude"), 
						 &ProjectileData::initialize, DEFVAL(Array()));

	// Bind getters
	ClassDB::bind_method(D_METHOD("get_position"), &ProjectileData::get_position);
	ClassDB::bind_method(D_METHOD("get_start_position"), &ProjectileData::get_start_position);
	ClassDB::bind_method(D_METHOD("get_start_time"), &ProjectileData::get_start_time);
	ClassDB::bind_method(D_METHOD("get_launch_velocity"), &ProjectileData::get_launch_velocity);
	ClassDB::bind_method(D_METHOD("get_params"), &ProjectileData::get_params);
	ClassDB::bind_method(D_METHOD("get_trail_pos"), &ProjectileData::get_trail_pos);
	ClassDB::bind_method(D_METHOD("get_owner"), &ProjectileData::get_owner);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &ProjectileData::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_exclude"), &ProjectileData::get_exclude);
	ClassDB::bind_method(D_METHOD("get_emitter_id"), &ProjectileData::get_emitter_id);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_position", "position"), &ProjectileData::set_position);
	ClassDB::bind_method(D_METHOD("set_start_position", "start_position"), &ProjectileData::set_start_position);
	ClassDB::bind_method(D_METHOD("set_start_time", "start_time"), &ProjectileData::set_start_time);
	ClassDB::bind_method(D_METHOD("set_launch_velocity", "launch_velocity"), &ProjectileData::set_launch_velocity);
	ClassDB::bind_method(D_METHOD("set_params", "params"), &ProjectileData::set_params);
	ClassDB::bind_method(D_METHOD("set_trail_pos", "trail_pos"), &ProjectileData::set_trail_pos);
	ClassDB::bind_method(D_METHOD("set_owner", "owner"), &ProjectileData::set_owner);
	ClassDB::bind_method(D_METHOD("set_frame_count", "frame_count"), &ProjectileData::set_frame_count);
	ClassDB::bind_method(D_METHOD("set_exclude", "exclude"), &ProjectileData::set_exclude);
	ClassDB::bind_method(D_METHOD("set_emitter_id", "emitter_id"), &ProjectileData::set_emitter_id);

	// Bind utility methods
	ClassDB::bind_method(D_METHOD("increment_frame_count"), &ProjectileData::increment_frame_count);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_position"), "set_start_position", "get_start_position");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "start_time"), "set_start_time", "get_start_time");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "launch_velocity"), "set_launch_velocity", "get_launch_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "params", PROPERTY_HINT_RESOURCE_TYPE, "Resource"), "set_params", "get_params");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "trail_pos"), "set_trail_pos", "get_trail_pos");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "owner"), "set_owner", "get_owner");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_count"), "set_frame_count", "get_frame_count");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "exclude"), "set_exclude", "get_exclude");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "emitter_id"), "set_emitter_id", "get_emitter_id");
}

ProjectileData::ProjectileData() {
	position = Vector3();
	start_position = Vector3();
	start_time = 0.0;
	launch_velocity = Vector3();
	trail_pos = Vector3();
	owner = nullptr;
	frame_count = 0;
	emitter_id = -1;
}

ProjectileData::~ProjectileData() {
	// Owner is not owned by this class, so we don't delete it
}

void ProjectileData::initialize(const Vector3 &pos, const Vector3 &vel, double t, 
								const Ref<Resource> &p, Object *_owner, const Array &_exclude) {
	position = pos;
	start_position = pos;
	trail_pos = pos + vel.normalized() * 25.0;
	params = p;
	start_time = t;
	launch_velocity = vel;
	owner = _owner;
	frame_count = 0;
	exclude = _exclude;
	emitter_id = -1;
}

// Getters
Vector3 ProjectileData::get_position() const {
	return position;
}

Vector3 ProjectileData::get_start_position() const {
	return start_position;
}

double ProjectileData::get_start_time() const {
	return start_time;
}

Vector3 ProjectileData::get_launch_velocity() const {
	return launch_velocity;
}

Ref<Resource> ProjectileData::get_params() const {
	return params;
}

Vector3 ProjectileData::get_trail_pos() const {
	return trail_pos;
}

Object *ProjectileData::get_owner() const {
	return owner;
}

int ProjectileData::get_frame_count() const {
	return frame_count;
}

Array ProjectileData::get_exclude() const {
	return exclude;
}

int ProjectileData::get_emitter_id() const {
	return emitter_id;
}

// Setters
void ProjectileData::set_position(const Vector3 &p_position) {
	position = p_position;
}

void ProjectileData::set_start_position(const Vector3 &p_start_position) {
	start_position = p_start_position;
}

void ProjectileData::set_start_time(double p_start_time) {
	start_time = p_start_time;
}

void ProjectileData::set_launch_velocity(const Vector3 &p_launch_velocity) {
	launch_velocity = p_launch_velocity;
}

void ProjectileData::set_params(const Ref<Resource> &p_params) {
	params = p_params;
}

void ProjectileData::set_trail_pos(const Vector3 &p_trail_pos) {
	trail_pos = p_trail_pos;
}

void ProjectileData::set_owner(Object *p_owner) {
	owner = p_owner;
}

void ProjectileData::set_frame_count(int p_frame_count) {
	frame_count = p_frame_count;
}

void ProjectileData::set_exclude(const Array &p_exclude) {
	exclude = p_exclude;
}

void ProjectileData::set_emitter_id(int p_emitter_id) {
	emitter_id = p_emitter_id;
}

void ProjectileData::increment_frame_count() {
	frame_count++;
}