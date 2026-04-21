extends Node

class_name BotControllerV4

## Bot Controller V4 — Uses ShipNavigator (C++ GDExtension) for navigation
## instead of NavigationAgent3D + proxy + raycasts.
##
## Key differences from V3:
##   - No NavigationAgent3D, no Node3D navigation proxy, no nav region assignment
##   - No get_threat_vector() with 16 physics raycasts
##   - No grounded recovery state machine (navigator prevents grounding proactively)
##   - Behaviors return NavIntent instead of raw Vector3 positions
##   - ShipNavigator handles pathfinding, arc prediction, collision avoidance, and steering
##   - Outputs rudder [-1,1] and throttle [-1,4] directly to ShipMovementV4

# ===========================================================================
# DEBUG
# ===========================================================================

## Debug visualization vectors (compatible with existing camera debug drawing)
var _debug_desired_heading_vector: Vector3 = Vector3.ZERO
var _debug_heading_rudder_vector: Vector3 = Vector3.ZERO
var _debug_threat_vector: Vector3 = Vector3.ZERO
var _debug_safe_vector: Vector3 = Vector3.ZERO
var _debug_threat_weight: float = 0.0
var _debug_throttle: int = 0
var _debug_turn_sim_points_desired: Array[Vector3] = []
var _debug_turn_sim_points_undesired: Array[Vector3] = []
var _debug_shell_obstacles: Array = []  # [{landing_x, landing_z, time_remaining, caliber, landing_vx, landing_vz, threat_half_len}]
var debug_draw_turn_sim: bool = true

var debug_log_interval: float = 2.0
var debug_log_timer: float = 0.0
var debug_log: bool = false

# ===========================================================================
# REFERENCES
# ===========================================================================

var _ship: Ship
var server_node: GameServer
var movement: ShipMovementV4
var navigator: ShipNavigator
var behavior: BotBehavior

# ===========================================================================
# NAVIGATION STATE
# ===========================================================================

var target: Ship
var destination: Vector3 = Vector3.ZERO
var desired_heading: float = 0.0
var desired_heading_offset_deg: float = 0.0

# ===========================================================================
# TARGET SCANNING
# ===========================================================================

@export var target_scan_interval: float = 30.0
var target_scan_timer: float = 0.0

# ===========================================================================
# OBSTACLE TRACKING
# ===========================================================================

## How often to update obstacle positions (frames)
const OBSTACLE_UPDATE_INTERVAL: int = 4
## Maximum distance to register a ship as an obstacle
const OBSTACLE_REGISTER_RANGE: float = 5000.0

## Maximum distance to register a torpedo as an obstacle
@export var torpedo_track_range: float = 3000.0
## Torpedo detonation/avoidance radius (m) — roughly the magnetic fuze trigger zone
const TORPEDO_HIT_RADIUS: float = 20.0
## ID namespace base for torpedo obstacles (negative, never collides with ship instance IDs)
const TORPEDO_ID_OFFSET: int = -100000

## Maximum distance to query for incoming shells
const SHELL_QUERY_RANGE: float = 1000.0
## How often to force a path replan (frames). Between replans the navigator
## continues arc-based threat avoidance with the last known destination.
## At 20 fps, 10 frames = 0.5 s — adequate for the speed and scale of ships.
const PATH_UPDATE_INTERVAL: int = 8
## Distance (m) the intent destination must jump to trigger an immediate path
## replan, bypassing the PATH_UPDATE_INTERVAL cooldown.
const PATH_SIGNIFICANT_MOVE: float = 1000.0

# ===========================================================================
# INTENT SYSTEM
# ===========================================================================

## Min/max interval for behavior queries. Event-driven triggers can force
## early re-queries (subject to MIN), while MAX ensures periodic updates.
const MIN_BEHAVIOR_INTERVAL: float = 0.3
const MAX_BEHAVIOR_INTERVAL: float = 2.0
var _behavior_timer: float = 0.0
var bot_id: int = 0
var _last_intent: NavIntent = null

## The raw intent returned by the behavior BEFORE validation adjusts it.
## Used by _is_intent_similar to compare against the next behavior query.
## Without this, the cycle is: behavior returns A → validate adjusts to A' →
## next query behavior returns A again → A' vs A = "different" → re-validate → repeat.
var _last_raw_intent: NavIntent = null

## Distance threshold below which a new intent's position is considered
## "close enough" to the current one — the navigator will retarget rather
## than fully recalculating its path. Mirrors the C++ PATH_REUSE thresholds.
const INTENT_POSITION_REUSE_THRESHOLD: float = 100.0

## Heading threshold (radians) below which a heading change is considered trivial.
const INTENT_HEADING_REUSE_THRESHOLD: float = 0.35  # ~20 degrees

# ===========================================================================
# EVENT-DRIVEN INTENT TRIGGERS
# ===========================================================================

## Tracks per-enemy visibility state from the previous frame.
## Key = ship instance id, Value = was visible_to_enemy last check.
var _enemy_visibility_cache: Dictionary = {}

## Number of living friendly ships last frame (used to detect friendly death).
var _last_friendly_alive_count: int = -1

## Whether we were in cover last frame (behavior.is_in_cover).
var _was_in_cover: bool = false

## Cooldown (seconds) after navigator avoidance ends before throttle_override
## is allowed again.  Prevents the push-pull oscillation where a behavior's
## throttle_override fights the avoidance system on alternating frames.
var _avoidance_throttle_cooldown: float = 0.0
const AVOIDANCE_THROTTLE_COOLDOWN_DURATION: float = 3.0

## When true, the next physics frame will force an immediate intent update
## regardless of the stagger timer.
var _force_intent_next_frame: bool = false
## When true, the next _tick_behavior call will force a target rescan
## regardless of the scan timer.
var _force_target_rescan: bool = false

## Cooldown timer (seconds) to prevent event-driven triggers from firing
## more than once per second. Reset after each forced intent update.
var _event_cooldown: float = 0.0
const EVENT_COOLDOWN_DURATION: float = 1.0

## Cached average enemy position for centroid-shift detection.
var _cached_enemy_avg: Vector3 = Vector3.ZERO

## Last HP bracket (1-4) for threshold-crossing detection. -1 = uninitialized.
var _last_hp_bracket: int = -1
## Frame counter controlling how often navigate_to() is called (path replanning).
# var _path_update_timer: int = 0
## Last destination sent to navigate_to() — used to detect significant moves.
var _last_path_destination: Vector3 = Vector3.ZERO

var should_query_behavior: bool = false


# ===========================================================================
# LIFECYCLE
# ===========================================================================

func _ready() -> void:
	if !_Utils.authority():
		set_physics_process(false)
		return

	server_node = get_tree().root.get_node("/root/Server")
	movement = get_node("../MovementController")

	# Initialize the C++ ShipNavigator
	navigator = ShipNavigator.new()

	# Connect to the shared NavigationMap (built by NavigationMapManager autoload)
	var nav_map = NavigationMapManager.get_map()
	if nav_map != null:
		navigator.set_map(nav_map)
	else:
		push_warning("[BotControllerV4] NavigationMap not yet built — navigator will operate without terrain data")

	# Connect to the shared WaypointGraph (built alongside NavigationMap)
	var wp_graph = NavigationMapManager.get_waypoint_graph()
	if wp_graph != null:
		navigator.set_waypoint_graph(wp_graph)
	else:
		push_warning("[BotControllerV4] WaypointGraph not yet built — navigator will pathfind without graph")

	# Set ship kinematic parameters from the movement controller
	# These match ShipMovementV4's exported properties
	navigator.set_ship_params(
		movement.turning_circle_radius,
		movement.rudder_response_time,
		movement.acceleration_time,
		movement.deceleration_time,
		movement.max_speed,
		movement.reverse_speed_ratio,
		movement.ship_length,
		movement.ship_beam,
		movement.turn_speed_loss,
		movement.BASE_DRAG
	)

	# Initialize behavior
	behavior._ship = _ship
	add_child(behavior)

	# Defer the initial target acquisition so the scene tree is ready
	get_tree().create_timer(0.2).timeout.connect(_deferred_init)


