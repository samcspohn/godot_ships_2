extends Upgrade

## Fire Prevention System — Rank 1.
## Raises the buildup threshold required to start a fire or flood, making
## ignition harder by ~5%. The defensive utility pick: not flashy, but
## consistently cuts incoming DoT damage over a match.

const resistance_bonus = 1.05   # +5% buildup threshold for both fire and flood

func _init():
	upgrade_id = "fire_prev_1"
	name = "Fire Prevention System"
	description = "Increases fire and flooding resistance by 5%."
	icon = preload("res://icons/health-normal.png")
	tier = 1

func _a(_ship: Ship) -> void:
	# Fire resistance lives on FireManager.rparams (ResistanceParams).
	var fr := _ship.fire_manager.rparams.static_mod as ResistanceParams
	fr.max_buildup *= resistance_bonus
	# Flood manager folds its resistance into FloodParams.max_buildup directly.
	var fl := _ship.flood_manager.params.static_mod as FloodParams
	fl.max_buildup *= resistance_bonus
