extends Upgrade

## Concealment System Mod 1 — Tier 2.
## The stealth pick: shrinks your visibility radius. Competes with extra HP
## (Hull Mod 2), better acceleration (Propulsion Mod), and longer guns (GFCS).

const radius_mod = 0.93   # -7% concealment radius (smaller = harder to spot)

func _init():
	upgrade_id = "conceal_sys_1"
	name = "Concealment System Mod 1"
	description = "Reduces ship visibility (concealment radius) by 7%."
	icon = preload("res://icons/health-normal.png")
	tier = 3

func _a(_ship: Ship) -> void:
	var c := _ship.concealment.params.static_mod as ConcealmentParams
	c.radius *= radius_mod