func _deferred_init() -> void:
	# Re-check map and waypoint graph in case they were built after our _ready
	if navigator != null and NavigationMapManager.is_map_ready():
		navigator.set_map(NavigationMapManager.get_map())
		var wp_graph = NavigationMapManager.get_waypoint_graph()
		if wp_graph != null:
			navigator.set_waypoint_graph(wp_graph)

	# Pass bot_id to navigator for staggered periodic replanning
	if navigator != null:
		navigator.set_bot_id(bot_id)

	# Set initial destination (forward from spawn)
	destination = _ship.global_position - _ship.global_transform.basis.z * 10000.0
	destination.y = 0.0


# ===========================================================================
# MAIN LOOP
# ===========================================================================

func _physics_process(delta: float) -> void:
	if _ship == null or movement == null or navigator == null:
		return

	if Debug.follow_ship == _ship:
		_emit_debug_draws()

	var in_update_slot: bool = Engine.get_physics_frames() % OBSTACLE_UPDATE_INTERVAL == bot_id % OBSTACLE_UPDATE_INTERVAL

	# --- Timers: tick every frame for accurate timing ---
	_behavior_timer += delta
	if _event_cooldown > 0.0:
		_event_cooldown -= delta

	# =========================================================================
	# TIER 1 — every frame
	# navigator.set_state() drives arc prediction and emergency steering, so it
	# must receive fresh ship state on every tick for optimal threat avoidance.
	# Shell and torpedo data are equally time-sensitive.
	# Torpedo obstacles are re-registered every frame OUTSIDE the update slot;
	# inside the slot _update_obstacles() handles the full clear + re-add.
	# =========================================================================

	if Engine.get_physics_frames() % 3 == bot_id % 3:
		navigator.set_state(
			_ship.global_position,
			_ship.linear_velocity,
			get_ship_heading(),
			_ship.angular_velocity.y,
			movement.rudder_input,
			get_current_speed(),
			delta
		)
		navigator.set_grounded(movement.is_grounded)

		if _ship.health_controller:
			var hp_frac: float = _ship.health_controller.current_hp / maxf(_ship.health_controller.max_hp, 1.0)
			navigator.set_health_fraction(hp_frac)

		_update_shell_threats()

	if not in_update_slot:
		# _update_obstacles() (called below in the slot) already ends with
		# _register_torpedo_obstacles(), so only call it on non-slot frames.
		_register_torpedo_obstacles()

	# =========================================================================
	# TIER 2 — staggered bot slot (every OBSTACLE_UPDATE_INTERVAL frames)
	# Ship obstacle registration is expensive (iterates all ships), so it is
	# spread across bots. Behavior and intent queries also belong here.
	# =========================================================================
	if in_update_slot:
		# Full obstacle refresh: clear everything, re-add ships, re-add torpedoes.
		# This is the only place clear_obstacles() is called.
		_update_obstacles()
		_update_threat_zones()

		# Event checks involve server queries — deferred to slot, not every frame.
		if _event_cooldown <= 0.0:
			_check_intent_events()

		# --- Get navigation intent from behavior ---
		if _force_intent_next_frame:
			should_query_behavior = true
			_force_target_rescan = true
			_force_intent_next_frame = false
			_event_cooldown = EVENT_COOLDOWN_DURATION
			_behavior_timer = 0.0
		elif _behavior_timer >= MAX_BEHAVIOR_INTERVAL:
			should_query_behavior = true
			_behavior_timer = 0.0

		if should_query_behavior:
			should_query_behavior = false
			_update_nav_intent()

	# =========================================================================
	# TIER 3 — path update (every PATH_UPDATE_INTERVAL frames, or immediately
	# when the intent destination moves significantly)
	# Calls navigate_to() which sets the D* Lite goal. The C++ navigator will
	# only trigger a full replan when the destination has actually changed
	# (built-in threshold: turning_circle_radius * 0.5). The GDScript-side
	# PATH_SIGNIFICANT_MOVE guard ensures a brand-new waypoint is pushed
	# immediately rather than waiting for the next interval tick.
	# =========================================================================
	# _path_update_timer += 1
	var current_dest: Vector3 = _last_intent.target_position if _last_intent != null \
		else Vector3(destination.x, 0.0, destination.z)
	var dest_moved_far: bool = current_dest.distance_to(_last_path_destination) >= PATH_SIGNIFICANT_MOVE

	if Engine.get_physics_frames() % PATH_UPDATE_INTERVAL == bot_id % PATH_UPDATE_INTERVAL or dest_moved_far:
		# _path_update_timer = 0
		_last_path_destination = current_dest
		_execute_nav_intent()

	# --- 5. Read steering output from navigator ---
	var rudder: float = navigator.get_rudder()
	var throttle: int = navigator.get_throttle()

	# --- 5b. Apply NavIntent throttle override ---
	# Behaviors can request a minimum throttle (e.g. CAs approaching cover at speed)
	# to prevent the navigator from decelerating too early.
	# Only apply when:
	#   - The navigator is in NORMAL mode (not EMERGENCY)
	#   - The navigator is going forward (throttle >= 0) — never override reverse
	#   - The navigator isn't signaling collision — never force speed into an obstacle
	#   - Avoidance throttle cooldown has expired — after the navigator was recently
	#     dodging an obstacle, don't immediately force high throttle back toward it
	var nav_st: int = navigator.get_nav_state()
	var is_emergency: bool = nav_st == 1  # EMERGENCY
	if navigator.is_collision_imminent():
		_avoidance_throttle_cooldown = AVOIDANCE_THROTTLE_COOLDOWN_DURATION
	elif _avoidance_throttle_cooldown > 0.0:
		_avoidance_throttle_cooldown -= delta
	var throttle_override_allowed: bool = (
		_last_intent != null
		and _last_intent.throttle_override >= 0
		and throttle >= 0
		and not navigator.is_collision_imminent()
		and not is_emergency
		and _avoidance_throttle_cooldown <= 0.0
	)
	if throttle_override_allowed:
		throttle = maxi(throttle, _last_intent.throttle_override)

	# --- 6. Apply behavior speed modifier (DD evasion speed variation etc.) ---
	var speed_mult: float = behavior.get_speed_multiplier()
	if speed_mult != 1.0:
		throttle = clampi(int(throttle * speed_mult), -1, 4)

	# --- 7. Send to movement controller ---
	movement.set_movement_input([throttle, rudder])

	# --- 8. Update desired heading for debug visualization ---
	desired_heading = navigator.get_desired_heading()
	_debug_throttle = throttle
	_update_debug_vectors(rudder)

	# # --- 8b. Emit immediate-mode debug draws when being followed ---
	# if Debug.follow_ship == _ship:
	# 	_emit_debug_draws()

	# --- 9. Behavior tick (target scanning, firing, consumables) ---
	_tick_behavior(delta)


