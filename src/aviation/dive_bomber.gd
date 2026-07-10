extends Aircraft
class_name DiveBomberAircraft

@export var shell_params: ShellParams

# Dispersion parameters normally supplied by GunParams - baked in here since a
# dive bomber has no gun/turret/target-mod to source them from.
@export var grouping: float = 1.8
@export var h_spread: float = 0.01
@export var v_spread: float = 0.005
@export var dispersion_curve: Curve = preload("res://src/artillary/default_dispersion.tres")
@export var max_dispersion: float = 270.0
@export var max_range: float = 3000.0  # used only to sample dispersion_curve (t = dist / max_range)

var _dispersion_calculator: DispersionCalculator

func _ready() -> void:
	_dispersion_calculator = DispersionCalculator.new()

# Drops a single HE shell straight down from wherever this aircraft currently
# is (its formation slot, spread out by the squadron for the attack run).
# Mirrors Gun.fire()'s dispersion + fireBullet usage, minus the gun/target-mod
# plumbing that doesn't apply to an aircraft-dropped bomb.
func fire_ordnance(_direction: Vector2) -> bool:

	var aim_point := Vector3(global_position.x, 0.0, global_position.z)
	for i in range(2):
		var dispersed_velocity: Variant = _dispersion_calculator.calculate_dispersed_launch(
				aim_point, global_position, shell_params,
				grouping, grouping, h_spread, v_spread,
				max_range, dispersion_curve, max_dispersion)
		if dispersed_velocity == null:
			return true
		var t = ProjectileManager.get_current_time()
		var id = ProjectileManager.fireBullet(dispersed_velocity, global_position, shell_params, t, _ship)
		TcpThreadPool.send_display_shell(id, global_position, dispersed_velocity, t, shell_params, self, true)
	return true
