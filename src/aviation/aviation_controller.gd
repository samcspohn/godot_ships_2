extends WeaponController
class_name AviationController


@export var params: Array[AircraftParams] = [] # plane params
# Deck-wide (rather than per-squadron) aviation parameters - currently just the
# minimum spacing between takeoffs. Left unset in the scene, a default instance
# is created in _ready() so every carrier still gets a working flight deck.
@export var deck_params: AviationParams
@export var launcher: Node3D

var squadrons: Array[Squadron] = []
var active_squadrons: Dictionary[int, bool] = {}
var aim_point: Vector3
var fire_held: bool = false
var attack_point = null
var aim_direction: Vector2 = Vector2.ZERO
# Client-local only (never touched by set_fire_held's RPC path) - tracks the
# drag anchor for the live drop-pattern preview independently of the
# server-authoritative attack_point above, since that one is only ever reset
# to null inside the authority-gated block below and would otherwise go stale
# on every peer but the server. See update_local_drag_state().
var _preview_anchor: Vector3 = Vector3.ZERO
var _preview_holding: bool = false

var game_world: Node3D

# ── launch cooldowns ────────────────────────────────────────────────────────
# Authority-side timers. Seconds left on the deck-wide takeoff lockout started
# by the last launch (see launch_squadron), and, per squadron, seconds left of
# the ordnance reload started when it landed (see recall_squadron). A squadron
# may only launch once BOTH have run out - see can_launch().
var _launch_lockout: float = 0.0
var _reload_remaining: Array[float] = []
# Display state mirrored on every peer: for each squadron, seconds left on
# whichever of the two timers above is currently the longer one, and the full
# duration of that same timer so the UI can draw it as a fraction. Derived
# every tick from the authoritative timers on the server and replicated
# verbatim to clients (see to_bytes/from_bytes), which decay them locally
# between snapshots so the bars run smoothly.
var _cooldown_remaining: Array[float] = []
var _cooldown_total: Array[float] = []
# Aircraft each squadron has on strength. Replicated alongside the cooldowns
# rather than derived from the plane `dead` flags, which are only synced while a
# squadron is airborne - clients reconcile their parked squadrons against this
# count instead (see from_bytes and Squadron.set_alive_count).
var _alive_counts: Array[int] = []

# ── aircraft replacement ────────────────────────────────────────────────────
# Losses are made good over time rather than permanently. Per squadron: seconds
# left on the replacement currently being built, and the number of finished
# replacements parked and waiting for the squadron to land before they can join
# it. Every squadron builds in parallel with every other, but only one plane at
# a time within a squadron. _regen_remaining is replicated for the UI (and
# decayed locally between snapshots, same as the cooldowns).
var _regen_remaining: Array[float] = []
var _regen_pending: Array[int] = []

# What a squadron's progress bar is counting down, replicated alongside the
# timer itself so every peer colours the bar the same way (see
# get_button_cooldown_color).
enum Cooldown {
	NONE = 0,
	DECK = 1, # waiting on the flight deck: takeoff interval, or a replacement plane
	RELOAD = 2, # rearming after dropping its ordnance
	DEPLOYED = 3, # airborne, running down its fuel
}
var _cooldown_kind: Array[int] = []

# Airborne squadrons show their remaining sortie in cyan and rearming ones their
# rearm in red; everything else - the deck interval, a squadron waiting on a
# replacement plane - keeps the default yellow.
const DEPLOYED_COLOR := Color(0.25, 0.85, 1.0, COOLDOWN_ALPHA)
const RELOAD_COLOR := Color(1.0, 0.28, 0.22, COOLDOWN_ALPHA)

