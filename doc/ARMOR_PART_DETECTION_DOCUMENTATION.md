# Armor Part Detection Function Documentation

## Overview

The `get_armor_part_at_point()` function in `ArmorInteraction.gd` allows you to determine which armor part contains a given 3D point. This is useful for various gameplay mechanics where you need to know what armor protection exists at a specific location.

## Function Signature

```gdscript
static func get_armor_part_at_point(point: Vector3, space_state: PhysicsDirectSpaceState3D) -> Dictionary
```

## Parameters

- **point**: `Vector3` - The 3D world position to check
- **space_state**: `PhysicsDirectSpaceState3D` - The physics space state for raycasting (get from `get_tree().root.get_world_3d().direct_space_state`)

## Return Value

Returns a `Dictionary` with the following structure:

### Success Case (point is inside armor):
```gdscript
{
    "armor_part": ArmorPart,           # The innermost armor part containing the point
    "armor_path": String,              # The armor system path (e.g., "Hull/380mmTurret")
    "position": Vector3,               # The original point that was tested
    "all_containing_parts": Array     # All armor parts that contain the point (for nested armor)
}
```

### Failure Case (point is not inside any armor):
```gdscript
{}  # Empty dictionary
```

## How It Works

### 1. Multi-directional Raycasting
The function casts rays in 8 different directions from the test point:
- Cardinal directions: RIGHT, LEFT, UP, DOWN, FORWARD, BACK
- Diagonal directions: (1,1,1) and (-1,-1,-1) normalized

### 2. Inside/Outside Detection
For each armor part hit by the rays, the function determines if the point is inside by:
- Analyzing surface normals at hit points
- Performing reverse raycasting for verification
- Using dot product calculations to determine containment

### 3. Nested Armor Handling
When multiple armor parts contain the same point (nested armor), the function:
- Identifies all containing armor parts
- Calculates the approximate volume of each armor part
- Returns the smallest (innermost) armor part as the primary result
- Provides all containing parts in the `all_containing_parts` array

## Usage Examples

### Basic Usage
```gdscript
func check_armor_at_explosion():
    var space_state = get_tree().root.get_world_3d().direct_space_state
    var explosion_pos = Vector3(10, 5, 0)
    
    var result = ArmorInteraction.get_armor_part_at_point(explosion_pos, space_state)
    
    if result.is_empty():
        print("Explosion hit unarmored area")
    else:
        print("Explosion hit armor: ", result["armor_path"])
        var armor_part = result["armor_part"]
        # Access armor thickness, apply damage modifications, etc.
```

### Handling Nested Armor
```gdscript
func analyze_nested_armor():
    var space_state = get_tree().root.get_world_3d().direct_space_state
    var test_point = Vector3(0, 10, 0)
    
    var result = ArmorInteraction.get_armor_part_at_point(test_point, space_state)
    
    if not result.is_empty():
        print("Primary armor: ", result["armor_path"])
        
        var all_parts = result["all_containing_parts"]
        if all_parts.size() > 1:
            print("This point is protected by ", all_parts.size(), " armor layers:")
            for armor_info in all_parts:
                print("  - ", armor_info["armor_part"].armor_path)
```

### Area-of-Effect Damage
```gdscript
func calculate_aoe_damage(center: Vector3, radius: float):
    var space_state = get_tree().root.get_world_3d().direct_space_state
    var damage_map = {}
    
    # Test multiple points within the explosion radius
    for angle in range(0, 360, 45):  # Every 45 degrees
        for r in range(1, int(radius), 2):  # Every 2 units of radius
            var offset = Vector3(cos(deg_to_rad(angle)), 0, sin(deg_to_rad(angle))) * r
            var test_point = center + offset
            
            var armor_result = ArmorInteraction.get_armor_part_at_point(test_point, space_state)
            
            if armor_result.is_empty():
                # Full damage to unarmored areas
                damage_map[test_point] = 1.0
            else:
                # Reduced damage based on armor
                var armor_part = armor_result["armor_part"]
                # Calculate damage reduction based on armor properties
                damage_map[test_point] = calculate_armor_damage_reduction(armor_part)
```

## Performance Considerations

### Optimization Tips
1. **Cache space_state**: Don't get the space state repeatedly in loops
2. **Batch checks**: Group multiple point checks together when possible
3. **Use sparingly**: This is a computationally expensive operation due to multiple raycasts

### Cost Analysis
- **Raycasts per call**: 8 primary directions × multiple hits per direction
- **Typical performance**: Suitable for occasional checks (explosions, special effects)
- **Not recommended for**: Per-frame updates or high-frequency operations

## Integration with Existing Systems

### With Armor System V2
```gdscript
func get_armor_thickness_at_point(point: Vector3) -> float:
    var space_state = get_tree().root.get_world_3d().direct_space_state
    var armor_result = ArmorInteraction.get_armor_part_at_point(point, space_state)
    
    if armor_result.is_empty():
        return 0.0
    
    var armor_part = armor_result["armor_part"]
    # To get exact thickness, you'd need to determine the closest face
    # For now, return a representative thickness
    if armor_part.armor_system:
        var stats = armor_part.armor_system.get_node_armor_stats(armor_part.armor_path)
        return stats.get("average_armor", 0.0)
    
    return 0.0
```

### With Projectile System
```gdscript
func check_projectile_penetration_path(start: Vector3, end: Vector3):
    var space_state = get_tree().root.get_world_3d().direct_space_state
    var steps = 20
    var armor_layers = []
    
    for i in range(steps + 1):
        var t = float(i) / steps
        var point = start.lerp(end, t)
        var armor_result = ArmorInteraction.get_armor_part_at_point(point, space_state)
        
        if not armor_result.is_empty():
            var armor_path = armor_result["armor_path"]
            if armor_path not in armor_layers:
                armor_layers.append(armor_path)
    
    print("Projectile will pass through these armor layers: ", armor_layers)
```

## Limitations

1. **Accuracy**: Based on raycasting, so very thin armor or complex geometries might not be detected perfectly
2. **Performance**: Multiple raycasts make this unsuitable for high-frequency use
3. **Convex assumption**: Works best with convex or near-convex armor parts
4. **Edge cases**: Points exactly on armor boundaries might give inconsistent results

## Best Practices

1. **Use for significant events**: Explosions, special attacks, area effects
2. **Cache results**: If checking the same point multiple times, cache the result
3. **Validate results**: Always check if the returned dictionary is empty
4. **Consider alternatives**: For simple hit detection, existing raycast functions might be more appropriate
5. **Test thoroughly**: Complex nested armor configurations should be tested with your specific ship models

## Related Functions

- `get_next_hit()`: For finding the next armor part along a ray
- `process_hit()`: For processing projectile hits on armor
- `ArmorSystemV2.get_face_armor_thickness()`: For getting specific face armor values
