#ifndef SHELL_DATA_H
#define SHELL_DATA_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class ShellData : public RefCounted {
	GDCLASS(ShellData, RefCounted)

private:
	Ref<Resource> params; // ShellParams resource
	Vector3 velocity;
	Vector3 position;
	Vector3 end_position;
	double fuse;
	int hit_result;

protected:
	static void _bind_methods();

public:
	ShellData();
	~ShellData();

	// Getters
	Ref<Resource> get_params() const;
	Vector3 get_velocity() const;
	Vector3 get_position() const;
	Vector3 get_end_position() const;
	double get_fuse() const;
	int get_hit_result() const;

	// Setters
	void set_params(const Ref<Resource> &p_params);
	void set_velocity(const Vector3 &p_velocity);
	void set_position(const Vector3 &p_position);
	void set_end_position(const Vector3 &p_end_position);
	void set_fuse(double p_fuse);
	void set_hit_result(int p_hit_result);
};

} // namespace godot

#endif // SHELL_DATA_H