func _ready() -> void:
	multi_select = true
	_ship = get_parent().get_parent() as Ship
	game_world = _ship.get_parent() as Node3D
	if deck_params == null:
		deck_params = AviationParams.new()
	deck_params = deck_params.instantiate(_ship) as AviationParams
	# instantiate squadrons
	for i in range(params.size()):
		params[i] = params[i].instantiate(_ship) as AircraftParams
		tool_tips.append(func () -> String:
			var p = params[i].p()
			var text := "%s\nRange: %.1f\nSpeed: %.1f\nReload: %.0fs" % [p.type, p._range, p.speed, p.ordnance_reload_time]
			text += "\nPlanes: %d/%d" % [get_alive_count(i), squadrons[i].aircraft.size()]
			if get_regen_remaining(i) > 0.0:
				text += "\nNew plane in: %.0fs" % get_regen_remaining(i)
			if get_regen_pending(i) > 0:
				text += "\n+%d joining on landing" % get_regen_pending(i)
			if squadrons[i].active:
				text += "\nFuel: %.0fs" % squadrons[i].fuel_remaining
			else:
				var remaining := get_cooldown_remaining(i)
				if remaining > 0.0:
					var label := "Rearming" if _cooldown_kind[i] == Cooldown.RELOAD else "Ready in"
					text += "\n%s: %.0fs" % [label, remaining]
			return text
		)
		button_names.append(params[i].type)
		_reload_remaining.append(0.0)
		_cooldown_remaining.append(0.0)
		_cooldown_total.append(0.0)
		_alive_counts.append((params[i].p() as AircraftParams).squadron_size)
		_regen_remaining.append(0.0)
		_regen_pending.append(0)
		_cooldown_kind.append(Cooldown.NONE)

		var squadron := Squadron.new()
		squadron.setup(params[i], launcher, _ship, game_world)
		squadrons.append(squadron)

	shell_index = 0
	set_physics_process(true)
	set_process(true)


# Runs every physics tick (fixed rate). Ground/waypoint marker raycasts need
# the physics thread (PhysicsDirectSpaceState3D is unavailable during
# _process()), and flight simulation/attack commits need to stay in lockstep
# with update_flight delta - both remain here. The reticle/committed
# drop-pattern preview used to also live here, but it has no raycast
# dependency anymore (see Aircraft.make_flat_marker) and was visibly
# lagging behind the mouse since physics ticks and render frames are not
# 1:1 - it now runs in _process below instead.
func _physics_process(delta: float) -> void:
	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		squadron._update_ground_indicator()
		squadron._update_waypoint_indicators()

	_tick_regen(delta)
	_tick_cooldowns(delta)

	if not _Utils.authority():
		return

	if shell_index >= params.size():
		shell_index = 0

	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		if not squadron.active:
			continue
		squadron.update_flight(delta, _ship)
		if squadron.all_finished_attack() or squadron.all_dead():
			recall_squadron(i)

	assert(multi_select)
	if attack_point != null and not fire_held: # release ordnance at drop point
		for sh_index in shell_indices:
			if sh_index >= squadrons.size():
				continue
			var squadron := squadrons[sh_index]
			aim_direction = _drag_direction(attack_point, aim_point, _direction_to(_ship.global_position, attack_point))
			squadron.set_attack(Vector2(attack_point.x, attack_point.z), aim_direction)
		attack_point = null
		aim_direction = Vector2.ZERO

# Runs every rendered frame (not gated to authority) so the drop-pattern
# preview tracks the mouse/aim_point smoothly instead of lagging behind at
# the physics tick rate. Purely visual - see Squadron.update_reticle_preview
# and Squadron.update_committed_attack_preview.
func _process(delta: float) -> void:
	super._process(delta)
	var is_local_selection: bool = _ship.control is PlayerController and _ship.control.current_weapon_controller == self
	for i in range(squadrons.size()):
		var squadron = squadrons[i]
		# always show drop-pattern preview allowing for drop point updates
		_update_drop_preview(squadron, is_local_selection and i in shell_indices)
		# show committed drop-pattern
		if squadron.attack_point != null:
			squadron.update_committed_attack_preview()
			# squadron.update_reticle_preview(false, Vector2.ZERO, Vector2.ZERO)

