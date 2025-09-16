# Consumable Keyboard Shortcut Visualization Implementation

## Overview
Added keyboard shortcut visualization to consumable buttons in the UI. Each consumable button now displays the corresponding keyboard shortcut in the bottom-right corner.

## Changes Made

### 1. Scene File Updates (`scenes/camera_ui.tscn`)
- Added a `KeyboardShortcutLabel` node to the `ConsumableTemplate`
- Positioned in the bottom-right corner of the button (anchored to bottom-right)
- Styled with:
  - White text with shadow for visibility
  - Small font size (10px)
  - Centered alignment within the label area

### 2. Script Updates (`src/camera/camera_ui_scene.gd`)
- Added `consumable_shortcut_labels` array to track shortcut labels
- Added `consumable_actions` array with action names: `["consumable_1", "consumable_2", "consumable_3"]`
- Added `get_keyboard_shortcut_for_action()` function to dynamically get keys from InputMap
- Updated `setup_consumable_ui()` function to:
  - Get the `KeyboardShortcutLabel` from duplicated template
  - Use InputMap to get the actual keyboard shortcut for each action
  - Set the dynamic shortcut text based on current input mappings
  - Store the label reference in the tracking array

## Keyboard Mappings
The consumable shortcuts are dynamically retrieved from the InputMap using `InputMap.action_get_events()`:

- **Consumable 1**: Reads from "consumable_1" action (currently R key)
- **Consumable 2**: Reads from "consumable_2" action (currently T key) 
- **Consumable 3**: Reads from "consumable_3" action (currently Y key)

This approach ensures that if the key bindings are changed in `project.godot` or through user settings, the UI will automatically show the correct keys.

## Visual Result
Each consumable button now shows a small letter in the bottom-right corner, dynamically retrieved from the InputMap:
- First consumable slot: Shows the key bound to "consumable_1" action (default: "R")
- Second consumable slot: Shows the key bound to "consumable_2" action (default: "T") 
- Third consumable slot: Shows the key bound to "consumable_3" action (default: "Y")

The labels automatically update if the key bindings are changed, making the system flexible and user-customizable.

## Implementation Details

### Dynamic Key Retrieval
```gdscript
func get_keyboard_shortcut_for_action(action_name: String) -> String:
    if not InputMap.has_action(action_name):
        return ""
    
    var events = InputMap.action_get_events(action_name)
    for event in events:
        if event is InputEventKey:
            var key_event = event as InputEventKey
            return OS.get_keycode_string(key_event.physical_keycode)
    
    return ""
```

This function:
- Checks if the action exists in the InputMap
- Gets all events for the action
- Finds the first keyboard event
- Converts the physical keycode to a readable string

### Template Structure
```
ConsumableTemplate (TextureButton)
├── ProgressBar (cooldown overlay)
└── KeyboardShortcutLabel (NEW - shows keyboard shortcut)
```

### Label Positioning
- Anchored to bottom-right of button
- 13px wide × 13px tall
- 2px margin from right and bottom edges
- Semi-transparent white text with shadow

### Code Integration
The shortcut labels are created when `setup_consumable_ui()` is called and dynamically populated using `InputMap.action_get_events()`. The system automatically handles:
- Missing or undefined actions (shows empty string)
- Multiple input events per action (uses first keyboard event found)
- Custom key bindings (automatically reflects user changes)

No additional input handling was needed since keyboard shortcuts were already implemented.

## Benefits
- Improves user experience by showing current keyboard shortcuts
- **Dynamic and flexible**: Automatically adapts to key binding changes
- **Future-proof**: Works with user-customizable controls
- Follows common UI patterns found in games
- Non-intrusive design that doesn't interfere with existing functionality
- Automatically scales with the number of consumable slots
- **Maintainable**: No hardcoded key values to update
