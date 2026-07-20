extends Skill

## Dead Eye — BB only.
## Sniping-focused: tighter dispersion and flatter shell trajectories at every
## range, paid for with slower reload and slower turret traverse. There is no
## range gate: you get the benefit whether you're sniping at 20 km or brawling
## at 6 km, so the skill never pushes you out of the fight — it just rewards
## patient, aimed shots over rapid-fire engagements.

const spread_mod        = 0.9   # -10% main gun dispersion
# const shell_speed_mod   = 1.05   # +5% shell velocity (both shell types)
const reload_mod        = 1.05   # +10% reload time (slower fire)
const traverse_mod      = 0.9   # -15% turret traverse speed

func _init():
	name = "Dead Eye"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.BB]
	flavor_text = "Trade rate-of-fire for precision — sniping or brawling, every shell flies straighter."
	tooltip_stats = [
		{"stat": "Main Gun Dispersion", "value": fmt_mult_pct(spread_mod), "positive": true},
		# {"stat": "Shell Velocity", "value": fmt_mult_pct(shell_speed_mod), "positive": true},
		{"stat": "Main Gun Reload", "value": fmt_mult_pct(reload_mod), "positive": false},
		{"stat": "Turret Traverse", "value": fmt_mult_pct(traverse_mod), "positive": false},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	main.max_h_disp     *= spread_mod
	main.max_v_disp     *= spread_mod
	main.reload_time     *= reload_mod
	main.traverse_speed  *= traverse_mod
	# if main.shell1:
	# 	main.shell1.speed *= shell_speed_mod
	# 	if main.shell1.type == ShellParams.ShellType.AP:
	# 		main.shell1.penetration_modifier *= 0.95
	# if main.shell2:
	# 	main.shell2.speed *= shell_speed_mod
