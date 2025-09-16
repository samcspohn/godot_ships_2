# Target Indicator System Documentation

## Overview
The target indicator system provides visual feedback when selecting targets for secondary weapons. When a ship is targeted by the player's secondaries, a distinct indicator appears above and to the right of the enemy's health bar.

## Features

### Visual Indicator
- **Position**: Above and to the right of the targeted ship's health bar
- **Appearance**: Orange circular indicator (◉) with pulsing animation
- **Animation**: Pulses between orange and yellow colors at 4Hz for high visibility
- **Size**: 20x20 pixels, positioned +5 pixels right and -5 pixels up from the health bar

### Automatic Detection
- The system automatically detects the current secondary target from the ship's secondary controllers
- Updates in real-time as targets change
- Works for both enemy and friendly ships (though targeting friendlies may not be practical)

## Controls

### Target Selection
- **Ctrl + Left Click**: Release mouse cursor to enable target selection mode
- **Left Click on Ship**: Select the clicked ship as the secondary target
- **Ctrl Release**: Return to normal camera control mode

### Target Clearing
- **X Key**: Clear the current secondary target for all secondary controllers

## Implementation Details

### Files Modified
1. **scenes/camera_ui.tscn**: Added target indicator UI elements to ship templates
2. **src/camera/camera_ui_scene.gd**: Added target tracking and visual update logic
3. **src/client/PlayerController.gd**: Added target selection and clearing functionality

### Key Components

#### Target Indicator Elements
```gdscript
# Added to both EnemyShipTemplate and FriendlyShipTemplate
[node name="EnemyTargetIndicator" type="ColorRect"]
- Position: anchored to top-right of ship UI
- Color: Orange (1, 0.6, 0, 0.9) with yellow pulse
- Initially hidden, shown when ship is targeted

[node name="EnemyTargetIcon" type="Label"] 
- Text: "◉" (filled circle)
- Color: Black text for contrast
- Font size: 12
```

#### Core Functions

**CameraUIScene:**
```gdscript
func set_secondary_target(target_ship: Ship) -> void
func clear_secondary_target() -> void
# Automatic target detection in _process()
```

**PlayerController:**
```gdscript
func select_target_ship(target_ship: Ship) -> void
func show_target_indicator(target_ship: Ship) -> void
func clear_secondary_target() -> void
```

### Animation System
- Uses `sin(Time.get_ticks_msec() / 1000.0 * 4.0)` for smooth pulsing
- Interpolates between base orange color and bright yellow
- Updates every frame for smooth animation

## Usage Instructions

1. **To Target a Ship:**
   - Hold Ctrl to release mouse cursor
   - Click on the desired enemy ship
   - Release Ctrl to return to camera control
   - The target indicator will appear above the selected ship

2. **To Clear Target:**
   - Press X key to clear all secondary targets
   - The target indicator will disappear

3. **Visual Feedback:**
   - Targeted ships show a pulsing orange/yellow indicator
   - Indicator appears above and to the right of the ship's health bar
   - Animation makes it easily visible during combat

## Technical Notes

- Target detection is automatic and updates every frame
- Multiple secondary controllers are supported (all target the same ship)
- System works with existing ship UI templates
- Compatible with both enemy and friendly ship detection
- Performance optimized with minimal overhead per frame