# ===========================================================================
# NAVIGATION INTENT
# ===========================================================================

func _update_nav_intent() -> void:
	var _dbg := int(_ship.name) < 1004
	var friendly = server_node.get_team_ships(_ship.team.team_id)
	var enemy = server_node.get_valid_targets(_ship.team.team_id)

	var new_intent: NavIntent = null

	# Check if behavior supports the new NavIntent interface
	new_intent = behavior.get_nav_intent(target, _ship, server_node)

	# --- Smart comparison: compare raw-to-raw to prevent oscillation ---
	# When similar, still pass through position + heading so the navigator
	# always sees the freshest coordinates. It decides whether to replan
	# based on its own threshold in navigate_to().
	if new_intent != null and _last_raw_intent != null and _is_intent_similar(_last_raw_intent, new_intent):
		_last_raw_intent = new_intent
		_last_intent.target_heading = new_intent.target_heading
		_last_intent.target_position = new_intent.target_position
		return

	# Store the raw behavior intent BEFORE validation modifies it.
	_last_raw_intent = new_intent
	_last_intent = new_intent

	# --- Validate destination is in navigable water ---
	if _last_intent != null and NavigationMapManager.is_map_ready():
		var nav_map = NavigationMapManager.get_map()
		var clearance: float = navigator.get_clearance_radius()
		var turning_radius: float = movement.turning_circle_radius
		var ship_pos_2d := Vector2(_ship.global_position.x, _ship.global_position.z)
		var dest_2d := Vector2(_last_intent.target_position.x, _last_intent.target_position.z)
		if not nav_map.is_navigable(dest_2d.x, dest_2d.y, clearance):
			var safe := nav_map.safe_nav_point(ship_pos_2d, dest_2d, clearance, turning_radius)
			_last_intent.target_position = Vector3(safe["position"].x, 0.0, safe["position"].y)

	# --- Push destination out of enemy threat zones when sneaking ---
	if _last_intent != null and behavior != null and behavior.wants_stealth:
		_adjust_destination_for_threats(_last_intent)

	# Track destination for debug drawing
	if _last_intent != null:
		destination = _last_intent.target_position


func _execute_nav_intent() -> void:
	if _last_intent == null:
		navigator.navigate_to(Vector3(destination.x, 0.0, destination.z), get_ship_heading(), 0.0)
		return
	navigator.navigate_to(
		_last_intent.target_position,
		_last_intent.target_heading,
		_last_intent.hold_radius,
		_last_intent.heading_tolerance
	)

## Get the current NavIntent mode as a human-readable string (for debug overlay)
func get_nav_mode_string() -> String:
	return "NAVIGATE"


# ===========================================================================
# OBSTACLE MANAGEMENT
# ===========================================================================

func _update_obstacles() -> void:
	# return
	# Clear and re-register all nearby ships as dynamic obstacles
	navigator.clear_obstacles()

	var all_ships = server_node.get_all_ships()
	for ship in all_ships:
		if ship == _ship:
			continue
		if not is_instance_valid(ship) or not ship.is_alive():
			continue

		var dist = _ship.global_position.distance_to(ship.global_position)
		if dist > OBSTACLE_REGISTER_RANGE:
			continue

		var ship_id = ship.get_instance_id()
		var pos_2d = Vector2(ship.global_position.x, ship.global_position.z)
		var vel_2d = Vector2(ship.linear_velocity.x, ship.linear_velocity.z)
		var ship_length = ship.movement_controller.ship_length if ship.movement_controller else 200.0
		var radius = ship_length * 0.5
		# print("[Obstacle %s] Registering ship %s as obstacle at dist=%.0f" % [_ship.name, ship.name, dist])
		navigator.register_obstacle(ship_id, pos_2d, vel_2d, radius, ship_length)

	# Re-register torpedo obstacles so they are always current alongside ship obstacles.
	# Torpedoes use negative IDs and are added on top of the freshly-cleared obstacle map.
	_register_torpedo_obstacles()


func _update_torpedo_obstacles() -> void:
	# Remove stale torpedo obstacle IDs and add/refresh current ones.
	# We don't call clear_obstacles() here because _update_obstacles() already
	# did that on its own cadence — we just patch the torpedo entries each cycle.
	_register_torpedo_obstacles()


func _register_torpedo_obstacles() -> void:
	## Iterate the live torpedo array and register armed, visible, enemy torpedoes
	## as navigator obstacles using the negative TORPEDO_ID_OFFSET namespace.
	var tm: _TorpedoManager = TorpedoManager as _TorpedoManager
	if tm == null:
		return

	var my_team_id: int = _ship.team.team_id if _ship.team else -1

	for i in tm.torpedos.size():
		var torp: _TorpedoManager.TorpedoData = tm.torpedos[i]
		if torp == null:
			continue

		# Only track armed torpedoes — unarmed ones are still inside their safe
		# arming distance and cannot detonate yet.
		if not torp.armed:
			continue

		# Ignore friendly torpedoes.
		if torp.owner != null and torp.owner.team != null and torp.owner.team.team_id == my_team_id:
			continue

		# Ignore torpedoes that our team hasn't detected yet.
		if not torp.visible_to_enemy:
			continue

		var dist: float = _ship.global_position.distance_to(torp.position)
		if dist > torpedo_track_range:
			continue

		var obs_id: int = TORPEDO_ID_OFFSET - i
		var pos_2d := Vector2(torp.position.x, torp.position.z)
		# Velocity: torpedo direction × speed × game speed multiplier
		var vel_2d := Vector2(torp.direction.x, torp.direction.z) * torp.params.speed * _TorpedoManager.TORPEDO_SPEED_MULTIPLIER

		# length = 0.0 flags this as a torpedo to the C++ avoidance logic
		# (distinguishable from ships which always have length > 0).
		navigator.register_obstacle(obs_id, pos_2d, vel_2d, TORPEDO_HIT_RADIUS, 0.0)



func _update_shell_threats() -> void:
	navigator.clear_incoming_shells()
	var my_team_id: int = _ship.team.team_id if _ship.team else -1
	var my_pos_2d := Vector2(_ship.global_position.x, _ship.global_position.z)

	var shells: Array = ProjectileManager.get_shells_near_position(
		my_pos_2d, SHELL_QUERY_RANGE, my_team_id
	)

	_debug_shell_obstacles = shells

	for s in shells:
		var vx: float = s["landing_vx"]
		var vz: float = s["landing_vz"]
		var spd: float = sqrt(vx * vx + vz * vz)
		var landing_dir := Vector2(vx, vz) / maxf(spd, 1e-10)
		navigator.add_incoming_shell(
			s["shell_id"],
			Vector2(s["landing_x"], s["landing_z"]),
			s["time_remaining"],
			s["caliber"],
			landing_dir,
			s["threat_half_len"]
		)


