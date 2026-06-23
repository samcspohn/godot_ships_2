extends Node
class_name TorpedoController

@export var params: TorpedoLauncherParams
@export var launchers: Array[TorpedoLauncher] = []
var aim_point: Vector3 = Vector3.ZERO
var _ship: Ship
var spread: float = 0.0
var fire_held: bool = false
var sequential_fire_timer: float = 0.0
var sequential_fire_delay: float = 0.2 # Delay between sequential gun fires

var weapons: Array[Turret]:
	get:
		var arr: Array[Turret] = []
		for l in launchers:
			arr.append(l)
		return arr


func get_weapon_ui() -> Array[Button]:
	var button = Button.new()
	button.text = "TP"
	button.set_meta("tooltip_provider", func() -> String: return _build_tooltip_text())
	button.pressed.connect(func():
		print("Pressed TorpedoController")
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
	)
	return [button]

func get_shell_params() -> TorpedoParams:
	return null
func _build_tooltip_text() -> String:
	var tp := get_torp_params()
	var lp := get_params()
	var num_launchers := launchers.size()
	var lines := [
		"Torpedoes",
		"",
		"Launchers: %d" % num_launchers,
		"Reload: %.1f s" % lp.reload_time,
		"Range: %.1f km" % (lp._range / 1000.0),
		"Traverse: %.1f deg/s" % rad_to_deg(lp.traverse_speed),
		"",
		"Torpedo:",
		"  Damage: %d" % int(tp.damage),
		"  Speed: %.0f kt (%.1f m/s)" % [tp.speed_knts, tp.speed],
		"  Flood buildup: %.0f" % tp.flood_buildup,
		"  Detection range: %.0f m" % tp.detection_range,
		"  Arming distance: %.0f m" % tp.arming_distance,
	]
	return "\n".join(PackedStringArray(lines))

func get_aim_ui() -> Dictionary:
	var time_to_target = -1
	var penetration_power = -1
	var terrain_hit = false

	time_to_target = _ship.global_position.distance_to(aim_point) / get_torp_params().speed / TorpedoManager.TORPEDO_SPEED_MULTIPLIER

	return {
		"time_to_target": time_to_target,
		"penetration_power": penetration_power,
		"terrain_hit": terrain_hit
	}

func get_max_range() -> float:
	return get_params()._range

func to_bytes() -> PackedByteArray:
	return params.dynamic_mod.to_bytes()

func from_bytes(b: PackedByteArray) -> void:
	params.dynamic_mod.from_bytes(b)

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
	params = params.instantiate(_ship) as TorpedoLauncherParams

	# Sort launchers front-to-back in ship-local space (Godot forward is -Z,
	# smallest z = bow). Same scene on server and client, so gun_id assignments
	# stay consistent for fire RPCs and sync indices.
	launchers.sort_custom(func(a: TorpedoLauncher, b: TorpedoLauncher) -> bool:
		return a.get_parent().position.z < b.get_parent().position.z
	)

	var i = 0
	for l in launchers:
		l.gun_id = i
		l.controller = self
		l._ship = _ship
		i += 1

	if _Utils.authority():
		set_physics_process(true)
	else:
		set_physics_process(false)

func set_aim_input(target_point: Vector3) -> void:
	aim_point = target_point

func _physics_process(delta: float) -> void:

	for l in launchers:
		l._aim(aim_point, delta)

	if fire_held:
		sequential_fire_timer += delta
		var reload = get_params().reload_time
		var min_reload = reload / launchers.size() - 0.01
		var adjusted_sequential_fire_delay = min(sequential_fire_delay, min_reload)
		while sequential_fire_timer >= adjusted_sequential_fire_delay:
			sequential_fire_timer -= adjusted_sequential_fire_delay
			fire_next_ready()

@rpc("any_peer", "call_remote")
func fire_all() -> void:
	for launcher in launchers:
		if launcher.reload >= 1.0 and launcher.can_fire:
			launcher.fire()

@rpc("any_peer", "call_remote")
func fire_next_ready() -> void:
	for launcher in launchers:
		if launcher.reload >= 1.0 and launcher.can_fire:
			launcher.fire()
			return

@rpc("any_peer", "call_remote")
func set_fire_held(held: bool) -> void:
	fire_held = held


func get_params() -> TorpedoLauncherParams:
	return params.dynamic_mod as TorpedoLauncherParams

func get_torp_params() -> TorpedoParams:
	return get_params().torpedo_params as TorpedoParams
