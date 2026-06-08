extends Skill

## Swift Fish — DD / CA, mutually exclusive with Slow Fish.
## Faster torpedoes that close the gap before targets can react, at the cost of
## per-fish punch.

const speed_mod   = 1.10   # +10% torpedo speed
const damage_mod  = 0.90   # -10% torpedo damage

func _init():
	name = "Swift Fish"
	tier = 2
	cost = 2
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	exclusive_group = "torpedo_tuning"
	flavor_text = "Lighter warheads, hotter motors. Hits before they can dodge."
	tooltip_stats = [
		{"stat": "Torpedo Speed", "value": fmt_mult_pct(speed_mod), "positive": true},
		{"stat": "Torpedo Damage", "value": fmt_mult_pct(damage_mod), "positive": false},
	]

func _a(ship: Ship) -> void:
	if ship.torpedo_controller == null:
		return
	var tl := ship.torpedo_controller.params.dynamic_mod as TorpedoLauncherParams
	if tl.torpedo_params == null:
		return
	tl.torpedo_params.speed_knts *= speed_mod
	tl.torpedo_params.damage     *= damage_mod