## Push the intent's destination out of enemy threat zones so the A* goal
## is in pathable territory.  Only active when SNEAKING — mirrors the same
## condition used by _update_threat_zones().
##
## For every enemy whose soft_radius covers the destination we push the
## destination radially away from that enemy until it sits just outside the
## soft_radius.  After all pushes we re-validate against terrain so the
## adjusted point is still in navigable water.
func _adjust_destination_for_threats(intent: NavIntent) -> void:
	if behavior == null:
		return

	# Read concealment — same radii used by _update_threat_zones
	var my_concealment: float = 0.0
	if _ship.concealment != null and _ship.concealment.params != null:
		my_concealment = (_ship.concealment.params.p() as ConcealmentParams).radius
	if my_concealment <= 0.0:
		return

	# HP-based radius scaling (matches _update_threat_zones)
	var radius_mult: float = behavior.get_concealment_radius_multiplier()
	var soft_radius_base: float = (my_concealment + 500.0) * radius_mult  # must match _update_threat_zones
	# Small buffer so the destination lands clearly outside the soft edge
	var push_margin: float = 100.0

	var dest := Vector2(intent.target_position.x, intent.target_position.z)
	var ship_pos := Vector2(_ship.global_position.x, _ship.global_position.z)
	var was_adjusted := false

	# Collect enemy positions with per-threat soft radii
	# Array of {pos: Vector2, radius: float}
	var threats: Array = []
	var enemies = server_node.get_valid_targets(_ship.team.team_id)
	for enemy_ship in enemies:
		if is_instance_valid(enemy_ship) and enemy_ship.is_alive():
			threats.append({
				pos = Vector2(enemy_ship.global_position.x, enemy_ship.global_position.z),
				radius = soft_radius_base
			})

	var unspotted = server_node.get_unspotted_enemies(_ship.team.team_id)
	var unspotted_times = server_node.get_unspotted_enemy_times(_ship.team.team_id)
	var now: float = Time.get_ticks_msec() / 1000.0
	const STALE_DECAY_SECONDS: float = 100.0
	for enemy_ship in unspotted.keys():
		if is_instance_valid(enemy_ship) and enemy_ship.is_alive():
			var last_time: float = unspotted_times.get(enemy_ship, now)
			var decay: float = 1.0 - clamp((now - last_time) / STALE_DECAY_SECONDS, 0.0, 1.0)
			if decay <= 0.0:
				continue  # Fully decayed — no longer a routing obstacle
			var lp: Vector3 = unspotted[enemy_ship]
			threats.append({
				pos = Vector2(lp.x, lp.z),
				radius = soft_radius_base * decay
			})

	# Iteratively push the destination out of every overlapping threat zone.
	var max_passes := 4
	for _pass in max_passes:
		var pushed_this_pass := false
		for t in threats:
			var epos: Vector2 = t.pos
			var soft_radius: float = t.radius
			var to_dest := dest - epos
			var dist := to_dest.length()
			if dist < soft_radius + push_margin:
				var push_dir: Vector2
				if dist > 1.0:
					push_dir = to_dest / dist
				else:
					var fallback := ship_pos - epos
					if fallback.length() > 1.0:
						push_dir = fallback.normalized()
					else:
						push_dir = Vector2(1.0, 0.0)
				dest = epos + push_dir * (soft_radius + push_margin)
				pushed_this_pass = true
				was_adjusted = true
		if not pushed_this_pass:
			break

	# Re-validate against terrain so we don't push into land
	if was_adjusted and NavigationMapManager.is_map_ready():
		var nav_map = NavigationMapManager.get_map()
		var clearance: float = navigator.get_clearance_radius()
		var turning_radius: float = movement.turning_circle_radius
		if not nav_map.is_navigable(dest.x, dest.y, clearance):
			var safe := nav_map.safe_nav_point(ship_pos, dest, clearance, turning_radius)
			dest = safe["position"]
		intent.target_position = Vector3(dest.x, 0.0, dest.y)
	elif was_adjusted:
		intent.target_position = Vector3(dest.x, 0.0, dest.y)


func _update_threat_zones() -> void:
	navigator.clear_threat_zones()

	if behavior == null or not behavior.wants_stealth:
		return

	# Use our base concealment radius as the avoidance distance
	var my_concealment: float = 0.0
	if _ship.concealment != null and _ship.concealment.params != null:
		my_concealment = (_ship.concealment.params.p() as ConcealmentParams).radius
	if my_concealment <= 0.0:
		return

	# HP-based radius scaling (e.g. DDs scale up to 1.5x at low HP)
	var radius_mult: float = behavior.get_concealment_radius_multiplier()

	var hard_radius: float = (my_concealment + _ship.movement_controller.turning_circle_radius * 2.0) * radius_mult
	var soft_radius: float = (my_concealment + 500.0) * radius_mult  # 500m safety margin

	# Register all known spotted enemy positions as threat zones (full radius)
	var enemies = server_node.get_valid_targets(_ship.team.team_id)
	for enemy in enemies:
		if not is_instance_valid(enemy) or not enemy.is_alive():
			continue
		var pos_2d = Vector2(enemy.global_position.x, enemy.global_position.z)
		navigator.add_threat_zone(pos_2d, hard_radius, soft_radius)

	# Unspotted enemies: radius decays linearly to 0 over 100 seconds
	var unspotted = server_node.get_unspotted_enemies(_ship.team.team_id)
	var unspotted_times = server_node.get_unspotted_enemy_times(_ship.team.team_id)
	var now: float = Time.get_ticks_msec() / 1000.0
	const STALE_DECAY_SECONDS: float = 100.0
	for enemy_ship in unspotted.keys():
		if not is_instance_valid(enemy_ship) or not enemy_ship.is_alive():
			continue
		var last_time: float = unspotted_times.get(enemy_ship, now)
		var decay: float = 1.0 - clamp((now - last_time) / STALE_DECAY_SECONDS, 0.0, 1.0)
		if decay <= 0.0:
			continue  # Zone fully decayed — skip
		var last_pos: Vector3 = unspotted[enemy_ship]
		var pos_2d = Vector2(last_pos.x, last_pos.z)
		navigator.add_threat_zone(pos_2d, hard_radius * decay, soft_radius * decay)


# ===========================================================================
# BEHAVIOR TICK (target scanning, firing, consumables)
# ===========================================================================

func _tick_behavior(delta: float) -> void:
	# Target scanning
	target_scan_timer += delta
	var needs_rescan: bool = false
	if _force_target_rescan:
		needs_rescan = true
		_force_target_rescan = false
	elif target_scan_timer >= target_scan_interval:
		needs_rescan = true
	elif target == null:
		needs_rescan = true
	elif target is Ship and not target.is_alive():
		needs_rescan = true
	elif target is Ship and not target.visible_to_enemy:
		# Target went hidden — rescan but only on the slower scan timer to avoid
		# thrashing when targets flicker at concealment edge. We give it a grace
		# period: only rescan if we've waited at least 2 seconds since last scan.
		if target_scan_timer >= 2.0:
			needs_rescan = true
	elif target is Ship and target.visible_to_enemy and not behavior.can_hit_target(target):
		# Target is visible but terrain-blocked — rescan after a short grace
		# period so we switch to a shootable enemy instead of sailing toward
		# one we can't actually hit. Use 3s to avoid thrashing at island edges.
		if target_scan_timer >= 3.0:
			needs_rescan = true

	if needs_rescan:
		var old_target = target
		target_scan_timer = 0.0
		_acquire_target(target)
		# If target actually changed identity, force an intent update next frame
		if target != old_target and _event_cooldown <= 0.0:
			_force_intent_next_frame = true

	# Engage current target (fire weapons)
	_engage_target()

	# Use consumables (repair, damage control)
	behavior.try_use_consumable()


func _acquire_target(last_target: Ship) -> void:
	target = behavior.pick_target(server_node.get_valid_targets(_ship.team.team_id), last_target)


