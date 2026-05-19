extends Skill

## Heavy Shell Expert — BB / CA.
## Boosts AP penetration and widens the auto-bounce cone on both main-gun
## shell slots. HE shells in either slot are ignored.

const PEN_MOD: float   = 1.05
const BOUNCE_DELTA: float = deg_to_rad(2.0)  # subtracted from auto_bounce angle

func _init() -> void:
	name = "Heavy Shell Expert"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.BB, Ship.ShipClass.CA]
	flavor_text = "Heavier charges, tighter fuses — AP shells hit harder and bite deeper."
	tooltip_stats = [
		{"stat": "AP Penetration",       "value": "+5%",  "positive": true},
		{"stat": "Auto-Bounce Angle",    "value": "-2°",  "positive": true},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	for shell: ShellParams in [main.shell1, main.shell2]:
		if shell == null:
			continue
		if shell.type != ShellParams.ShellType.AP:
			continue
		shell.penetration_modifier *= PEN_MOD
		shell.auto_bounce          -= BOUNCE_DELTA
