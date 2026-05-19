extends Upgrade
class_name TorpedoMod1

const RELOAD_MOD: float = 0.85

func _init() -> void:
	upgrade_id = "torp_mod_1"
	name = "Torpedo Mod 1"
	description = "Reduces torpedo reload time by 15%."
	tier = 3
	icon = preload("res://icons/health-normal (1).png")
	flavor_text = "Streamlined loading gear cycles torpedoes back into the tubes faster."
	tooltip_stats = [
		{"stat": "Torpedo Reload", "value": fmt_mult_pct(0.85), "positive": true},
	]

func _a(_ship: Ship) -> void:
	if _ship.torpedo_controller == null:
		return
	(_ship.torpedo_controller.params.static_mod as TorpedoLauncherParams).reload_time *= RELOAD_MOD
