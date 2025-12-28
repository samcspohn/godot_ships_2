# Projectile Physics GDExtension

This is a C++ GDExtension port of the projectile physics system for improved performance.

## Classes

- **ProjectilePhysics** - Simple projectile physics without drag (drop-in replacement for `GDProjectilePhysics`)
- **ProjectilePhysicsWithDrag** - Analytical projectile physics with drag effects (drop-in replacement for `GDProjectilePhysicsWithDrag`)

## Building

### Prerequisites

1. **SCons** - Build system (install via `pip install scons`)
2. **C++ Compiler** - GCC, Clang, or MSVC depending on your platform
3. **godot-cpp** - Already included as a submodule at `../godot-cpp`

### Build Commands

Navigate to this directory and run:

```bash
# Debug build (for development)
scons platform=linux target=template_debug

# Release build (for distribution)
scons platform=linux target=template_release

# For Windows
scons platform=windows target=template_debug

# For macOS
scons platform=macos target=template_debug
```

### Build Options

- `platform` - Target platform: `linux`, `windows`, `macos`, `android`, `ios`, `web`
- `target` - Build type: `template_debug`, `template_release`
- `arch` - Architecture: `x86_64`, `x86_32`, `arm64`, `arm32`

### Output

Compiled libraries are placed in `../../bin/` directory:
- Linux: `libprojectile_physics.linux.template_debug.x86_64.so`
- Windows: `libprojectile_physics.windows.template_debug.x86_64.dll`
- macOS: `libprojectile_physics.macos.template_debug.framework`

## Usage

Once built, the C++ classes are automatically available in GDScript:

```gdscript
# These calls now use the C++ implementation
var result = ProjectilePhysics.calculate_launch_vector(start, target, speed)
var drag_result = ProjectilePhysicsWithDrag.calculate_launch_vector(start, target, speed, drag)
```

## GDScript Fallback

The original GDScript implementations have been renamed to:
- `GDProjectilePhysics`
- `GDProjectilePhysicsWithDrag`

If the C++ extension fails to load, you can update your code to use these fallback classes.

## API Reference

### ProjectilePhysics

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `get_gravity()` | - | `float` | Returns gravity constant (-9.8) |
| `calculate_launch_vector()` | `start_pos: Vector3, target_pos: Vector3, projectile_speed: float` | `Array[Vector3, float]` | Calculates launch vector and time to hit stationary target |
| `calculate_position_at_time()` | `start_pos: Vector3, launch_vector: Vector3, time: float` | `Vector3` | Position at given time |
| `calculate_leading_launch_vector()` | `start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3, projectile_speed: float` | `Array[Vector3, float]` | Launch vector for moving target |
| `calculate_max_range_from_angle()` | `angle: float, projectile_speed: float` | `float` | Maximum range at angle |
| `calculate_angle_from_max_range()` | `max_range: float, projectile_speed: float` | `float` | Angle for desired range |

### ProjectilePhysicsWithDrag

All methods from `ProjectilePhysics` plus:

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `get_default_drag_coefficient()` | - | `float` | Default drag (0.002) |
| `get_shell_380mm_drag_coefficient()` | - | `float` | 380mm shell drag (0.009) |
| `get_ping_pong_drag_coefficient()` | - | `float` | Ping pong ball drag (0.233) |
| `get_bowling_ball_drag_coefficient()` | - | `float` | Bowling ball drag (0.00267) |
| `calculate_absolute_max_range()` | `projectile_speed: float, drag_coefficient: float` | `Array[float, float, float]` | Max range, angle, and flight time |
| `calculate_velocity_at_time()` | `launch_vector: Vector3, time: float, drag_coefficient: float` | `Vector3` | Velocity with drag effects |
| `calculate_precise_shell_position()` | `start_pos: Vector3, target_pos: Vector3, launch_vector: Vector3, current_time: float, total_flight_time: float, drag_coefficient: float` | `Vector3` | Position with endpoint precision |
| `calculate_impact_position()` | `start_pos: Vector3, launch_velocity: Vector3, drag_coefficient: float` | `Vector3` | Impact position (y=0) |
| `estimate_time_of_flight()` | `start_pos: Vector3, launch_vector: Vector3, horiz_dist: float, drag_coefficient: float` | `float` | Estimated flight time |
| `calculate_leading_launch_vector()` | `start_pos: Vector3, target_pos: Vector3, target_velocity: Vector3, projectile_speed: float, drag_coefficient: float` | `Array[Vector3, float, Vector3]` | Launch vector, time, and final target position |