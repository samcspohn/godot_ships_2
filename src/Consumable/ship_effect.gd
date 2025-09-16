# src/effects/ship_effect.gd
extends Node
class_name ShipEffect

var ship: Ship
var remaining_duration: float
var effect_active: bool = false

func setup(target_ship: Ship, duration: float):
	ship = target_ship
	remaining_duration = duration
	activate_effect()

func _ready():
	effect_active = true

func _process(delta):
	if effect_active:
		remaining_duration -= delta
		if remaining_duration <= 0:
			deactivate_effect()

func activate_effect():
	# Override in specific effects
	pass

func deactivate_effect():
	effect_active = false
	# Override in specific effects
	queue_free()
