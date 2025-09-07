# Floating Damage System

A visual feedback system that displays damage numbers floating above hit points in the game.

## Features

- Displays damage amounts as floating text above hit locations
- Automatically fades out after 0.7 seconds
- Smoothly animates upward and fades out
- Easy to integrate into existing damage systems
- Automatically positions relative to camera view
- Clean scene-based architecture with preloading

## Files

- `scenes/floating_damage.gd` - Main floating damage script
- `scenes/floating_damage.tscn` - Floating damage scene file
- `floating_damage_usage_example.gd` - Integration examples

## Usage

### Quick Start

The simplest way to show floating damage is through the CameraUIScene:

```gdscript
# Get the camera UI (it's in the "camera_ui" group)
var camera_ui = get_tree().get_nodes_in_group("camera_ui")[0]
if camera_ui:
    camera_ui.create_floating_damage(150, Vector3(10, 5, 20))
```

### Manual Creation

For more control, you can preload and instantiate the scene directly:

```gdscript
# Preload the scene (do this once, preferably as a const)
const FloatingDamageScene = preload("res://scenes/floating_damage.tscn")

# Create floating damage
var floating_damage = FloatingDamageScene.instantiate()
floating_damage.damage_amount = 150
floating_damage.world_position = Vector3(10, 5, 20)
add_child(floating_damage)
```

### Integration with Existing Systems

The floating damage system integrates well with existing damage tracking. For example, in the projectile manager's `track_damage_event` function:

```gdscript
func track_damage_event(p: ProjectileData, damage: float, position: Vector3):
    if not p or not is_instance_valid(p):
        return

    if p.owner.stats:
        p.owner.stats.damage_events.append({"damage": damage, "position": position})
    
    # Show floating damage
    var camera_ui = get_tree().get_nodes_in_group("camera_ui")
    if camera_ui.size() > 0:
        camera_ui[0].create_floating_damage(int(damage), position)
```

## Architecture

The system now uses a clean scene-based approach:

1. **FloatingDamage Scene**: Contains a Label node with the floating damage script
2. **Preloading**: The CameraUIScene preloads the floating damage scene for efficient instantiation
3. **No Templates**: No more template nodes that could cause issues - each instance is a fresh scene instantiation

## Customization

The floating damage script has several configurable parameters:

- `lifetime`: How long the damage display lasts (default: 0.7 seconds)
- `float_distance`: How far upward the text floats (default: 50 pixels)
- `fade_start_time`: When to start fading out (default: 0.3 seconds)

These can be modified in the script or set via exports when creating custom instances.

## Benefits of Scene-Based Approach

- **No template conflicts**: Each instance is independent
- **Better performance**: Preloaded scenes instantiate faster
- **Cleaner architecture**: Separation of concerns between UI and floating damage
- **Easier maintenance**: Single scene file for all floating damage instances
- **No queue_free issues**: No risk of templates destroying themselves
