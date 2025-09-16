extends Resource
class_name Moddable

#var mods: Array
var base: Moddable
var static_mod: Moddable
@export var dynamic_mod: Moddable

func _apply_mods() -> void:
	pass

# first perform self = base.duplicate(true)
func init(_ship: Ship) -> void:
	base = self
	static_mod = base.duplicate(true)
	dynamic_mod = static_mod.duplicate(true)

	_ship.reset_mods.connect(self.reset)
	_ship.reset_dynamic_mods.connect(self.reset_dynamic_mod)

# then apply any static mods to static_mod
# self = static_mod.duplicate(true)
func reset() -> void:
	print("reset moddable")
	static_mod = base.duplicate(true)
	dynamic_mod = static_mod.duplicate(true)

func reset_dynamic_mod() -> void:
	dynamic_mod = static_mod.duplicate(true)

func params() -> Variant:
	return dynamic_mod
