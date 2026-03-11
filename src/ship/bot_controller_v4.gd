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
var debug_draw_turn_sim: bool = true

var debug_log_interval: float = 2.0
var debug_log_timer: float = 0.0

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
## Frame offset for torpedo obstacle updates vs ship obstacle updates
const TORPEDO_UPDATE_OFFSET: int = 2
## ID namespace base for torpedo obstacles (negative, never collides with ship instance IDs)
const TORPEDO_ID_OFFSET: int = -100000

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

## When true, the next physics frame will force an immediate intent update
## regardless of the stagger timer.
var _force_intent_next_frame: bool = false

## Cooldown timer (seconds) to prevent event-driven triggers from firing
## more than once per second. Reset after each forced intent update.
var _event_cooldown: float = 0.0
const EVENT_COOLDOWN_DURATION: float = 1.0

## Cached average enemy position for centroid-shift detection.
var _cached_enemy_avg: Vector3 = Vector3.ZERO

## Last HP bracket (1-4) for threshold-crossing detection. -1 = uninitialized.
var _last_hp_bracket: int = -1

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
		movement.turn_speed_loss
	)

	# Initialize behavior
	behavior._ship = _ship
	add_child(behavior)

	# Defer the initial target acquisition so the scene tree is ready
	get_tree().create_timer(0.2).timeout.connect(_deferred_init)


func _deferred_init() -> void:
	# Re-check map in case it was built after our _ready
	if navigator != null and NavigationMapManager.is_map_ready():
		navigator.set_map(NavigationMapManager.get_map())

	# Set initial destination (forward from spawn)
	destination = _ship.global_position - _ship.global_transform.basis.z * 10000.0
	destination.y = 0.0


# ===========================================================================
# MAIN LOOP
# ===========================================================================

func _physics_process(delta: float) -> void:
	if _ship == null or movement == null or navigator == null:
		return

	# --- 1. Update navigator with current ship state ---
	navigator.set_state(
		_ship.global_position,
		_ship.linear_velocity,
		get_ship_heading(),
		_ship.angular_velocity.y,
		movement.rudder_input,
		get_current_speed(),
		delta
	)

	# --- 2. Update dynamic obstacles (other ships) ---
	if Engine.get_physics_frames() % OBSTACLE_UPDATE_INTERVAL == bot_id % OBSTACLE_UPDATE_INTERVAL:
		_update_obstacles()

	# --- 2c. Update torpedo obstacles (fast-moving threats) ---
	# Use an offset modulo so torpedo and ship updates don't fire on the same frame.
	var torp_frame_slot: int = (bot_id + TORPEDO_UPDATE_OFFSET) % OBSTACLE_UPDATE_INTERVAL
	if Engine.get_physics_frames() % OBSTACLE_UPDATE_INTERVAL == torp_frame_slot:
		_update_torpedo_obstacles()

	# --- 2b. Check for event-driven intent triggers ---
	# These run every frame (cheap checks) and set _force_intent_next_frame
	# when a significant tactical event occurs. Gated by cooldown to prevent
	# rapid re-firing from oscillating game state (e.g. enemies on concealment edge).
	if _event_cooldown > 0.0:
		_event_cooldown -= delta
	else:
		_check_intent_events()

	# --- 3. Get navigation intent from behavior ---
	_behavior_timer += delta
	if _force_intent_next_frame:
		should_query_behavior = true
		_force_intent_next_frame = false
		_event_cooldown = EVENT_COOLDOWN_DURATION
		_behavior_timer = 0.0
	elif _behavior_timer >= MAX_BEHAVIOR_INTERVAL:
		should_query_behavior = true
		_behavior_timer = 0.0

	if should_query_behavior and Engine.get_physics_frames() % 8 == bot_id % 8:
		should_query_behavior = false
		_update_nav_intent()

	# --- 4. Execute the current navigation intent ---
	_execute_nav_intent()

	# --- 5. Read steering output from navigator ---
	var rudder: float = navigator.get_rudder()
	var throttle: int = navigator.get_throttle()

	# --- 5b. Apply NavIntent throttle override ---
	# Behaviors can request a minimum throttle (e.g. CAs approaching cover at speed)
	# to prevent the navigator from decelerating too early.
	# Only apply when:
	#   - The navigator is NAVIGATING or AVOIDING (not ARRIVING/SETTLING/HOLDING)
	#   - The navigator is going forward (throttle >= 0) — never override reverse
	#   - The navigator isn't signaling collision — never force speed into an obstacle
	var nav_st: int = navigator.get_nav_state()
	var is_approach_phase: bool = nav_st >= 2  # ARRIVING(2), SETTLING(3), HOLDING(4)
	if _last_intent != null and _last_intent.throttle_override >= 0 and throttle >= 0 and not navigator.is_collision_imminent() and not is_approach_phase:
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
	if behavior.has_method("get_nav_intent"):
		new_intent = behavior.get_nav_intent(target, _ship, server_node)
	else:
		# Fallback: use the legacy get_desired_position interface
		# and wrap its result in a NavIntent.create
		var next_destination = behavior.get_desired_position(friendly, enemy, target, destination)
		if next_destination.distance_to(destination) > movement.turning_circle_radius * 0.5:
			destination = next_destination
		var approach_heading = calculate_desired_heading(destination)
		new_intent = NavIntent.create(destination, approach_heading)

		# Check if behavior wants to override heading for evasion
		if _ship.visible_to_enemy and behavior.has_method("get_desired_heading"):
			var heading_info = behavior.get_desired_heading(target, get_ship_heading(), 0.0, destination)
			if heading_info.get("use_evasion", false):
				# Override with evasion heading
				new_intent = NavIntent.create(destination, heading_info.heading)

	# --- Smart comparison: compare raw-to-raw to prevent oscillation ---
	if new_intent != null and _last_raw_intent != null and _is_intent_similar(_last_raw_intent, new_intent):
		_last_raw_intent = new_intent
		# Still update heading since that's cheap
		_last_intent.target_heading = new_intent.target_heading
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


# ===========================================================================
# BEHAVIOR TICK (target scanning, firing, consumables)
# ===========================================================================

func _tick_behavior(delta: float) -> void:
	# Target scanning
	target_scan_timer += delta
	var needs_rescan: bool = false
	if target_scan_timer >= target_scan_interval:
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

	var _dbg := int(_ship.name) < 1004

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
		# Also rescan target — the tactical picture changed so we may want
		# a different target (e.g. our target went hidden, pick a visible one).
		if target == null or (target is Ship and not target.visible_to_enemy):
			var old_target = target
			_acquire_target(target)
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
			if _dbg:
				print("[Event %s] COVER_LOST (overshoot) frame=%d" % [_ship.name, Engine.get_physics_frames()])
			_force_intent_next_frame = true
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
	debug_log_timer += 1.0 / Engine.physics_ticks_per_second
	if debug_log_timer >= debug_log_interval:
		debug_log_timer = 0.0
		# if _ship.name == "1001" or _ship.name == "1002" or _ship.name == "1003":
		# 	print("[BotV4 %s] %s" % [_ship.name, navigator.get_debug_info()])


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

## Get nav state as a human-readable string
func get_nav_state_string() -> String:
	var state_names = [
		"PLANNING", "NAVIGATING", "ARRIVING",
		"SETTLING", "HOLDING", "AVOIDING", "EMERGENCY"
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
