extends Skill

## Stealthy Fish — DD / CA, Tier 1.
## -20% torpedo detection range (enemies spot incoming torps later).

const DETECT_MOD := 0.80

func _init() -> void:
	name = "Stealthy Fish"
	tier = 1
	cost = 1
	allowed_classes = [Ship.ShipClass.DD, Ship.ShipClass.CA]
	flavor_text = "Silenced propulsion systems make the fish almost invisible."
	tooltip_stats = [
		{"stat": "Torpedo Detection Range", "value": fmt_mult_pct(DETECT_MOD), "positive": true},
	]

func _a(ship: Ship) -> void:
	if ship.torpedo_controller == null:
		return
	var tl := ship.torpedo_controller.params.dynamic_mod as TorpedoLauncherParams
	if tl.torpedo_params == null:
		return
	tl.torpedo_params.detection_range *= DETECT_MOD
