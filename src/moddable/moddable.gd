extends Resource
class_name Moddable

## Shared template data lives on the original Resource (set in the editor).
## Per-ship runtime state (base, static_mod, dynamic_mod) is created by
## instantiate() and lives on a COPY — so the template is never mutated and
## never needs resource_local_to_scene.

# ── runtime mod layers (only populated on instantiated copies) ──────────────
var base: Moddable        ## immutable snapshot of the template
var static_mod: Moddable  ## copy that static mods (upgrades) write to
var dynamic_mod: Moddable ## copy that dynamic mods (skills, consumables) write to

# ── internal bookkeeping ────────────────────────────────────────────────────
var _is_instance: bool = false   ## true on copies returned by instantiate()
var _is_mod_copy: bool = false   ## true on base / static_mod / dynamic_mod copies

const _RUNTIME_PROP_NAMES := {
	&"base": true,
	&"static_mod": true,
	&"dynamic_mod": true,
	&"_is_instance": true,
	&"_is_mod_copy": true,
}
static var _copy_property_cache: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
#  Deep-ish copy that catches EVERY script-defined variable, not just @export.
#  • duplicate(true) handles @export properties + deep-copies sub-resources.
#  • We then patch in every non-Resource script var that duplicate() missed.
# ─────────────────────────────────────────────────────────────────────────────
func create_copy() -> Moddable:
	var copy: Moddable = duplicate(true)

	for prop_name in _copy_property_names():
		var val = get(prop_name)

		# Skip Resource values — duplicate(true) already deep-copied the
		# exported ones, and we don't want to overwrite them with shared refs.
		if val is Resource:
			continue

		_set_copied_value(copy, prop_name, val)

	copy._is_mod_copy = true
	return copy

func copy_values_from(source: Moddable) -> void:
	for prop_name in source._copy_property_names():
		_set_copied_value(self, prop_name as StringName, source.get(prop_name))

func _copy_property_names() -> Array:
	var script: Script = get_script()
	var cache_key: String = script.resource_path
	if _copy_property_cache.has(cache_key):
		return _copy_property_cache[cache_key]

	var names: Array = []
	for prop in get_property_list():
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue

		var prop_name: StringName = prop.name
		if _RUNTIME_PROP_NAMES.has(prop_name):
			continue
		names.append(prop_name)

	_copy_property_cache[cache_key] = names
	return names

func _set_copied_value(target: Moddable, prop_name: StringName, val) -> void:
	if val is Resource:
		if val.get_script() != null or val.resource_path == "" or val.resource_path.contains("::"):
			target.set(prop_name, val.duplicate(true))
		else:
			target.set(prop_name, val)
	elif val is Array:
		target.set(prop_name, val.duplicate())
	elif val is Dictionary:
		target.set(prop_name, val.duplicate())
	else:
		target.set(prop_name, val)


# ─────────────────────────────────────────────────────────────────────────────
#  Create a per-ship runtime instance from this (shared) template.
#
#  Returns a NEW Moddable whose concrete type matches the template (e.g.
#  HPParams, GunParams …) with independent base / static_mod / dynamic_mod.
#
#  Usage in each manager's _ready():
#      params = params.instantiate(ship)        # one-liner replacement
#
#  The original @export var keeps pointing at the shared template in the scene
#  file — but after this line, `params` is a per-ship copy that is safe to
#  mutate without resource_local_to_scene.
# ─────────────────────────────────────────────────────────────────────────────
func instantiate(ship: Ship) -> Moddable:
	var inst: Moddable = create_copy()
	inst._is_instance = true
	inst._is_mod_copy = false

	inst.base        = self  # template is never mutated, so a direct ref is safe
	inst.static_mod  = create_copy()
	inst.dynamic_mod = create_copy()

	ship.reset_mods.connect(inst.reset)
	ship.reset_dynamic_mods.connect(inst.reset_dynamic_mod)

	return inst

# ─────────────────────────────────────────────────────────────────────────────
#  Mod-layer helpers  (same public API as before)
# ─────────────────────────────────────────────────────────────────────────────

## Called when static mods are reapplied (Ship.reset_mods signal).
func reset() -> void:
	static_mod.copy_values_from(base)
	dynamic_mod.copy_values_from(base)

## Called when only dynamic mods need refreshing (Ship.reset_dynamic_mods signal).
func reset_dynamic_mod() -> void:
	dynamic_mod.copy_values_from(static_mod)

## Returns the "effective" parameters — the dynamic_mod layer with all mods baked in.
func p() -> Moddable:
	return dynamic_mod

# ─────────────────────────────────────────────────────────────────────────────
#  Backward-compat shim — prints a one-time warning so you can migrate callers
#  at your own pace.  Remove once every call site uses instantiate().
# ─────────────────────────────────────────────────────────────────────────────
func init(_ship: Ship) -> void:
	push_warning("Moddable.init() is deprecated — use  params = params.instantiate(ship)  instead.")
	# Replicate the old behaviour: mutate self in-place (requires local-to-scene)
	if resource_path != "" and not resource_local_to_scene:
		push_error("Moddable.init() requires resource_local_to_scene when called on a scene resource. " +
				   "Switch to instantiate() to remove this requirement.")

	base        = create_copy()
	static_mod  = create_copy()
	dynamic_mod = create_copy()
	_is_instance = true

	_ship.reset_mods.connect(self.reset)
	_ship.reset_dynamic_mods.connect(self.reset_dynamic_mod)
