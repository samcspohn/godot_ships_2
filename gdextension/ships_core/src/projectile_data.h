#ifndef PROJECTILE_DATA_H
#define PROJECTILE_DATA_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/array.hpp>

namespace godot {

class ProjectileData : public RefCounted {
	GDCLASS(ProjectileData, RefCounted)

private:
	Vector3 position;
	Vector3 start_position;
	double start_time;
	Vector3 launch_velocity;
	Ref<Resource> params; // ShellParams resource
	Vector3 trail_pos;
	Object *owner; // Ship reference
	int frame_count;
	Array exclude; // Array of Ships to exclude from collision
	int emitter_id;

protected:
	static void _bind_methods();

public:
	ProjectileData();
	~ProjectileData();

	void initialize(const Vector3 &pos, const Vector3 &vel, double t, 
					const Ref<Resource> &p, Object *_owner, const Array &_exclude = Array());

	// Getters
	Vector3 get_position() const;
	Vector3 get_start_position() const;
	double get_start_time() const;
	Vector3 get_launch_velocity() const;
	Ref<Resource> get_params() const;
	Vector3 get_trail_pos() const;
	Object *get_owner() const;
	int get_frame_count() const;
	Array get_exclude() const;
	int get_emitter_id() const;

	// Setters
	void set_position(const Vector3 &p_position);
	void set_start_position(const Vector3 &p_start_position);
	void set_start_time(double p_start_time);
	void set_launch_velocity(const Vector3 &p_launch_velocity);
	void set_params(const Ref<Resource> &p_params);
	void set_trail_pos(const Vector3 &p_trail_pos);
	void set_owner(Object *p_owner);
	void set_frame_count(int p_frame_count);
	void set_exclude(const Array &p_exclude);
	void set_emitter_id(int p_emitter_id);

	// Increment frame count
	void increment_frame_count();
};

} // namespace godot

#endif // PROJECTILE_DATA_H