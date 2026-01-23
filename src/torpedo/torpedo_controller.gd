extends Node
class_name TorpedoController

@export var params: TorpedoLauncherParams
@export var launchers: Array[TorpedoLauncher] = []
var aim_point: Vector3 = Vector3.ZERO
var _ship: Ship
var spread: float = 0.0

var weapons: Array[Turret]:
	get:
		var arr: Array[Turret] = []
		for l in launchers:
			arr.append(l)
		return arr


func get_weapon_ui() -> Array[Button]:
	var button = Button.new()
	button.text = "TP"
	button.pressed.connect(func():
		print("Pressed TorpedoController")
		_ship.get_node("Modules/PlayerControl").current_weapon_controller = self
	)
	return [button]

func to_bytes() -> PackedByteArray:
	return params.dynamic_mod.to_bytes()

func from_bytes(b: PackedByteArray) -> void:
	params.dynamic_mod.from_bytes(b)

func _ready() -> void:
	_ship = get_parent().get_parent() as Ship
	params.init(_ship)
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

func get_params() -> TorpedoLauncherParams:
	return params.dynamic_mod as TorpedoLauncherParams

func get_torp_params() -> TorpedoParams:
	return get_params().torpedo_params as TorpedoParams
