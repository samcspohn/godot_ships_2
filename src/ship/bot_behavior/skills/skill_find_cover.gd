class_name SkillFindCover
extends BotSkill

var _target_island_id: int = -1
var _target_island_pos: Vector3 = Vector3.ZERO
var _target_island_radius: float = 0.0
var _nav_destination: Vector3 = Vector3.ZERO
var _nav_destination_valid: bool = false
var _cover_recalc_ms: int = 0
var _last_in_range_ms: int = 0
var _arrived: bool = false
var can_shoot: bool = false
var _dist_to_dest: float = 0.0

# Spotted-position stamp: recorded when the ship arrives at cover but is still
# visible to the enemy.  Candidate positions must also block LOS to this point
# so the ship doesn't just shuffle between two equally exposed spots.
var _spotted_stamp_pos: Vector3 = Vector3.ZERO
var _spotted_stamp_ms: int = 0
const SPOTTED_STAMP_DURATION_MS: int = 60000


func execute(ctx: SkillContext, params: Dictionary, prioritize_cover: bool = false) -> NavIntent:
	var ship = ctx.ship
	var target = ctx.target
	var desired_range = params.get("desired_range", ship.artillery_controller.get_params()._range * 0.6)
	var recalc_cooldown = params.get("recalc_cooldown_ms", 3000)
	var push_timeout = params.get("push_timeout_ms", 20000)

	# Track in-range enemies
	var gun_range = ship.artillery_controller.get_params()._range
	for enemy in ctx.server.get_valid_targets(ship.team.team_id):
		if enemy.global_position.distance_to(ship.global_position) <= gun_range:
			_last_in_range_ms = Time.get_ticks_msec()
			break

	# Push timeout: change island after N seconds without in-range targets
	if _nav_destination_valid and Time.get_ticks_msec() - _last_in_range_ms > push_timeout:
		_nav_destination_valid = false
		_last_in_range_ms = Time.get_ticks_msec()

	# Spotted-position stamping: if arrived but still visible, record where we
	# were spotted so future candidate evaluation blocks LOS to this point too.
	if _arrived and ship.visible_to_enemy:
		_spotted_stamp_pos = ship.global_position
		_spotted_stamp_ms = Time.get_ticks_msec()

	# Expire the stamp after 60 seconds
	if _spotted_stamp_pos != Vector3.ZERO and Time.get_ticks_msec() - _spotted_stamp_ms > SPOTTED_STAMP_DURATION_MS:
		_spotted_stamp_pos = Vector3.ZERO
		_spotted_stamp_ms = 0

	# Build the spotted position to pass down (Vector3.ZERO means none)
	var active_spotted_pos: Vector3 = _spotted_stamp_pos

	# Find new island if needed
	if not _nav_destination_valid:
		var island = ctx.behavior._get_cover_position(desired_range, target, prioritize_cover, _arrived, active_spotted_pos)
		if island.is_empty():
			return null  # No cover available — caller falls back
		_set_island(island)

	# Periodically recalc cover position
	var now_ms = Time.get_ticks_msec()
	if now_ms - _cover_recalc_ms >= recalc_cooldown:
		_cover_recalc_ms = now_ms
		var island = ctx.behavior._get_cover_position(desired_range, target, prioritize_cover, _arrived, active_spotted_pos)
		if not island.is_empty():
			_set_island(island)
		elif not _nav_destination_valid:
			return null  # No cover available and no previous destination to fall back on

	# Approach / station-keep
	var dist = ship.global_position.distance_to(_nav_destination)
	_dist_to_dest = dist
	var clearance = ctx.behavior._get_ship_clearance()
	var arrival_radius = clearance * 2.0
	var exit_radius = clearance * 3.5
	_arrived = dist < exit_radius if _arrived else dist < arrival_radius

	var heading = ctx.behavior._tangential_heading(_target_island_pos, _nav_destination)

	# Check shootability (shell arc over terrain)
	can_shoot = false
	var check_pos = ship.global_position if _arrived else _nav_destination
	var shell_params = ship.artillery_controller.get_shell_params()
	if shell_params != null:
		for enemy in ctx.server.get_valid_targets(ship.team.team_id):
			if not is_instance_valid(enemy) or not enemy.health_controller.is_alive():
				continue
			var tgt = enemy.global_position + ctx.behavior.target_aim_offset(enemy)
			if check_pos.distance_to(tgt) > gun_range:
				continue
			var sol = ProjectilePhysicsWithDragV2.calculate_launch_vector(check_pos, tgt, shell_params)
			if sol[0] == null:
				continue
			var result = Gun.sim_can_shoot_over_terrain_static(check_pos, sol[0], sol[1], shell_params, ship)
			if result.can_shoot_over_terrain:
				can_shoot = true
				break

	if _arrived:
		var intent = NavIntent.create(_nav_destination, heading, arrival_radius * 0.5)
		intent.near_terrain = true
		return intent

	var intent = NavIntent.create(_nav_destination, heading)
	intent.near_terrain = true
	return intent


func _set_island(island: Dictionary) -> void:
	_target_island_id = island["id"]
	_target_island_pos = island["center"]
	_target_island_radius = island["radius"]
	_nav_destination = island["dest"]
	_nav_destination_valid = true
	if _last_in_range_ms == 0:
		_last_in_range_ms = Time.get_ticks_msec()


func is_complete(ctx: SkillContext) -> bool:
	return _arrived

func get_dist() -> float:
	return _dist_to_dest

func reset() -> void:
	_target_island_id = -1
	_nav_destination_valid = false
	_arrived = false
	can_shoot = false
	_spotted_stamp_pos = Vector3.ZERO
	_spotted_stamp_ms = 0
