# Shell Hit Replay System

## Overview
The shell hit replay system allows you to visualize and analyze shell trajectories and armor interactions from game logs.

## Usage

1. **Access Replay Mode**: From the main menu, click the "Replay" button
2. **Input Event Data**: Paste shell hit event logs into the text input area
3. **Play Replay**: Click "Play Replay" to visualize the shell's trajectory
4. **Return**: Click "Back to Menu" to return to the main menu

## Event Format

The system parses three types of events:

### Ship Event
```
Ship: 1016 pos=(-3276.7, -1.7, 6211.8), rot=(-0.0, 4.1, 0.0)
```
- Contains ship position and rotation
- Used to position the ship model in the 3D view

### Shell Event
```
Shell: speed=785.4 vel=(-340.8, -25.2, 707.2) m/s, fuze=-1.000 s, pos=(-3282.7, 3.0, 6096.0), pen: 708.5
```
- Shows shell position, velocity, speed, fuze time, and penetration value
- Each shell event creates a point in the trajectory trail

### Armor Event
```
Armor: OVERPEN, Hull with 32.0/49.1mm (angle 49.3°), normal: (1.0, -0.1, -0.3), ship: 1016
```
- Records armor interactions (OVERPEN, RICOCHET, SHATTER, PENETRATION)
- Creates colored markers at impact points:
  - **Blue**: OVERPEN
  - **Yellow**: RICOCHET
  - **Gray**: SHATTER
  - **Red**: PENETRATION

## Features

- **3D Visualization**: Shows the Bismarck3 ship model with the shell trajectory
- **Trail Rendering**: Orange line showing the complete shell path
- **Impact Markers**: Color-coded spheres at each armor interaction point
- **Auto Camera**: Automatically positions camera to view the entire trajectory
- **Event Parsing**: Robust parser handles the complex event format

## Files

- `src/client/shell_replay.tscn` - Main replay scene
- `src/client/shell_replay.gd` - Replay controller script
- `src/client/shell_event_parser.gd` - Event parsing logic
- `src/client/main_menu_ui.gd` - Updated with replay button

## Technical Details

- Playback speed: 0.1 seconds between events (adjustable via `playback_speed` variable)
- Shell represented as orange glowing sphere
- Trail uses `ImmediateMesh` for efficient line rendering
- Camera auto-positioning based on trajectory bounds