# Live aiming preview: while held (dragging out an attack), the pattern
# freezes at the point the drag started and rotates to track the drag
# direction, matching what will be committed on release (see
# update_local_drag_state() for how the anchor itself is tracked). Otherwise
# it just follows the cursor, facing away from the ship. Either way the
# facing is clamped to Squadron.MAX_ATTACK_ANGLE either side of the
# ship-to-target line.
func _update_drop_preview(squadron: Squadron, show: bool) -> void:
	if not show:
		squadron.update_reticle_preview(false, Vector2.ZERO, Vector2.ZERO)
		return

	var center: Vector3
	var direction: Vector2
	if _preview_holding:
		center = _preview_anchor
		direction = _drag_direction(_preview_anchor, aim_point, _direction_to(_ship.global_position, _preview_anchor))
	else:
		center = aim_point
		direction = _direction_to(_ship.global_position, aim_point)
	# Run the drag through the same clamp set_attack() applies on commit, so the
	# reticle stops rotating at the cone edge instead of promising an approach
	# angle the squadron will not actually fly.
	direction = Squadron.clamp_attack_direction(
		direction,
		Vector2(center.x, center.z),
		Vector2(_ship.global_position.x, _ship.global_position.z))
	squadron.update_reticle_preview(true, Vector2(center.x, center.z), direction)

# Called directly (not via rpc) by the local player's PlayerController every
# frame so the preview anchor updates instantly instead of waiting on a
# server round-trip. Purely client-side visual state - the actual attack
# commit still goes through set_fire_held()/attack_point below. On release
# the reticle immediately resumes following the cursor (see
# _update_drop_preview() above) rather than waiting on the server to
# confirm the attack - once it does (squadron.attack_point becomes
# non-null), the committed drop-pattern preview takes over instead (see
# _process() and Squadron.update_committed_attack_preview()).
func update_local_drag_state(holding: bool) -> void:
	if holding and not _preview_holding:
		_preview_anchor = aim_point
	_preview_holding = holding

# Direction of the current mouse drag away from `anchor`, or `fallback` if the
# drag hasn't moved far enough to be meaningful (e.g. a tap instead of a
# drag).
static func _drag_direction(anchor: Vector3, current: Vector3, fallback: Vector2) -> Vector2:
	var offset := Vector2(current.x - anchor.x, current.z - anchor.z)
	if offset.length() > 10.0:
		return offset.normalized()
	return fallback

static func _direction_to(from: Vector3, to: Vector3) -> Vector2:
	var offset := Vector2(to.x - from.x, to.z - from.z)
	if offset.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	return offset.normalized()


# ── launch cooldowns ────────────────────────────────────────────────────────

# Runs on every peer. The authority owns the timers and derives the display
# state from them; everyone else just decays the last replicated display value
# so the UI bars keep moving between snapshots instead of stepping down once
# per network update (from_bytes overwrites them again the moment one lands).
func _tick_cooldowns(delta: float) -> void:
	if not _Utils.authority():
		for i in range(_cooldown_remaining.size()):
			_cooldown_remaining[i] = maxf(_cooldown_remaining[i] - delta, 0.0)
		return

	_launch_lockout = maxf(_launch_lockout - delta, 0.0)
	var takeoff_interval: float = maxf((deck_params.p() as AviationParams).min_takeoff_interval, 0.001)
	for i in range(_reload_remaining.size()):
		_reload_remaining[i] = maxf(_reload_remaining[i] - delta, 0.0)
		_alive_counts[i] = squadrons[i].alive_count()
		var plane_params := params[i].p() as AircraftParams
		if squadrons[i].active:
			# Airborne: the bar is the sortie itself running out, not a wait.
			_cooldown_remaining[i] = squadrons[i].fuel_remaining
			_cooldown_total[i] = maxf(plane_params.fuel_time, 0.001)
			_cooldown_kind[i] = Cooldown.DEPLOYED
			continue
		# Show whichever timer is actually holding the squadron on deck, along
		# with the full duration of that same timer so the bar reads as a
		# fraction of the wait the player is currently sitting through.
		var remaining := 0.0
		var total := 0.0
		var kind: int = Cooldown.NONE
		if _launch_lockout > remaining:
			remaining = _launch_lockout
			total = takeoff_interval
			kind = Cooldown.DECK
		if _reload_remaining[i] > remaining:
			remaining = _reload_remaining[i]
			total = maxf(plane_params.ordnance_reload_time, 0.001)
			kind = Cooldown.RELOAD
		# A squadron with nothing left to fly is waiting on the production line
		# rather than on the deck, so count down to its next plane instead.
		if _alive_counts[i] == 0 and _regen_remaining[i] > remaining:
			remaining = _regen_remaining[i]
			total = maxf(plane_params.plane_regen_time, 0.001)
			kind = Cooldown.DECK
		_cooldown_remaining[i] = remaining
		_cooldown_total[i] = total
		_cooldown_kind[i] = kind

