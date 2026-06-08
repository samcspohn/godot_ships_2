extends Skill

## IFHE (Improved Fuze and High Explosive) — all classes, Tier 2.
## Improved fuze and cap design penetrates thinner deck armor at the cost of
## reduced fire-starting potential. Applies to all HE shells in main battery
## and all secondary sub-controllers.

const PEN_MOD:  float = 1.30   # +30% HE penetration
const FIRE_MOD: float = 0.60   # -40% HE fire buildup

func _init() -> void:
	skill_id = "ifhe"
	name = "IFHE"
	tier = 2
	cost = 2
	flavor_text = "Improved fuze and cap design penetrates thinner deck armor at the cost of fire risk."
	tooltip_stats = [
		{"stat": "HE Penetration",   "value": fmt_mult_pct(PEN_MOD),  "positive": true},
		{"stat": "HE Fire Buildup",  "value": fmt_mult_pct(FIRE_MOD), "positive": false},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	for shell: ShellParams in [main.shell1, main.shell2]:
		if shell == null:
			continue
		if shell.type == ShellParams.ShellType.HE:
			shell.penetration_modifier *= PEN_MOD
			shell.fire_buildup         *= FIRE_MOD

	for sec: SecSubController in ship.secondary_controller.sub_controllers:
		var params := sec.params.dynamic_mod as GunParams
		for shell: ShellParams in [params.shell1, params.shell2]:
			if shell == null:
				continue
			if shell.type == ShellParams.ShellType.HE:
				shell.penetration_modifier *= PEN_MOD
				shell.fire_buildup         *= FIRE_MOD