func _engage_target() -> void:
	if target != null and target.visible_to_enemy and target.is_alive():
		behavior.engage_target(target)
	else:
		# No valid target — aim at destination as fallback
		_ship.artillery_controller.set_aim_input(destination)


# ===========================================================================
# SHIP STATE HELPERS
# ===========================================================================

func get_ship_heading() -> float:
	## Get ship's current heading. 0 = +Z, PI/2 = +X, etc.
	var forward := -_ship.global_transform.basis.z
	return atan2(forward.x, forward.z)


func _normalize_angle(angle: float) -> float:
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle


# ===========================================================================
# EVENT-DRIVEN INTENT TRIGGERS
# ===========================================================================

## Check for tactical events that should trigger an immediate intent update.
## Only called when _event_cooldown has expired (at most once per EVENT_COOLDOWN_DURATION).
func _check_intent_events() -> void:
	if server_node == null:
		return

	var _dbg := int(_ship.name) < 1004 and debug_log

	# --- 1. Enemy visibility change (detected or went hidden) ---
	# We use the SIZE of get_valid_targets() which is already filtered to only
	# include visible enemy ships. This avoids per-ship visible_to_enemy checks
	# that can race with the server's reset-and-redetect cycle within a frame.
	# A count change means the tactical picture genuinely shifted.
	var enemies = server_node.get_valid_targets(_ship.team.team_id)
	var visible_count: int = enemies.size()

	var cached_count: int = _enemy_visibility_cache.get("_count", -1) as int
	if cached_count >= 0 and visible_count != cached_count:
		if _dbg:
			print("[Event %s] ENEMY_VIS_COUNT %d → %d frame=%d" % [_ship.name, cached_count, visible_count, Engine.get_physics_frames()])
		_force_intent_next_frame = true
		# Always rescan target when visibility changes — a newly spotted enemy
		# may be a much better target even if the current one is still valid.
		var old_target = target
		_acquire_target(target)
		_force_target_rescan = false  # just did it
		if target != old_target and _dbg:
			print("[Event %s] TARGET_RESCAN on vis change: %s → %s" % [
				_ship.name,
				str(old_target.name) if old_target != null else "null",
				str(target.name) if target != null else "null"
			])
	_enemy_visibility_cache["_count"] = visible_count

	# --- 2. Friendly ship died ---
	var friendlies = server_node.get_team_ships(_ship.team.team_id)
	var alive_count: int = 0
	for friendly_ship in friendlies:
		if is_instance_valid(friendly_ship) and friendly_ship.is_alive():
			alive_count += 1
	if _last_friendly_alive_count >= 0 and alive_count < _last_friendly_alive_count:
		if _dbg:
			print("[Event %s] FRIENDLY_DIED %d → %d frame=%d" % [_ship.name, _last_friendly_alive_count, alive_count, Engine.get_physics_frames()])
		_force_intent_next_frame = true
	_last_friendly_alive_count = alive_count

	# --- 3. Enemy centroid shift ---
	var enemy_avg = server_node.get_enemy_avg_position(_ship.team.team_id)
	if enemy_avg != Vector3.ZERO:
		if _cached_enemy_avg != Vector3.ZERO:
			if enemy_avg.distance_to(_cached_enemy_avg) > 500.0:
				if _dbg:
					print("[Event %s] ENEMY_CENTROID_SHIFT %.0f frame=%d" % [_ship.name, enemy_avg.distance_to(_cached_enemy_avg), Engine.get_physics_frames()])
				_force_intent_next_frame = true
		_cached_enemy_avg = enemy_avg

	# --- 4. HP threshold crossing ---
	var hp_ratio = _ship.health_controller.current_hp / _ship.health_controller.max_hp
	var hp_bracket: int = 4
	if hp_ratio < 0.25: hp_bracket = 1
	elif hp_ratio < 0.50: hp_bracket = 2
	elif hp_ratio < 0.75: hp_bracket = 3
	if _last_hp_bracket >= 0 and hp_bracket != _last_hp_bracket:
		if _dbg:
			print("[Event %s] HP_BRACKET %d → %d frame=%d" % [_ship.name, _last_hp_bracket, hp_bracket, Engine.get_physics_frames()])
		_force_intent_next_frame = true
	_last_hp_bracket = hp_bracket

	# --- 5. Cover position reached or lost (for behaviors that seek cover) ---
	if behavior != null and "is_in_cover" in behavior:
		var now_in_cover: bool = behavior.is_in_cover
		if now_in_cover and not _was_in_cover:
			if _dbg:
				print("[Event %s] COVER_REACHED frame=%d" % [_ship.name, Engine.get_physics_frames()])
			_force_intent_next_frame = true
		elif not now_in_cover and _was_in_cover:
			# Ship drifted/overshot out of cover — force re-query so the behavior
			# can re-issue a POSE intent to navigate back to the cover position.
			# BUT: suppress the event when the navigator's avoidance is actively
			# steering us (e.g. a friendly ship nudged us out).  In that case
			# the displacement is temporary and firing COVER_LOST would trigger
			# a throttle_override re-approach that fights the avoidance, creating
			# an oscillation loop (reverse → throttle 3 → reverse …).
			var avoidance_active: bool = navigator.is_collision_imminent()
			if not avoidance_active:
				if _dbg:
					print("[Event %s] COVER_LOST (overshoot) frame=%d" % [_ship.name, Engine.get_physics_frames()])
				_force_intent_next_frame = true
			else:
				if _dbg:
					print("[Event %s] COVER_LOST suppressed (avoidance active) frame=%d" % [_ship.name, Engine.get_physics_frames()])
		_was_in_cover = now_in_cover


## Compare two NavIntents and return true if they are similar enough that
## switching from old_intent to new_intent would not meaningfully change
## the ship's navigation. This prevents the navigator from discarding its
## validated path and forward simulation for trivial position jitter.
func _is_intent_similar(old_intent: NavIntent, new_intent: NavIntent) -> bool:
	var pos_dist = old_intent.target_position.distance_to(new_intent.target_position)
	if pos_dist >= INTENT_POSITION_REUSE_THRESHOLD:
		return false
	var radius_diff = absf(old_intent.hold_radius - new_intent.hold_radius)
	if radius_diff >= 100.0:
		return false
	return true


func get_current_speed() -> float:
	## Signed forward speed (negative when moving backwards)
	return (-_ship.global_basis.z).dot(_ship.linear_velocity)


func calculate_desired_heading(target_position: Vector3) -> float:
	var to_target: Vector3 = target_position - _ship.global_position
	to_target.y = 0.0
	return _normalize_angle(atan2(to_target.x, to_target.z))


# ===========================================================================
# DEBUG VISUALIZATION (compatible with existing camera/debug drawing)
# ===========================================================================