# Rebuilds lost aircraft, one at a time per squadron and all squadrons at once.
# A plane shot down goes onto the line the moment it is lost - the squadron does
# not have to land first - but a replacement finished while the squadron is
# airborne has to wait on deck for it to come home (see recall_squadron).
# Clients just decay the replicated timer so the tooltip keeps counting down
# between snapshots.
func _tick_regen(delta: float) -> void:
	if not _Utils.authority():
		for i in range(_regen_remaining.size()):
			_regen_remaining[i] = maxf(_regen_remaining[i] - delta, 0.0)
		return

	for i in range(squadrons.size()):
		var squadron := squadrons[i]
		# Planes the squadron is still short, not counting the ones already
		# built and parked waiting for it to land.
		var missing: int = squadron.aircraft.size() - squadron.alive_count() - _regen_pending[i]
		if missing <= 0:
			_regen_remaining[i] = 0.0
			continue
		if _regen_remaining[i] <= 0.0:
			# Nothing on the line yet (or the last one just rolled off) - start
			# the next plane. Sequential within the squadron: only ever one.
			_regen_remaining[i] = maxf((params[i].p() as AircraftParams).plane_regen_time, 0.001)
		_regen_remaining[i] = maxf(_regen_remaining[i] - delta, 0.0)
		if _regen_remaining[i] > 0.0:
			continue
		if squadron.active:
			_regen_pending[i] += 1
		else:
			squadron.revive_one()

# Seconds until this squadron's next replacement plane is ready, or 0 if it is
# at full strength. Valid on every peer (see _tick_regen and to_bytes).
func get_regen_remaining(index: int) -> float:
	if index < 0 or index >= _regen_remaining.size():
		return 0.0
	return _regen_remaining[index]

# Replacement planes built while this squadron was airborne, waiting on deck to
# join it once it lands. Valid on every peer.
func get_regen_pending(index: int) -> int:
	if index < 0 or index >= _regen_pending.size():
		return 0
	return _regen_pending[index]

# Authority-side launch gate: a squadron has to be on deck, rearmed, and clear
# of the deck-wide takeoff lockout left by the last launch.
func can_launch(index: int) -> bool:
	if index < 0 or index >= squadrons.size():
		return false
	if squadrons[index].active:
		return false
	# Nothing left to put up - the squadron stays grounded until a replacement
	# plane has been built for it (see _tick_regen).
	if squadrons[index].all_dead():
		return false
	if _launch_lockout > 0.0:
		return false
	return _reload_remaining[index] <= 0.0

# Seconds left before this squadron may launch. Valid on every peer (see
# _tick_cooldowns) so the UI and tooltips read the same value the server does.
func get_cooldown_remaining(index: int) -> float:
	if index < 0 or index >= _cooldown_remaining.size():
		return 0.0
	return _cooldown_remaining[index]

