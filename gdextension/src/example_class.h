#ifndef EXAMPLE_CLASS_H
#define EXAMPLE_CLASS_H

#include <godot_cpp/classes/node3d.hpp>

namespace godot {

class ExampleClass : public Node3D {
    GDCLASS(ExampleClass, Node3D)

private:
    float speed = 10.0f;
    float health = 100.0f;

protected:
    static void _bind_methods();

public:
    ExampleClass();
    ~ExampleClass();

    void _ready() override;
    void _process(double delta) override;

    // Property getters/setters
    void set_speed(float p_speed);
    float get_speed() const;

    void set_health(float p_health);
    float get_health() const;

    // Custom methods
    void take_damage(float amount);
};

} // namespace godot

#endif // EXAMPLE_CLASS_H