func _update_debug_vectors(rudder: float) -> void:
	_debug_desired_heading_vector = Vector3(
		sin(desired_heading), 0.0, cos(desired_heading)
	).normalized()

	var current_heading_angle = get_ship_heading()
	var combined_angle = current_heading_angle - rudder * 0.5
	_debug_heading_rudder_vector = Vector3(
		sin(combined_angle), 0.0, cos(combined_angle)
	).normalized()

	# Update threat info from navigator's collision detection
	if navigator.is_collision_imminent():
		_debug_threat_weight = 1.0
		# Use navigator's predicted trajectory to show threat direction
		var trajectory = navigator.get_predicted_trajectory()
		if trajectory.size() > 1:
			var threat_dir = (trajectory[trajectory.size() - 1] - _ship.global_position).normalized()
			_debug_threat_vector = threat_dir
			_debug_safe_vector = -threat_dir
	else:
		_debug_threat_weight = 0.0
		_debug_threat_vector = Vector3.ZERO
		_debug_safe_vector = Vector3.ZERO

	# Debug logging
	if debug_log:
		debug_log_timer += 1.0 / Engine.physics_ticks_per_second
		if debug_log_timer >= debug_log_interval:
			debug_log_timer = 0.0
		# Performance timing (every second for bots 1001-1003)
		var _bot_id := int(_ship.name)
		if _bot_id >= 1001 and _bot_id <= 1003:
			if Engine.get_physics_frames() % Engine.physics_ticks_per_second == _bot_id % Engine.physics_ticks_per_second:
				var reason_names := ["none", "requested", "no_path", "deviated", "ticking"]
				var phase_names := ["IDLE", "FWD", "FALLBACK", "REVERSE", "DONE", "GRID_FB"]
				var r: int = navigator.get_timing_replan_reason()
				var p: int = navigator.get_timing_plan_phase()
				print("[Perf %s] update=%.0fus avoid=%.0fus plan=%.0fus | reason=%s phase=%s state=%s" % [
					_ship.name,
					navigator.get_timing_update_us(),
					navigator.get_timing_avoidance_us(),
					navigator.get_timing_plan_us(),
					reason_names[r] if r < reason_names.size() else str(r),
					phase_names[p] if p < phase_names.size() else str(p),
					get_nav_state_string()
				])


# ---------------------------------------------------------------------------
# Immediate-mode debug drawing — pushes draw commands to Debug autoload
# ---------------------------------------------------------------------------

