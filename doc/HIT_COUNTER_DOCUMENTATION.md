# Hit Counter System Documentation

## Overview
The hit counter system displays temporary hit indicators in dedicated containers when damage events occur. These counters appear for 5 seconds and show the count of each hit type (penetration, shatter, ricochet, overpenetration, citadel) with visual distinction between main and secondary gun hits. The system uses pre-created UI elements in the scene that are toggled visible/hidden rather than created/destroyed at runtime.

## Features

### Visual Display
- **Location**: 
  - Main hits: `MainContainer/TopRightPanel/MainCounterTemp`
  - Secondary hits: `MainContainer/TopRightPanel/SecCounterTemp`
- **Appearance**: Identical to the existing permanent hit counter UI elements (pre-created in scene)
- **Duration**: 5 seconds per counter
- **Behavior**: 
  - New hit of same type increments counter and resets timer
  - Only relevant hit types are shown (irrelevant counters remain hidden)
  - Main gun hits appear in MainCounterTemp, secondary in SecCounterTemp
  - Uses the same styling and layout as permanent counters

### Hit Type Colors
- **Visual Style**: Uses the exact same styling as the permanent hit counters in the scene
- **Background Colors**: Match the existing StyleBoxFlat resources defined in camera_ui.tscn
- **Typography**: Consistent fonts, sizes, and colors with existing UI elements

### Counter Format
- Main gun hits: Same format as permanent main counters (e.g., "P" with count)
- Secondary gun hits: Type letter + "(SEC)" in two lines (e.g., "P\n(SEC)" with count)

## Implementation Details

### Key Components

1. **Main Counter Container** (`main_counter_temp`): HBoxContainer for main weapon hit counters
2. **Secondary Counter Container** (`sec_counter_temp`): HBoxContainer for secondary weapon hit counters  
3. **Pre-created UI Elements**: All hit counter UI elements exist in the scene file
4. **Active Counters** (`active_hit_counters`): Dictionary tracking which counters are currently active
5. **Timer System**: Each active counter has a 5-second countdown timer

### Main Functions

#### `setup_hit_counter_system()`
- Maps hit types to their pre-created UI element references
- Ensures containers start hidden
- Called during UI initialization

#### `show_hit_counter(hit_type: String, is_secondary: bool)`
- Main entry point for displaying hit counters
- Either increments existing counter or shows new one
- Resets timer to full duration
- Makes appropriate container visible

#### `update_hit_counters(delta: float)`
- Called each frame to update timers
- Hides expired counters
- Hides containers when no counters are active
- Maintains proper counter lifecycle
#### `process_damage_events(damage_events: Array)`
- Processes incoming damage events from ship stats
- Converts event types to display format
- Clears events after processing

### Integration Points

#### PlayerController Changes
- Removed immediate clearing of `damage_events` array
- Events now processed by both floating damage and hit counter systems
- Hit counter system handles clearing after processing

#### Camera UI Integration
- Hit counter processing added to `_process()` function
- Events processed before regular UI updates
- Automatic cleanup of expired counters

#### Scene File Structure
- All hit counter UI elements pre-created in camera_ui.tscn
- MainCounterTemp and SecCounterTemp containers added to TopRightPanel
- Each hit type has dedicated Control nodes with proper styling
- Secondary counters include "(SEC)" designation in their labels

## Usage

The system works automatically when damage events occur. No manual intervention required.

### Damage Event Flow
1. Projectile hits ship and generates damage event
2. Event added to ship's `stats.damage_events` array
3. PlayerController processes for floating damage
4. Camera UI processes for hit counters
5. Events cleared by camera UI to prevent duplicates

### Counter Lifecycle
1. Hit occurs → Counter becomes visible or count incremented
2. Timer set to 5 seconds and begins countdown
3. Additional hits of same type reset timer to 5 seconds
4. When timer expires, counter becomes hidden

## Testing

To test the hit counter system:
1. Start a battle scenario
2. Fire at enemy ships or take damage
3. Observe hit counters appearing in MainCounterTemp and SecCounterTemp
4. Verify different hit types show different colors
5. Check that secondary hits appear in SecCounterTemp with "(SEC)" labels
6. Confirm counters disappear after 5 seconds of inactivity

## Technical Notes

### Performance Considerations
- No runtime UI creation/destruction - all elements pre-exist
- Simple visibility toggling is more efficient than node management
- Minimal overhead for timer-based cleanup system

### Styling System
- Uses existing UI templates from MainHitCounters structure
- All styling defined in scene file
- Consistent with existing permanent hit counter elements
- No custom StyleBox creation needed

### Event Processing
- Handles HitResult enum values correctly
- Distinguishes between main and secondary weapon hits
- Graceful handling of unknown hit types

## Usage

The system works automatically when damage events occur. No manual intervention required.

### Damage Event Flow
1. Projectile hits ship and generates damage event
2. Event added to ship's `stats.damage_events` array
3. PlayerController processes for floating damage
4. Camera UI processes for hit counters
5. Events cleared by camera UI to prevent duplicates

### Counter Lifecycle
1. Hit occurs → Counter created or count incremented
2. Timer set to 5 seconds and begins countdown
3. Additional hits of same type reset timer to 5 seconds
4. When timer expires, counter fades and is removed

## Testing

To test the hit counter system:
1. Start a battle scenario
2. Fire at enemy ships or take damage
3. Observe hit counters appearing on right side
4. Verify different hit types show different colors
5. Check that secondary hits appear below main hits
6. Confirm counters disappear after 5 seconds of inactivity

## Technical Notes

### Performance Considerations
- Counters are dynamically created/destroyed as needed
- No permanent UI elements for hit types not in use
- Efficient timer-based cleanup system

### Styling System
- Uses existing UI templates from MainHitCounters structure
- Duplicates Control nodes with all styling intact
- Consistent with existing permanent hit counter elements
- No custom StyleBox creation needed

### Event Processing
- Handles HitResult enum values correctly
- Distinguishes between main and secondary weapon hits
- Graceful handling of unknown hit types
