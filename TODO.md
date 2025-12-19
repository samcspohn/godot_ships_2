# Ship Combat Game - TODO

// not weather effects
- [x] fix close(long?) range aiming too high
- [ ] incorrect hit effect (explosion on ricochet)
- [x] hit ribbons not showing
- [ ] auto lockon
- [ ] sniper reticle
- [ ] torpedo aiming indicator
	- [ ] torpedo arming distance indicator
	- [ ] torpedo spread indicator
- [ ] part health system / saturation
- [ ] concealment
	- [ ] visual indicator for concealment range
	- [ ] radio transmitter/reciever system for spotting
- [ ] ship movement overhaul
- [ ] ship sound effects
- [ ] match end handling (victory/defeat screens/stats/back to port)
- [ ] friendly consumable use visuals

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