func _emit_debug_draws() -> void:
	var ship_pos: Vector3 = _ship.global_position

	# --- a) Desired heading arrow (GREEN, above ship) ---
	var heading_pos = ship_pos
	heading_pos.y += 100.0
	Debug.draw_arrow(heading_pos, _debug_desired_heading_vector, 200.0, Color.GREEN, 10.0)

	# --- b) Heading + rudder arrow (CYAN) ---
	if _debug_heading_rudder_vector.length() > 0.1:
		var rudder_pos = ship_pos
		rudder_pos.y += 80.0
		Debug.draw_arrow(rudder_pos, _debug_heading_rudder_vector, 180.0, Color.CYAN, 8.0)

	# --- c) Threat arrow (ORANGE, scaled by threat weight) ---
	if _debug_threat_vector.length() > 0.1:
		var threat_pos = ship_pos
		threat_pos.y += 60.0
		Debug.draw_arrow(threat_pos, _debug_threat_vector, 200.0 * _debug_threat_weight, Color(1.0, 0.3, 0.0), 8.0)

	# --- d) Safe arrow (TEAL, same scale as threat) ---
	if _debug_safe_vector.length() > 0.1:
		var safe_pos = ship_pos
		safe_pos.y += 60.0
		Debug.draw_arrow(safe_pos, _debug_safe_vector, 200.0 * _debug_threat_weight, Color(0.0, 1.0, 0.5), 8.0)

	# --- e) Throttle indicator ---
	var throttle_pos = ship_pos
	throttle_pos.y += 120.0
	if _debug_throttle == 0:
		Debug.draw_im_sphere(throttle_pos, 15.0, Color.RED)
	else:
		var ship_forward = -_ship.global_transform.basis.z
		var current_heading_vec = Vector3(ship_forward.x, 0.0, ship_forward.z).normalized()
		var throttle_color: Color
		var throttle_length: float
		if _debug_throttle == -1:
			throttle_color = Color.YELLOW
			throttle_length = 100.0
			current_heading_vec = -current_heading_vec
		elif _debug_throttle == 4:
			throttle_color = Color(0.0, 0.4, 1.0)
			throttle_length = 200.0
		else:
			throttle_color = Color(0.0, 1.0, 0.3)
			throttle_length = 200.0 * (float(_debug_throttle) / 4.0)
		Debug.draw_arrow(throttle_pos, current_heading_vec, throttle_length, throttle_color, 9.0)

	# --- f) Target indicator (red diamond cone above target ship) ---
	if target != null and is_instance_valid(target):
		var target_pos = target.global_position
		target_pos.y += 150.0
		Debug.draw_cone(target_pos, Vector3(PI, 0.0, 0.0), 60.0, 0.0, 30.0, Color.RED, 4)

	# --- g) Destination marker (green cone pointing down) ---
	if destination != Vector3.ZERO:
		Debug.draw_cone(Vector3(destination.x, 120.0, destination.z), Vector3(PI, 0.0, 0.0), 80.0, 0.0, 40.0, Color(0.0, 1.0, 0.4, 0.9), 4)

	# --- Navigator-dependent draws ---
	if navigator != null:
		# --- h) Nav path (line strip with spheres) ---
		var nav_path = navigator.get_current_path()
		if nav_path.size() > 0:
			var full_path = PackedVector3Array([_ship.global_position])
			for pt in nav_path:
				full_path.append(Vector3(pt.x, 50.0, pt.z))
			full_path[0].y = 50.0
			Debug.draw_path(full_path, Color(1.0, 0.6, 1.0, 0.7), 1, 20.0)

		# --- i) Simulated path (cyan) ---
		var sim_path = navigator.get_simulated_path()
		if sim_path.size() >= 2:
			var raised_path = PackedVector3Array()
			for pt in sim_path:
				raised_path.append(Vector3(pt.x, 40.0, pt.z))
			var stride = maxi(raised_path.size() / 30, 1)
			Debug.draw_path(raised_path, Color(0.0, 0.9, 0.9, 0.8), stride, 12.0)

		# --- j) Predicted trajectory / turn sim points (green spheres) ---
		var trajectory = navigator.get_predicted_trajectory()
		for i in range(trajectory.size()):
			var pt = trajectory[i]
			var t = float(i) / float(max(trajectory.size() - 1, 1))
			var color = Color(0.0, 1.0 - t * 0.5, 0.0)
			Debug.draw_im_sphere(pt, 15.0, color)

		# --- k) Clearance circles ---
		var clearance_r = navigator.get_clearance_radius()
		if clearance_r > 0.0:
			var circle_pos = Vector3(ship_pos.x, 5.0, ship_pos.z)
			Debug.draw_circle(circle_pos, clearance_r, Color(0.2, 0.8, 1.0, 0.7), 64)
		var soft_clearance_r = navigator.get_soft_clearance_radius()
		if soft_clearance_r > 0.0:
			var soft_pos = Vector3(ship_pos.x, 4.0, ship_pos.z)
			Debug.draw_circle(soft_pos, soft_clearance_r, Color(1.0, 0.8, 0.0, 0.5), 64)

		# --- l) SDF tile squares ---
		if clearance_r > 0.0 and NavigationMapManager.is_map_ready():
			_emit_sdf_tiles(clearance_r)

		# --- o) Threat zones (concealment radii the pathfinder avoids) ---
		var threat_zones = navigator.get_debug_threat_zones()
		for tz in threat_zones:
			var tz_pos = Vector3(tz["x"], 6.0, tz["z"])
			Debug.draw_circle(tz_pos, tz["hard_radius"], Color(1.0, 0.0, 0.0, 0.4), 64)
			Debug.draw_circle(Vector3(tz_pos.x, 5.0, tz_pos.z), tz["soft_radius"], Color(1.0, 0.5, 0.0, 0.25), 64)

		# --- p) Torpedo & shell threat lines ---
		var threat_lines = navigator.get_debug_torpedo_threat_points()
		for t_pt in threat_lines:
			var landing_x: float = t_pt.get("landing_x", 0.0)
			var landing_z: float = t_pt.get("landing_z", 0.0)
			var time_remaining: float = t_pt.get("time_remaining", 0.0)
			var caliber: float = t_pt.get("caliber", 0.0)
			var urgency: float = clampf(1.0 - (time_remaining / 10.0), 0.0, 1.0)

			var has_line: bool = t_pt.has("line_start_x")
			if has_line:
				var sx: float = t_pt.get("line_start_x", 0.0)
				var sz: float = t_pt.get("line_start_z", 0.0)
				var ex: float = t_pt.get("line_end_x", 0.0)
				var ez: float = t_pt.get("line_end_z", 0.0)
				var is_torp: bool = caliber >= 500.0
				var line_color: Color
				if is_torp:
					line_color = Color(0.0, lerpf(0.5, 1.0, urgency), 1.0, lerpf(0.4, 0.9, urgency))
				else:
					line_color = Color(1.0, lerpf(0.9, 0.0, urgency), 0.0, lerpf(0.4, 0.9, urgency))
				var draw_y: float = 5.0
				Debug.draw_line(Vector3(sx, draw_y, sz), Vector3(ex, draw_y, ez), line_color)
				# Small sphere at the center for reference
				Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 4.0, line_color)
			else:
				var color = Color(0.0, lerpf(0.5, 1.0, urgency), 1.0, lerpf(0.3, 0.8, urgency))
				Debug.draw_circle(Vector3(landing_x, 5.0, landing_z), 60.0, color)
				Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 6.0, color)

	# --- m) Cover debug (circles + LOS lines) — only for CA behavior ---
	if behavior is CABehavior:
		var ca: CABehavior = behavior as CABehavior
		if ca._cover_zone_valid and ca._cover_island_radius > 0.0:
			var island_pos = ca._cover_island_center
			var draw_y = 6.0

			# Island radius circle (orange)
			Debug.draw_circle(Vector3(island_pos.x, draw_y, island_pos.z), ca._cover_island_radius, Color(1.0, 0.5, 0.0, 0.3), 64)

			# Safe distance circle (red) — ship clearance + buffer
			var ship_clearance: float = movement.ship_beam * 0.5 + 50.0
			var safe_dist = ship_clearance + 50.0
			Debug.draw_circle(Vector3(island_pos.x, draw_y + 1.0, island_pos.z), safe_dist, Color(1.0, 0.15, 0.15, 0.7), 64)

			# Cover zone circle (color depends on state)
			var zone_color: Color
			var spotted_in_cover = ca.is_in_cover and _ship.visible_to_enemy
			if spotted_in_cover:
				zone_color = Color(1.0, 0.0, 0.0, 0.8)
			elif ca.is_in_cover:
				zone_color = Color(0.0, 1.0, 0.0, 0.8)
			else:
				zone_color = Color(0.0, 0.7, 1.0, 0.6)

			Debug.draw_circle(Vector3(ca._nav_destination.x, draw_y + 2.0, ca._nav_destination.z), ca._cover_zone_radius, zone_color, 48)
			Debug.draw_im_sphere(Vector3(ca._nav_destination.x, 30.0, ca._nav_destination.z), 20.0, zone_color)

			# LOS lines from ship to each threat
			var threats: Array = behavior._gather_threat_positions(_ship)
			var ship_los_pos = _ship.global_position
			for threat_pos in threats:
				var blocked = NavigationMapManager.is_los_blocked(ship_los_pos, threat_pos)
				var los_color = Color(0.0, 1.0, 0.0, 0.6) if blocked else Color(1.0, 0.0, 0.0, 0.8)
				Debug.draw_line(Vector3(ship_los_pos.x, 25.0, ship_los_pos.z), Vector3(threat_pos.x, 25.0, threat_pos.z), los_color)

	# --- n) CA tactical: enemy clusters + nearby islands ---
	if server_node != null:
		var clusters = server_node.get_enemy_clusters(_ship.team.team_id)
		for cluster in clusters:
			var center: Vector3 = cluster.center
			var ship_count: int = cluster.ships.size()
			var sphere_size: float = 30.0 + ship_count * 15.0
			Debug.draw_im_sphere(Vector3(center.x, 38.0, center.z), sphere_size, Color(1.0, 0.2, 0.0, 0.7))
			var cluster_radius: float = 300.0 + ship_count * 200.0
			Debug.draw_circle(Vector3(center.x, 8.0, center.z), cluster_radius, Color(1.0, 0.3, 0.0, 0.4), 32)

		# Nearby islands
		if NavigationMapManager.is_map_ready():
			var islands = NavigationMapManager.get_islands()
			var my_pos = _ship.global_position
			for isl in islands:
				var center_2d: Vector2 = isl["center"]
				var isl_pos = Vector3(center_2d.x, 0.0, center_2d.y)
				var isl_radius: float = isl["radius"]
				var eff_dist = isl_pos.distance_to(my_pos) - isl_radius
				if eff_dist <= 10000.0:
					Debug.draw_circle(Vector3(isl_pos.x, 9.0, isl_pos.z), isl_radius, Color(0.0, 0.8, 0.9, 0.35), 48)
					Debug.draw_im_sphere(Vector3(isl_pos.x, 28.0, isl_pos.z), 15.0, Color(0.0, 0.9, 1.0, 0.6))

	# --- o) Shell obstacles (drawn as threat lines) ---
	for s in _debug_shell_obstacles:
		var landing_x: float = s.get("landing_x", 0.0)
		var landing_z: float = s.get("landing_z", 0.0)
		var time_remaining: float = s.get("time_remaining", 0.0)
		var caliber: float = s.get("caliber", 0.0)
		var urgency: float = clampf(1.0 - (time_remaining / 10.0), 0.0, 1.0)
		var color = Color(1.0, lerpf(0.9, 0.0, urgency), 0.0, lerpf(0.4, 0.9, urgency))
		# Draw the threat line using landing velocity direction and threat_half_len
		var vx: float = s.get("landing_vx", 0.0)
		var vz: float = s.get("landing_vz", 0.0)
		var spd: float = sqrt(vx * vx + vz * vz)
		var half_len: float = s.get("threat_half_len", 15.0)
		if spd > 1e-6 and half_len > 1.0:
			var dir_x: float = vx / spd
			var dir_z: float = vz / spd
			# Line trails backward from landing point and extends 15m past it
			var overshoot: float = 15.0
			var sx: float = landing_x - dir_x * half_len * 2.0
			var sz: float = landing_z - dir_z * half_len * 2.0
			var ex: float = landing_x + dir_x * overshoot
			var ez: float = landing_z + dir_z * overshoot
			var draw_y: float = 5.0
			Debug.draw_line(Vector3(sx, draw_y, sz), Vector3(ex, draw_y, ez), color)
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 5.0, color)
		else:
			# Fallback: draw as a circle if no velocity data
			var radius: float = clampf(caliber * 0.2, 30.0, 120.0)
			Debug.draw_circle(Vector3(landing_x, 5.0, landing_z), radius, color)
			Debug.draw_im_sphere(Vector3(landing_x, 15.0, landing_z), 8.0, color)

	# --- q) World-space label (nav state + skill info) ---
	if behavior != null:
		var lines: PackedStringArray = PackedStringArray()

		var state_names = ["NORMAL", "EMERGENCY"]
		if navigator != null:
			var state_idx = navigator.get_nav_state()
			if state_idx >= 0 and state_idx < state_names.size():
				lines.append("Nav: %s" % state_names[state_idx])
			else:
				lines.append("Nav: UNKNOWN(%d)" % state_idx)

		var skill_info = behavior.get_debug_skill_info()
		if not skill_info.is_empty():
			var skill: String      = skill_info.get("skill", "")
			var threat: float      = skill_info.get("threat", -1.0)
			var visible: bool      = skill_info.get("visible", false)
			var in_cover: bool     = skill_info.get("in_cover", false)
			var hp_pct: int        = skill_info.get("hp_pct", -1)
			var torp_reload: float = skill_info.get("torp_reload", -1.0)

			# Line 1 — skill + threat bar
			if not skill.is_empty():
				var threat_bar := ""
				if threat >= 0.0:
					var filled := int(round(threat * 10.0))
					threat_bar = " [" + "█".repeat(filled) + "░".repeat(10 - filled) + "] %.2f" % threat
				lines.append("Skill: %s%s" % [skill, threat_bar])

			# Line 2 — target class, name, distance
			if target != null:
				var cls := ""
				match target.ship_class:
					Ship.ShipClass.BB: cls = "BB"
					Ship.ShipClass.CA: cls = "CA"
					Ship.ShipClass.DD: cls = "DD"
				var dist_m := int(_ship.global_position.distance_to(target.global_position))
				var dist_str := "%.1fk" % (dist_m / 1000.0) if dist_m >= 1000 else "%dm" % dist_m
				lines.append("→ %s %s  ·  %s" % [cls, target.name, dist_str])

			# Line 3 — status flags
			var flags: PackedStringArray = PackedStringArray()
			if hp_pct >= 0:
				flags.append("HP:%d%%" % hp_pct)
			flags.append("VISIBLE" if visible else "HIDDEN")
			if in_cover:
				flags.append("COVER")
			lines.append(" · ".join(flags))

			# Line 4 — torpedo reload (only for ships that have torpedoes)
			if torp_reload >= 0.0:
				var filled := int(round(torp_reload * 10.0))
				var bar := "█".repeat(filled) + "░".repeat(10 - filled)
				lines.append("Torps: [%s] %d%%" % [bar, int(torp_reload * 100.0)])

		var label_text = "\n".join(lines)
		if not label_text.is_empty():
			Debug.draw_label(_ship.global_position + Vector3(-100, 100, 0), label_text)


