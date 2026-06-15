extends Skill

## Incoming Fire Alert — all classes, Tier 1.
## Shows a red indicator when enemy shells are inbound.

var indicator: Control = null
var _show_alert: bool = false

# var shells: Dictionary = {} # shell_id : time_remaining
func _init() -> void:
	skill_id = "ifa"
	name = "Incoming Fire Alert"
	tier = 1
	cost = 1
	flavor_text = "Sensors alert the crew when enemy shells are inbound."
	tooltip_stats = [
		{"stat": "Incoming Fire Indicator", "value": "shell flight time > 5s (placeholder)"},
	]

func _a(_ship: Ship) -> void:
	pass

func _proc(_delta: float) -> void:
	var my_team_id: int = _ship.team.team_id if _ship.team else -1
	var my_pos_2d := Vector2(_ship.global_position.x, _ship.global_position.z)

	var shells: Array = ProjectileManager.get_shells_near_position(
		my_pos_2d, 500, my_team_id
	)

	_show_alert = false
	var projectiles = ProjectileManager.get_projectiles()
	for s in shells:
		var sid := s["shell_id"] as int
		var pdata = projectiles[sid]
		if pdata != null:
			var start_time = pdata.get_start_time()
			var flight_time = s["time_remaining"] as float
			var elapsed_time = ProjectileManager.get_current_time() - start_time
			if flight_time > 4.0 and elapsed_time < 2.0: # show for shells with >5s flight time that were just fired
				_show_alert = true
				break

	# _show_alert = shells.size() > 0

func init_ui(container: Control):
	indicator = container

func update_ui(_container: Control):
	if indicator:
		indicator.visible = _show_alert

func to_bytes() -> PackedByteArray:
	var _data := super.to_bytes()
	var writer = StreamPeerBuffer.new()
	writer.put_8(1 if _show_alert else 0)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	super.from_bytes(data)
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	_show_alert = reader.get_u8() > 0