# 0..1 share of the current cooldown still to run - what the yellow bar on the
# squadron button draws. 0 exactly when the squadron is ready to launch.
func get_cooldown_fraction(index: int) -> float:
	if index < 0 or index >= _cooldown_remaining.size():
		return 0.0
	var total: float = _cooldown_total[index]
	if total <= 0.0:
		return 0.0
	return clampf(_cooldown_remaining[index] / total, 0.0, 1.0)

# Aircraft this squadron has on strength; 0 means it is grounded until its next
# replacement plane is built. Valid on every peer (see _tick_cooldowns and
# to_bytes/from_bytes).
func get_alive_count(index: int) -> int:
	if index < 0 or index >= _alive_counts.size():
		return 0
	return _alive_counts[index]

# Client-safe view of can_launch() - the timers themselves only exist on the
# authority, but their replicated display state says the same thing.
func is_launch_ready(index: int) -> bool:
	if index < 0 or index >= squadrons.size():
		return false
	if squadrons[index].active:
		return false
	if get_alive_count(index) <= 0:
		return false
	return get_cooldown_remaining(index) <= 0.0

# WeaponController UI hooks - drives the yellow cooldown bar and the dimmed
# look on squadrons that cannot be put up yet.
func get_button_cooldown(index: int) -> float:
	return get_cooldown_fraction(index)

func get_button_cooldown_color(index: int) -> Color:
	if index < 0 or index >= _cooldown_kind.size():
		return COOLDOWN_COLOR
	match _cooldown_kind[index]:
		Cooldown.DEPLOYED:
			return DEPLOYED_COLOR
		Cooldown.RELOAD:
			return RELOAD_COLOR
	return COOLDOWN_COLOR

func is_button_ready(index: int) -> bool:
	if index < 0 or index >= squadrons.size():
		return false
	# An airborne squadron is not launchable, but its button is still live: it
	# is how the player selects it to give it orders. Only a squadron stuck on
	# deck reads as unavailable.
	return squadrons[index].active or is_launch_ready(index)


func launch_squadron(index: int) -> void:
	if index >= squadrons.size():
		return
	squadrons[index].launch(game_world, launcher.global_position, launcher.global_rotation)
	active_squadrons[index] = true
	# Putting aircraft up reveals the carrier to the enemy for a few seconds.
	# Authority-only: clients run this same call while replaying the server's
	# squadron snapshot (see from_bytes), so without the gate every peer would
	# re-report the launch against its own local clock.
	if _Utils.authority():
		var server = _ship.get_node_or_null("/root/Server")
		if server != null:
			server.report_aircraft_launch(_ship)
		# Nothing else leaves the deck until the next takeoff slot comes round.
		_launch_lockout = (deck_params.p() as AviationParams).min_takeoff_interval

func recall_squadron(index: int) -> void:
	if active_squadrons.has(index):
		squadrons[index].recall(launcher)
		active_squadrons.erase(index)
		if _Utils.authority() and index < _reload_remaining.size():
			# Replacements built while the squadron was up were parked on deck
			# waiting for it; now that it is home they join the formation.
			for _i in range(_regen_pending[index]):
				squadrons[index].revive_one()
			_regen_pending[index] = 0
			# Back on deck. Rearming is only owed for ordnance actually dropped:
			# a squadron that came home still loaded is waiting on nothing but
			# the next free takeoff slot.
			if squadrons[index].ordnance_spent:
				_reload_remaining[index] = (params[index].p() as AircraftParams).ordnance_reload_time
			else:
				_reload_remaining[index] = 0.0

# Replaying the server's snapshot on a client: the squadron is already up as
# far as the authority is concerned, so this deliberately skips the cooldown
# gate ensure_launched() applies to genuine launch commands.
func _replay_launch(index: int) -> void:
	if index >= squadrons.size():
		return
	if not squadrons[index].active:
		launch_squadron(index)

func ensure_launched(index: int) -> void:
	if index >= squadrons.size():
		return
	if not squadrons[index].active and can_launch(index):
		launch_squadron(index)

