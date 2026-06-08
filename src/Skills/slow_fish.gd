extends Skill

## Slow Fish — DD / CA, mutually exclusive with Swift Fish.
## Heavier warheads with bigger flooding chance, but slower in the water and
## easier for lookouts to spot incoming.

const speed_mod      = 0.90   # -10% torpedo speed
const damage_mod     = 1.15   # +15% torpedo damage
const flood_mod      = 1.20   # +20% flood buildup
const detection_mod  = 1.15   # +15% torpedo detection range (enemies see them sooner)

func _init():
	name = "Slow Fish"
	tier = 2
	cost = 2
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	exclusive_group = "torpedo_tuning"
	flavor_text = "Bigger warheads, longer fuses. They take their time getting there."
	tooltip_stats = [
		{"stat": "Torpedo Damage", "value": fmt_mult_pct(damage_mod), "positive": true},
		{"stat": "Flood Buildup", "value": fmt_mult_pct(flood_mod), "positive": true},
		{"stat": "Torpedo Speed", "value": fmt_mult_pct(speed_mod), "positive": false},
		{"stat": "Torpedo Detection Range", "value": fmt_mult_pct(detection_mod), "positive": false},
	]

func _a(ship: Ship) -> void:
	if ship.torpedo_controller == null:
		return
	var tl := ship.torpedo_controller.params.dynamic_mod as TorpedoLauncherParams
	if tl.torpedo_params == null:
		return
	tl.torpedo_params.speed_knts      *= speed_mod
	tl.torpedo_params.damage          *= damage_mod
	tl.torpedo_params.flood_buildup   *= flood_mod
	tl.torpedo_params.detection_range *= detection_mod
