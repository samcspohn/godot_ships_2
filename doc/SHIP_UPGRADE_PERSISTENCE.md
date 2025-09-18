# Ship Upgrade Persistence System

This system allows ship upgrades selected in the menu to persist when a player joins a game. 

## How It Works

1. **In the menu:**
   - Players select upgrades for their ship
   - Upgrades are saved both to `GameSettings` (for the current session) and to a player-specific file (for persistence between sessions)

2. **On the server:**
   - When a player connects, the server loads their specific upgrade file
   - The server applies these upgrades to the player's ship

3. **On the client:**
   - The client applies the same upgrades to the local ship representation
   - This ensures the client and server ships have identical upgrades

## Key Components

### PlayerUpgrades Utility (`src/utils/player_upgrades.gd`)
Handles saving and loading player-specific upgrade data.

- `save_player_upgrades(player_name, ship_path, upgrades)`: Saves a player's upgrades to a JSON file
- `load_player_upgrades(player_name)`: Loads a player's upgrades from their JSON file
- `apply_upgrades_to_ship(ship, player_name, upgrade_manager)`: Applies loaded upgrades to a ship

### Server Integration (`src/server/server.gd`)
The server loads and applies player upgrades when spawning ships.

- Added `_load_and_apply_player_upgrades(ship, player_name)` function to load and apply upgrades
- Modified `spawn_player()` to call this function when spawning non-bot ships

### Client Integration
Client-side ships get the same upgrades as configured in the menu.

- Modified `spawn_players_client()` to apply the upgrades from `GameSettings` to the local player's ship

## File Structure

Upgrade data is stored in player-specific JSON files at:
```
user://player_upgrades/<player_name>.json
```

Each file contains:
- Player name
- Ship path
- Upgrade data (slot to upgrade path mapping)
- Last update timestamp

## Testing

You can test the system with the included test script:
```
src/utils/test_player_upgrades.tscn
```

This scene demonstrates saving and loading player upgrades.