func get_aim_ui() -> Dictionary:
	if active_squadrons.size() == 0:
		return {
			"terrain_hit": false,
			"penetration_power": 0.0,
			"time_to_target": 0.0
		}
	if shell_index >= params.size():
		shell_index = 0
	var squadron := squadrons[shell_index]
	var plane_params := params[shell_index]
	var dist = squadron.node.global_position.distance_to(aim_point)
	var speed: float = plane_params.p().speed
	var ui := {
		"terrain_hit": false,
		"penetration_power": 0.0,
		"time_to_target": dist / speed
	}
	return ui

func get_shell_params():
	return null

func get_params() -> AircraftParams:
	if shell_index >= params.size():
		return null
	return params[shell_index]

func get_max_range() -> float:
	return get_params()._range

func set_aim_input(point: Vector3) -> void:
	var ship_pos := _ship.global_position
	ship_pos.y = 0.0
	var offset := Vector3(point.x - ship_pos.x, 0.0, point.z - ship_pos.z)
	var max_range := get_max_range()
	if offset.length() > max_range:
		offset = offset.normalized() * max_range
	aim_point = ship_pos + offset

@rpc("any_peer", "call_remote")
func fire_all() -> void:
	pass

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
	if not active_squadrons.has(shell_index) and can_launch(shell_index):
		launch_squadron(shell_index)

# Sends the selected squadron to the current aim point without attacking;
# launches it first if it isn't airborne yet (mirrors fire_next_ready()).
# append lets the player queue up a multi-leg route (spacebar modifier)
# instead of replacing the current waypoint.
@rpc("any_peer", "call_remote")
func set_waypoint_at_aim(append: bool) -> void:
	for sh_index in shell_indices:
		if sh_index >= squadrons.size():
			continue
		if not active_squadrons.has(sh_index):
			if not can_launch(sh_index):
				continue
			launch_squadron(sh_index)
		squadrons[sh_index].set_waypoint(Vector2(aim_point.x, aim_point.z), append)

@rpc("any_peer", "call_remote")
func set_fire_held(held: bool) -> void:
	if !fire_held and held and attack_point == null:
		attack_point = aim_point
	fire_held = held