## Sample SDF tiles near the ship and emit draw_square commands for each.
func _emit_sdf_tiles(clearance: float) -> void:
	var nav_map = NavigationMapManager.get_map()
	if nav_map == null:
		return
	var cell_size: float = nav_map.get_cell_size_value()
	if cell_size <= 0.0:
		return

	var world_pos = _ship.global_position
	var half_range: float = 1000.0
	var start_x: float = snappedf(world_pos.x - half_range, cell_size)
	var start_z: float = snappedf(world_pos.z - half_range, cell_size)
	var end_x: float = world_pos.x + half_range
	var end_z: float = world_pos.z + half_range
	var tile_size: float = cell_size * 0.9

	var cx: float = start_x
	while cx <= end_x:
		var cz: float = start_z
		while cz <= end_z:
			var dist: float = nav_map.get_distance(cx, cz)
			# Only draw tiles near land — skip deep open water
			if dist < clearance * 3.0:
				var color: Color
				if dist < -clearance:
					# Deep inside land — black
					color = Color(0.1, 0.1, 0.1, 0.35)
				elif dist < 0.0:
					# Inside land — solid red
					color = Color(0.9, 0.1, 0.1, 0.35)
				elif dist < clearance:
					# Too close for this ship — orange/yellow gradient
					var t: float = dist / clearance
					color = Color(1.0, 0.3 + t * 0.5, 0.0, 0.3)
				else:
					# Navigable — green, more transparent the further from land
					var t: float = clampf((dist - clearance) / (clearance * 2.0), 0.0, 1.0)
					color = Color(0.0, 0.7, 0.3, 0.25 - t * 0.15)
				Debug.draw_square(Vector3(cx, 3.0, cz), tile_size, tile_size, color, true)
			cz += cell_size
		cx += cell_size


## Get the debug heading vector (for local access by camera)
func get_debug_heading_vector() -> Vector3:
	return _debug_desired_heading_vector

## Get the heading + rudder vector (current heading with rudder influence)
func get_debug_heading_rudder_vector() -> Vector3:
	return _debug_heading_rudder_vector

## Get waypoint position for debug drawing
func get_debug_waypoint() -> Vector3:
	return navigator.get_current_waypoint()

## Get destination position for debug drawing
func get_debug_destination() -> Vector3:
	return destination

## Get the navigation path for debug drawing
func get_debug_nav_path() -> PackedVector3Array:
	return navigator.get_current_path()

## Get the forward-simulated path for debug drawing (physics-validated path to target)
func get_debug_simulated_path() -> PackedVector3Array:
	return navigator.get_simulated_path()

## Get the predicted trajectory for debug drawing
func get_debug_predicted_trajectory() -> PackedVector3Array:
	return navigator.get_predicted_trajectory()

## Get the threat vector for debug drawing (points toward obstacles)
func get_debug_threat_vector() -> Vector3:
	return _debug_threat_vector

## Get the threat weight (0.0 = no threat, 1.0 = maximum threat)
func get_debug_threat_weight() -> float:
	return _debug_threat_weight

## Get the current throttle value for debug visualization (-1 = reverse, 0 = stopped, 1-4 = forward)
func get_debug_throttle() -> int:
	return _debug_throttle

## Get the safe vector for debug drawing (opposite of threat, the escape direction)
func get_debug_safe_vector() -> Vector3:
	return _debug_safe_vector

## Returns simulation points for debug visualization (V3 compat — returns predicted arc)
func get_turn_simulation_points_desired() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for pt in navigator.get_predicted_trajectory():
		points.append(pt)
	return points

## Returns empty array (V3 compat — threat points no longer computed via raycasts)
func get_turn_simulation_points_undesired() -> Array[Vector3]:
	return _debug_turn_sim_points_undesired

## Return cached shell obstacle data for debug visualization
func get_debug_shell_obstacles() -> Array:
	return _debug_shell_obstacles

## Return torpedo virtual threat points (generated procedurally by the navigator)
func get_debug_torpedo_threat_points() -> Array:
	return navigator.get_debug_torpedo_threat_points()

## Get nav state as a human-readable string
func get_nav_state_string() -> String:
	var state_names = [
		"NORMAL", "EMERGENCY"
	]
	var state_idx = navigator.get_nav_state()
	if state_idx >= 0 and state_idx < state_names.size():
		return state_names[state_idx]
	return "UNKNOWN"


# ===========================================================================
# V3 COMPATIBILITY STUBS
# ===========================================================================

## These methods exist so that systems that reference BotControllerV3's interface
## (e.g. camera debug drawing, server queries) don't break when V4 is used.

## No-op: V4 doesn't use navigation agents or proxies
func assign_nav_agent(_map: Node) -> void:
	pass

## No-op: V4 doesn't need deferred proxy setup
func defer_target() -> void:
	pass
