# Ship Combat Game - TODO


# Commander Skills — Not Yet Implementable
The following skills from the design list require engine/system work before they can be implemented:

- [ ] **Preventive Maintenance** — No module incapacitation system exists (`incapacitation_chance` not in GunParams/TurretParams). Needs a module HP / incap system first.
- [ ] **Grease the Gears — First-Strike Bonus** — The implemented skill has the base +10% traverse. The extra +5% "first-strike" bonus (guns haven't fired in 10 s) needs per-gun last-fire-time tracking (hook into Gun fire event). Currently `Grease the Gears` only grants the base traverse.
- [ ] **Pyrotechnician** — Requires per-shell-type reload differentiation in the firing system. Currently `reload_time` is a single value on GunParams; there is no way to distinguish HE-reload vs AP-reload or apply a per-salvo penalty.
- [ ] **Radio Location** — Needs a persistent HUD compass indicator showing the bearing to the nearest enemy. Server-side logic (get_valid_targets + direction) is feasible but requires a custom battle HUD widget.
- [ ] **Torpedo Reload Booster** — Better implemented as a consumable (activated burst). The consumable system already supports instant-effect items (duration = 0). Should be added as a `ConsumableItem` subclass, not a skill.
- [ ] **Adrenal Spotter** — While unspotted: -25% main gun reload buildup. The "unspotted" state is `ship.visible_to_enemy` (server-side), but "main gun reload buildup" doesn't exist as a concept — the main gun has a single `reload_time` param, not a buildup timer.
- [ ] **Manual Secondaries** — Lock secondaries to a single focus target with +35% accuracy / -15% reload. Requires a targeting-lock mode in `SecondaryController_` that bypasses the current auto-targeting logic.
- [ ] **Priority Target** — Live counter of how many enemy guns are aimed at you (with a small buff). Requires iterating all enemy `ArtilleryController.aim_point` positions and comparing them to this ship's position each frame — complex and performance-sensitive.
- [ ] **Dead Eye (range-gated variant)** — A version that only activates dispersion reduction at ranges >75% of max range. The existing `Dead Eye` is always-on. Implementing a conditional version needs a `_proc` that checks `aim_point.distance_to(ship.global_position)` vs range each frame.


# QOL
- [ ] save settings (screen resolution, minimap size, volume levels, keybindings)
- [ ] crtl+x lock guns
- [ ] hover over UI elements for tooltips (gun stats, consumable info, etc)
- [ ] add fire ribbon, temporary frag/fire ribbon.
- [ ] add kill feed
- [ ] map view + autopilot

# bot
- [ ] need to angle when engaging
- [ ] angle when kiting + turn to shoot front guns when reloaded and turn back
- [ ] use torpedos with angle offsets to increase spread
- [ ] use navmesh to navigate around obstacles
- [ ] reduce raycasts by using navmesh + check for other ships distance

## Todo Soon ⏳
concealment, sound effects, damage saturation, clamp sniper range
- [ ] dp guns shoot up + flak/explode at range
- [ ] don't count damage against team
- [x] fix close(long?) range aiming too high
- [ ] incorrect hit effect (explosion on ricochet)
- [x] hit ribbons not showing
- [ ] auto lockon
- [x] sniper reticle
- [ ] torpedo aiming indicator
	- [ ] torpedo arming distance indicator
	- [ ] torpedo spread indicator
- [x] part health system / saturation
- [ ] concealment
	- [x] visual indicator for concealment range
	- [ ] radio transmitter/reciever system for spotting
- [ ] ship movement overhaul
- [ ] ship sound effects
- [ ] match end handling (victory/defeat screens/stats/back to port)
- [ ] friendly consumable use visuals
	- [ ] show on use
	- [ ] hold alt show cooldowns/ready
- [ ] hover over/click ships on minimap to show radar/hydro range circles
- [ ] stat sheet based module system for ships
- [ ] fix max gpu shells and emitters to be dynamic
- [ ] change unified particle system from cycling to available pool
- [ ] improve stat counter implementation

## Core Features ✅ (Mostly Complete)
- [x] Ship movement and controls (throttle system, rudder control, physics)
- [x] Basic guns and shooting (reload timers, firing mechanics, aiming system)
- [x] Multiplayer networking (client-server RPCs, position sync)
- [x] Health/damage system (UI complete, damage tracking working)
- [x] Ship collision (physics collision layers working)
- [x] Match timer and game flow (basic multiplayer session management)
- [x] Ship classes (Battleship implementation with different gun types)

## Combat ✅ (Advanced System Working)
- [x] Projectile ballistics with drag physics
- [x] Armor system (Advanced V2 system with JSON extraction and penetration mechanics)
- [x] Different shell types (AP, HE with different parameters)
- [x] Torpedo system (TorpedoLauncher with physics simulation)
- [x] Visual effects (explosions, different hit results, particle systems)

## Maps & Environment ✅ (Basic Implementation)
- [x] Test map with water physics
- [x] Islands and terrain (with collision detection)
- [ ] Weather effects

## UI & Polish 🔄 (Partially Complete)
- [x] Gun reload indicators (progress bars for each gun)
- [x] HUD and minimap (comprehensive UI with ship tracking, range circles)
- [x] Damage indicators (HP bars, color-coded health states)
- [x] Settings menu (basic configuration options)
- [ ] Audio (engines, guns, ambient)
- [x] Damage numbers on enemy hit (floating damage text)
- [x] Shell hit ribbons (visual feedback for different hit types)
- [x] Total damage counters (player statistics tracking)
- [x] Team display (team scores, player list)
- [ ] Sniper reticle (enhanced crosshair for precision aiming)
- [ ] Handle battle end (match results, victory/defeat screens)

## Game Modes ✅ (AI System Complete) 
- [x] AI opponents (Advanced bot system with strategic navigation and collision avoidance)
- [ ] Team deathmatch (basic team system exists)
- [ ] Capture points
- [ ] PvE missions

## Later
- [ ] Ship progression/unlocks
- [ ] Customization options
- [ ] Performance optimization
- [ ] Optimize ship synchronization to update less frequently at long distances and offscreen
- [ ] don't sync enemy consumables/weapon reloads
- [ ] don't sync fire lifetime
- [ ] Spectator mode
- [ ] More maps
- [ ] More ship classes (Cruiser, Destroyer, Carrier)
- [ ] More consumables (smoke screens, speed boosts)