func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	# Launch cooldowns for every squadron, airborne or not - the buttons have to
	# show the wait on squadrons that are not in the active list below.
	writer.put_u8(squadrons.size())
	for i in range(squadrons.size()):
		writer.put_float(_cooldown_remaining[i])
		writer.put_float(_cooldown_total[i])
		writer.put_u8(_alive_counts[i])
		writer.put_float(_regen_remaining[i])
		writer.put_u8(_regen_pending[i])
		writer.put_u8(_cooldown_kind[i])
	writer.put_u8(active_squadrons.size())
	for index in active_squadrons.keys():
		var squadron = squadrons[index]
		writer.put_u8(index)
		writer.put_u8(squadron.aircraft.size())
		writer.put_var(squadron.node.global_position)
		writer.put_var(squadron.node.global_rotation)
		writer.put_var(squadron.idle_pos)
		writer.put_var(squadron.attack_point)
		writer.put_var(squadron.attack_direction)
		writer.put_u8(1 if squadron.holding_attack else 0)
		writer.put_u8(1 if squadron.in_attack_run else 0)
		writer.put_u8(1 if squadron.returning else 0)
		writer.put_u8(1 if squadron.in_landing_approach else 0)
		writer.put_float(squadron.fuel_remaining)
		writer.put_u8(squadron.waypoints.size())
		for wp in squadron.waypoints:
			writer.put_var(wp)
		for plane in squadron.aircraft:
			writer.put_var(plane.global_position)
			writer.put_var(plane.global_rotation)
			writer.put_float(plane.hp)
			writer.put_u8(1 if plane.dead else 0)
		writer.put_var(params[index].to_bytes())
	return writer.data_array

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	for squadron in squadrons:
		for plane in squadron.aircraft:
			plane.visible = false

	var cooldown_count = reader.get_u8()
	for i in range(cooldown_count):
		var remaining = reader.get_float()
		var total = reader.get_float()
		var alive = reader.get_u8()
		var regen = reader.get_float()
		var pending = reader.get_u8()
		var kind = reader.get_u8()
		if i < _cooldown_remaining.size():
			_cooldown_remaining[i] = remaining
			_cooldown_total[i] = total
			_alive_counts[i] = alive
			_regen_remaining[i] = regen
			_regen_pending[i] = pending
			_cooldown_kind[i] = kind

	var seen_indices: Dictionary[int, bool] = {}
	var active_count = reader.get_u8()
	for i in range(active_count):
		var index = reader.get_u8()
		seen_indices[index] = true
		var plane_count = reader.get_u8()
		var squadron_pos = reader.get_var()
		var squadron_rot = reader.get_var()
		var squadron_idle_pos = reader.get_var()
		var squadron_attack_point = reader.get_var()
		var squadron_attack_direction = reader.get_var()
		var squadron_holding_attack = reader.get_u8()
		var squadron_in_attack_run = reader.get_u8()
		var squadron_returning = reader.get_u8()
		var squadron_in_landing_approach = reader.get_u8()
		var squadron_fuel_remaining = reader.get_float()
		var squadron_waypoint_count = reader.get_u8()
		var squadron_waypoints: Array[Vector2] = []
		for w in range(squadron_waypoint_count):
			squadron_waypoints.append(reader.get_var())
		_replay_launch(index)
		var squadron = squadrons[index] if index < squadrons.size() else null
		if squadron != null:
			squadron.node.global_position = squadron_pos
			squadron.node.global_rotation = squadron_rot
			squadron.idle_pos = squadron_idle_pos
			squadron.holding_attack = squadron_holding_attack != 0
			squadron.attack_direction = squadron_attack_direction
			squadron.attack_point = squadron_attack_point
			squadron.in_attack_run = squadron_in_attack_run != 0
			squadron.returning = squadron_returning != 0
			squadron.in_landing_approach = squadron_in_landing_approach != 0
			squadron.fuel_remaining = squadron_fuel_remaining
			squadron.waypoints = squadron_waypoints
		for j in range(plane_count):
			var plane_pos = reader.get_var()
			var plane_rot = reader.get_var()
			var plane_hp = reader.get_float()
			var plane_dead = reader.get_u8()
			if squadron != null and j < squadron.aircraft.size():
				var plane = squadron.aircraft[j]
				plane.dead = plane_dead != 0
				plane.visible = not plane.dead
				# A replacement plane built between this client's last two
				# snapshots can still be parented to the launcher when the
				# squadron goes up, since Squadron.launch() skips the planes it
				# believes are dead - put it into the world with the rest.
				if not plane.dead and plane.get_parent() != game_world:
					plane.reparent(game_world)
					plane.set_physics_process(true)
					plane.set_hitbox_enabled(true)
				plane.global_position = plane_pos
				plane.global_rotation = plane_rot
				plane.hp = plane_hp
		if index < params.size():
			var params_bytes = reader.get_var()
			params[index].from_bytes(params_bytes)

	# A squadron missing from this snapshot but still marked active locally
	# means the server recalled it since the last update - replicate that
	# cleanup here since active_squadrons/active_count only ever tells us
	# what's currently active, never what just stopped being active.
	for index in range(squadrons.size()):
		if not seen_indices.has(index) and squadrons[index].active:
			squadrons[index].recall(launcher)
			active_squadrons.erase(index)
		# Parked squadrons never appear in the snapshot above, so their plane
		# `dead` flags would otherwise go stale as replacements are built on the
		# server. Only the head count matters on deck (see Squadron.launch), and
		# that is replicated - reconcile against it.
		if not squadrons[index].active:
			squadrons[index].set_alive_count(_alive_counts[index])
