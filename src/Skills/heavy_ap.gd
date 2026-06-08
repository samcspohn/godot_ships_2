extends Skill

## Heavy AP — all classes, Tier 3.
## Heavier AP shells with improved penetrating charge deal greater damage on impact.

const DAMAGE_MOD: float = 1.075   # +7.5% AP damage

func _init() -> void:
	skill_id = "hap"
	name = "Heavy AP"
	tier = 3
	cost = 3
	flavor_text = "Heavier AP shells with improved penetrating charge deal greater damage on impact."
	tooltip_stats = [
		{"stat": "AP Shell Damage", "value": fmt_mult_pct(DAMAGE_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	for shell: ShellParams in [main.shell1, main.shell2]:
		if shell == null:
			continue
		if shell.type == ShellParams.ShellType.AP:
			shell.damage *= DAMAGE_MOD
