extends Resource
class_name Moddable

#var mods: Array
var base: Moddable
var static_mod: Moddable
var dynamic_mod: Moddable

func _apply_mods() -> void:
	pass

func _init() -> void:
	self.resource_local_to_scene = true

# must be local to scene
func init(_ship: Ship) -> void:
	base = self
	static_mod = base.duplicate(true)
	dynamic_mod = static_mod.duplicate(true)

	_ship.reset_mods.connect(self.reset)
	_ship.reset_dynamic_mods.connect(self.reset_dynamic_mod)

func update_mods() -> void:
	static_mod = base.duplicate(true)
	dynamic_mod = static_mod.duplicate(true)

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
