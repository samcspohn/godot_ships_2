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


# ─────────────────────────────────────────────────────────────────────────────
#  Deep-ish copy that catches EVERY script-defined variable, not just @export.
#  • duplicate(true) handles @export properties + deep-copies sub-resources.
#  • We then patch in every non-Resource script var that duplicate() missed.
# ─────────────────────────────────────────────────────────────────────────────
func create_copy() -> Moddable:
	var copy: Moddable = duplicate(true)

	for prop in get_property_list():
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue

		var prop_name: String = prop.name
		# Never copy runtime mod-system internals
		if prop_name in ["base", "static_mod", "dynamic_mod",
						  "_is_instance", "_is_mod_copy"]:
			continue

		var val = get(prop_name)

		# Skip Resource values — duplicate(true) already deep-copied the
		# exported ones, and we don't want to overwrite them with shared refs.
		if val is Resource:
			continue

		# For Arrays / Dictionaries, make a shallow copy so the two instances
		# don't share the same container object.
		if val is Array:
			copy.set(prop_name, val.duplicate())
		elif val is Dictionary:
			copy.set(prop_name, val.duplicate())
		else:
			copy.set(prop_name, val)

	copy._is_mod_copy = true
	return copy


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

	inst.base       = create_copy()
	inst.static_mod = create_copy()
	inst.dynamic_mod = create_copy()

	ship.reset_mods.connect(inst.reset)
	ship.reset_dynamic_mods.connect(inst.reset_dynamic_mod)
	return inst


# ─────────────────────────────────────────────────────────────────────────────
#  Mod-layer helpers  (same public API as before)
# ─────────────────────────────────────────────────────────────────────────────

## Called when static mods are reapplied (Ship.reset_mods signal).
func reset() -> void:
	static_mod  = base.create_copy()
	dynamic_mod = base.create_copy()

## Called when only dynamic mods need refreshing (Ship.reset_dynamic_mods signal).
func reset_dynamic_mod() -> void:
	dynamic_mod = static_mod.create_copy()

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
