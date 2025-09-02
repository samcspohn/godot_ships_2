# Bot AI Navigation & Collision Avoidance System

This document describes the AI navigation system implemented for bot ships, including strategic movement patterns and collision avoidance to prevent them from running into islands and terrain.

## Overview

The bot AI system combines two main components:

1. **Strategic Navigation**: Bots move towards the opposite side of the map, then patrol within a 10km circle around the center
2. **Collision Avoidance**: Uses physics raycasting to detect obstacles and adjusts navigation to avoid collisions

## Strategic Navigation System

### Two-Phase Movement Pattern

**Phase 1: Approach Opposite Side**
- Bots determine which spawn point they're closer to
- Move towards the opposite side of the map (North ↔ South)
- Add randomization to avoid clustering: ±2000m in X, ±1000m in Z
- **Land Avoidance**: Uses terrain detection to ensure targets are positioned over water
- Transition to patrol phase when within 2000m of target

**Phase 2: Central Patrol**
- Patrol within a 8,000m radius circle around map center (0,0,0)
- **Persistent Patrol Points**: Select one patrol target and navigate to it
- **Target Switching**: Generate new patrol point only when within 500m of current target
- Generate random patrol targets within 30-90% of patrol radius
- **Land Avoidance**: All patrol points verified to be over water using raycast detection
- Return towards center if moving outside patrol zone
- Maintains strategic positioning during combat

### Map Layout
- **Team 0 Spawn (North)**: (0, 0, -5352)
- **Team 1 Spawn (South)**: (0, 0, 7234)
- **Map Center**: (0, 0, 0)
- **Patrol Zone**: 8km radius circle around center
- **Patrol Point Persistence**: 500m reach distance before selecting new target
- **Land Detection**: Terrain raycast system ensures all targets are positioned over water

## Collision Avoidance System

### Key Features

#### Realistic Ship Control
- Uses ship's actual orientation (basis -Z vector) for current heading
- Continuously adjusts rudder input until ship heading matches desired heading
- Proportional rudder control for smooth, realistic turning behavior

#### Multi-Ray Detection
- Casts 10 rays in a **360-degree full circle** around the ship
- Detects both **terrain/islands** and **moving ships** on all collision layers
- Analyzes all potential obstacles regardless of ship's intended direction
- **Moving Object Prediction**: Tracks velocity of RigidBody objects to predict future positions

#### Advanced Obstacle Handling
- **Static Objects**: Terrain, islands, and stationary obstacles
- **Moving Objects**: Ships, projectiles, and other dynamic RigidBody objects
- **Velocity Prediction**: Uses RigidBody.linear_velocity for collision prediction
- **Team Filtering**: Ignores friendly ships to prevent unnecessary avoidance of allies

#### Progressive Response
- **2000m range**: Starts gentle course corrections when obstacles are detected
- **500m range**: Emergency measures activate (reduced speed, sharp turns, or reverse)
- **250m range**: Full reverse to avoid collision

#### Intelligent Steering
- Calculates avoidance forces perpendicular to obstacle direction
- Chooses the avoidance direction that's most compatible with current heading
- Combines avoidance with strategic navigation goals
- Real-time rudder adjustment based on heading error

### Debug Visualization
- **Cyan spheres**: Phase 1 targets (moving to opposite side)
- **Magenta spheres**: Current patrol target (persistent until reached)
- **White spheres**: New patrol target selection markers
- **Green sphere**: Transition marker when reaching opposite side
- **Yellow spheres**: Static collision points (terrain, islands)
- **Orange spheres**: Moving collision points (ships, dynamic objects)
- **Red spheres**: Predicted future positions of moving objects
- **Blue spheres**: Final heading after avoidance applied

## Configuration Parameters

```gdscript
# Strategic Navigation
var map_center: Vector3 = Vector3(0, 0, 0)          # Center of the map
var patrol_radius: float = 8000.0                   # 8km patrol circle
var initial_approach_distance: float = 2000.0       # Distance to opposite side target

# Collision Avoidance  
var collision_avoidance_distance: float = 2000.0    # Detection range
var collision_check_rays: int = 10                  # Number of detection rays
var collision_ray_spread: float = TAU               # Ray spread angle (360 degrees - full circle)
var emergency_stop_distance: float = 500.0          # Emergency action distance
var avoidance_turn_strength: float = 2.0            # How aggressive turns are
var debug_draw: bool = true                         # Enable debug visualization
```

## Integration

The navigation system integrates seamlessly with combat behavior:

1. **Strategic Movement**: Bots follow the two-phase approach regardless of combat status
2. **Enhanced Target Selection**: Prioritizes visible enemies, navigates towards obscured ones
3. **Adaptive Combat Behavior**: Tactical maneuvering for visible targets, direct approach for obscured targets
4. **Patrol Behavior**: Uses strategic navigation when no enemies are present
5. **Collision Avoidance**: Applied to all movement decisions

## Enhanced Combat System

### Target Selection Priority
1. **Visible Enemies First**: Prioritizes `visible_to_enemy = true` ships
2. **Closest Visible Target**: Selects nearest visible enemy within attack range
3. **Fallback to Any Enemy**: If no visible enemies, targets closest enemy ship
4. **Navigation to Obscured**: Will navigate towards enemies even if line-of-sight is blocked

### Combat Behavior Modes
**Visible Target Mode** (when enemy is `visible_to_enemy` and clear line-of-sight):
- Tactical maneuvering around preferred distance (6km)
- Circling behavior when in optimal range
- Active firing when in range and facing target

**Navigation Mode** (when target is obscured or not visible):
- Direct approach towards target position
- No firing until target becomes visible
- Continuous navigation to establish line-of-sight

## Technical Implementation

### Strategic Navigation
```gdscript
# Phase 1: Move to opposite side
if not opposite_side_reached:
    target_position = get_opposite_side_target()
    opposite_side_reached = has_reached_opposite_side()

# Phase 2: Patrol around center  
else:
    target_position = get_patrol_target()
    if not is_in_patrol_zone():
        target_position = move_towards_center()
```

### Ship Control System
- **Heading Calculation**: Uses `ship.global_transform.basis.z` for actual ship orientation
- **Rudder Control**: Proportional control based on heading error: `rudder = clamp(angle_diff * scale, -1.0, 1.0)`
- **Emergency Response**: Increases rudder response during collision avoidance

### Collision Detection
- Uses collision layer 1 (terrain/islands) for detection
- Ignores ships and projectiles to focus on static obstacles
- Rays cast from ship position + 5m height to avoid water surface interference

## Usage

The navigation system activates automatically when bot ships are spawned. Bots will:

1. **Advance to Combat Zone**: Move towards the opposite side of the map
2. **Establish Central Control**: Patrol within 10km of map center
3. **Engage Enemies**: Fight while maintaining strategic positioning
4. **Avoid Obstacles**: Navigate around islands and terrain automatically

## Testing

To observe the strategic navigation system:

1. Start a single-player game (spawns AI bots)
2. Watch bots move towards opposite side of map (cyan target markers)
3. Observe transition to patrol behavior (magenta target markers)
4. Green markers indicate successful transition between phases
5. Bots should maintain 10km patrol zone while engaging enemies

The system creates more realistic naval combat with:
- ⚓ **Strategic positioning** rather than random movement
- 🎯 **Territorial control** around map center
- 🛡️ **Intelligent obstacle avoidance**
- ⚔️ **Combined tactical and strategic behavior**
