extends Upgrade

## Torpedo Tubes Mod 4 — Rank 4.
## The defining torpedo pick: stacks with the Rank 2 Torpedo Reload Boost
## (and Slow/Swift Fish skills) for a torp-spam DD or CA. Won't help ships
## that don't have tubes.

const reload_mod = 0.90   # -10% torp reload

func _init():
	upgrade_id = "torp_mod_4"
	name = "Torpedo Tubes Mod 4"
	description = "Reduces torpedo reload time by 10%."
	icon = preload("res://icons/health-normal (1).png")
	tier = 4

func _a(_ship: Ship) -> void:
	if _ship.torpedo_controller == null:
		return
	(_ship.torpedo_controller.params.static_mod as TorpedoLauncherParams).reload_time *= reload_mod
