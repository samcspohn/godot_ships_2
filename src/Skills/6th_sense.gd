extends Skill

## 6th sense — all classes, Tier 1.
## Shows a counter of enemy ships aiming at you

var indicator: Label = null
var _num_ships_aiming: int = 0

func _init() -> void:
	skill_id = "6_s"
	name = "sixth sense"
	tier = 1
	cost = 1
	flavor_text = "Advanced sensors provide a warning when enemy ships are aiming at you."
	tooltip_stats = [
		{"stat": "show number of enemies aiming at your ship", "value": ""},
	]

func _a(_ship: Ship) -> void:
	pass

func _proc(_delta: float) -> void:
	var my_team_id: int = _ship.team.team_id if _ship.team else -1
	var server = _ship.get_tree().root.get_node("Server") as GameServer
	if server == null:
		return

	_num_ships_aiming = 0
	var enemy_ships: Array = server._get_enemy_ships(my_team_id)
	for e: Ship in enemy_ships:
		if e.is_alive():
			var e_aim = e.artillery_controller.aim_point
			var my_pos = _ship.global_position
			if e_aim.distance_to(my_pos) < 500.0:
				_num_ships_aiming += 1

	# var my_pos_2d := Vector2(_ship.global_position.x, _ship.global_position.z)

	# var shells: Array = ProjectileManager.get_shells_near_position(
	# 	my_pos_2d, 500, my_team_id
	# )

	# _show_alert = false
	# var projectiles = ProjectileManager.get_projectiles()
	# for s in shells:
	# 	var sid := s["shell_id"] as int
	# 	var pdata = projectiles[sid]
	# 	if pdata != null:
	# 		var start_time = pdata.get_start_time()
	# 		var flight_time = s["time_remaining"] as float
	# 		var elapsed_time = ProjectileManager.get_current_time() - start_time
	# 		if flight_time > 4.0 and elapsed_time < 2.0: # show for shells with >5s flight time that were just fired
	# 			_show_alert = true
	# 			break

	# _show_alert = shells.size() > 0

func init_ui(container: Control):
	indicator = container

func update_ui(_container: Control):
	if indicator:
		indicator.visible = _num_ships_aiming > 0
		indicator.text = str(_num_ships_aiming)

func to_bytes() -> PackedByteArray:
	var _data := super.to_bytes()
	var writer = StreamPeerBuffer.new()
	writer.put_8(_num_ships_aiming)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	super.from_bytes(data)
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	_num_ships_aiming = reader.get_u8()
