extends Upgrade

## Secondary Battery Mod 4 — Rank 4.
## The defining secondary-build pick: meaningfully faster secondary reload on
## top of any Rank 1 Secondary Battery Upgrade you took. Lets brawler BBs and
## secondary-CAs put real DPS on the closer targets.

const reload_mod = 0.90   # -10% secondary reload

func _init():
	upgrade_id = "sec_mod_4"
	name = "Secondary Battery Mod 4"
	description = "Reduces secondary battery reload time by 10%."
	icon = preload("res://icons/auto-repair (1).png")
	tier = 4

func _a(_ship: Ship) -> void:
	for sec: SecSubController in _ship.secondary_controller.sub_controllers:
		(sec.params.static_mod as GunParams).reload_time *= reload_mod
