# Ship Movement V2 Documentation

## Overview

`ShipMovementV2` is a complete rewrite of the ship movement system designed to address the following issues from the original:

1. **Direct Speed Control**: The `max_speed` variable now directly corresponds to meters per second in-game
2. **Simplified Physics**: Minimal physics interference except for collisions
3. **Consistent Turning**: Predictable turning behavior based on `turn_rate` (degrees per second)
4. **Collision Handling**: Physics automatically takes over during collisions for realistic responses

## Key Features

### Direct Movement Control
- Uses direct velocity manipulation instead of force-based movement
- Speed values directly correspond to m/s (no confusing mass calculations)
- Predictable acceleration and deceleration timing

### Simplified Turning
- Turning circle radius specified directly in meters
- Ship will turn in the specified radius when at full rudder and full speed
- Turning effectiveness scales with current speed
- Realistic reverse turning (steering is inverted when moving backward)

### Collision Response
- Automatically detects collisions and lets physics take over briefly
- Ships will stop when hitting islands
- Ships will push each other realistically
- Returns to controlled movement after collision

### High Configurability
- All movement parameters are exposed as @export variables
- Easy to tune for different ship types
- Debug functions provide real-time movement data

## Configuration Parameters

### Speed Settings
- `max_speed`: Maximum forward speed in m/s (default: 15.0)
- `acceleration_time`: Time to reach full speed from stop (default: 8.0s)
- `deceleration_time`: Time to stop from full speed (default: 4.0s)
- `reverse_speed_ratio`: Reverse speed as ratio of max speed (default: 0.4)

### Turning Settings
- `turning_circle_radius`: Turning circle radius in meters at full rudder and full speed (default: 200.0)
- `min_turn_speed`: Minimum speed needed for effective turning (default: 2.0 m/s)
- `rudder_response_time`: Time for rudder to move from center to full (default: 1.5s)

### Collision Settings
- `collision_override_duration`: How long physics controls movement after collision (default: 0.1s)

## Usage

### Basic Setup
1. Attach `ShipMovementV2` as a child of a RigidBody3D
2. Set the desired configuration parameters
3. Call `set_movement_input([throttle_level, rudder_input])` each frame

### Input Format
- `throttle_level`: Integer from -1 to 4
  - -1: Reverse
  - 0: Stop
  - 1-4: Forward speeds (25%, 50%, 75%, 100%)
- `rudder_input`: Float from -1.0 to 1.0
  - -1.0: Full left rudder
  - 0.0: Center rudder
  - 1.0: Full right rudder

### Example Usage
```gdscript
# In your ship control script
@onready var movement = $ShipMovementV2

func _process(delta):
    var throttle = get_throttle_input()  # Your input handling
    var rudder = get_rudder_input()     # Your input handling
    
    movement.set_movement_input([throttle, rudder])
```

## Debug Functions

### Speed Information
- `get_current_speed_kmh()`: Current speed in km/h
- `get_current_speed_knots()`: Current speed in nautical knots
- `get_throttle_percentage()`: Current throttle as percentage

### Debug Data
- `get_movement_debug_info()`: Returns dictionary with all movement data including actual turning radius
- `get_actual_turning_radius()`: Returns current turning radius in meters
- `emergency_stop()`: Immediately stops the ship

## Physics Integration

### RigidBody3D Settings
The script automatically configures the RigidBody3D with:
- High linear damping (8.0) to prevent unwanted sliding
- High angular damping (10.0) to prevent unwanted rotation
- Collision detection for automatic physics override

### Collision Behavior
- When collision is detected, physics takes control for realistic response
- Ship will bounce off or stop against solid objects
- Ships will push each other when colliding
- Movement control resumes after brief physics override

## Comparison with Original System

| Aspect | Original | V2 |
|--------|----------|-----|
| Speed Control | Force-based, unpredictable | Direct velocity, predictable |
| Physics Role | Heavy involvement | Minimal, collision-only |
| Turning | Complex pivot system | Simple angular velocity |
| Speed Units | Unclear relationship | Direct m/s correlation |
| Collision | Manual force handling | Automatic physics override |
| Configurability | Limited | Highly configurable |

## Migration from Original

1. Replace `ShipMovement` with `ShipMovementV2` in your scene
2. Adjust `max_speed` to desired m/s value (original `speed` was roughly equivalent)
2. Set `turning_circle_radius` to desired turning radius in meters (200m is a good starting point for large ships)
4. Test and tune other parameters as needed

The input format remains the same, so existing control code should work without modification.
