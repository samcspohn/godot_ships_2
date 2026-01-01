extends Resource
class_name Moddable

#var mods: Array
var base: Moddable
var static_mod: Moddable
var dynamic_mod: Moddable
var _is_copy: bool = false
var valid: bool = false

func _apply_mods() -> void:
	pass

func check_init() -> void:
	# Skip check on copies (static_mod, dynamic_mod)
	if _is_copy:
		return
	if base == null:
		var resource_type = get_script().get_global_name() if get_script() else "Unknown"
		push_error("Moddable resource not initialized! Resource path: " + resource_type)
	else:
		valid = true
		static_mod.valid = true
		dynamic_mod.valid = true

func _init():
	if not valid:
		check_init.call_deferred()

func duplicate_as_copy(mod: Moddable) -> Moddable:
	var copy = mod.duplicate(true)
	copy._is_copy = true
	return copy

# must be local to scene
func init(_ship: Ship) -> void:
	base = self
	static_mod = duplicate_as_copy(base)
	dynamic_mod = duplicate_as_copy(static_mod)

	_ship.reset_mods.connect(self.reset)
	_ship.reset_dynamic_mods.connect(self.reset_dynamic_mod)

func update_mods() -> void:
	static_mod = duplicate_as_copy(base)
	dynamic_mod = duplicate_as_copy(static_mod)

# then apply any static mods to static_mod
# self = static_mod.duplicate(true)
func reset() -> void:
	print("reset moddable")
	static_mod = duplicate_as_copy(base)
	dynamic_mod = static_mod.duplicate(true)

func reset_dynamic_mod() -> void:
	dynamic_mod = duplicate_as_copy(static_mod)

func params() -> Variant:
	return dynamic_mod
