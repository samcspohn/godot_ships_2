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

## How a single property has to be transferred between mod layers.
enum _Kind {
	VALUE,   ## plain value (or CoW packed array) — direct set
	ARRAY,   ## Array — refill the target's array in place
	DICT,    ## Dictionary — refill the target's dict in place
	OBJECT,  ## needs a runtime check: shared ref vs. owned sub-resource
}

## Keyed by the Script object itself, not its path — an object key hashes by
## pointer, so the lookup stays cheap on the reset path.
static var _copy_plan_cache: Dictionary = {}
## Resource instance -> whether it is per-layer state rather than a shared asset.
static var _owned_resource_cache: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
#  Deep-ish copy that catches EVERY script-defined variable, not just @export.
#  • duplicate(true) handles @export properties + deep-copies sub-resources.
#  • We then patch in every non-Resource script var that duplicate() missed.
#
#  Only runs at instantiate() time, so it can afford to allocate.
# ─────────────────────────────────────────────────────────────────────────────
func create_copy() -> Moddable:
	var copy: Moddable = duplicate(true)

	for prop_name in _plan_all_names():
		var val = get(prop_name)

		if val is Resource:
			# duplicate(true) only deep-copies *embedded* sub-resources — one
			# stored in its own .tres (an ExtResource) comes back as a shared
			# reference, so every mod layer would write into the template file.
			# Give owned sub-resources their own copy here; shared library
			# assets (scriptless Curves, textures …) stay by reference.
			if _is_owned_resource(val):
				copy.set(prop_name, val.duplicate(true))
			continue

		if val is Array:
			copy.set(prop_name, val.duplicate())
		elif val is Dictionary:
			copy.set(prop_name, val.duplicate())
		else:
			copy.set(prop_name, val)

	copy._is_mod_copy = true
	return copy


# ─────────────────────────────────────────────────────────────────────────────
#  Restore this layer's values from another layer. Runs every time mods are
#  rebuilt, so it must not allocate: containers and owned sub-resources are
#  refilled in place instead of being duplicated. That also keeps any reference
#  someone cached (e.g. `params.p().shell1`) valid across a rebuild.
# ─────────────────────────────────────────────────────────────────────────────
func copy_values_from(source: Moddable) -> void:
	var plan: Array = source._copy_plan()

	# Fast path: the overwhelming majority of stat properties are plain scalars.
	for prop_name in plan[0]:
		set(prop_name, source.get(prop_name))

	for entry in plan[1]:
		var prop_name: StringName = entry[0]
		var src = source.get(prop_name)

		match entry[1]:
			_Kind.ARRAY:
				var dst = get(prop_name)
				if dst is Array and src is Array and not is_same(dst, src):
					dst.assign(src)
				else:
					set(prop_name, src.duplicate() if src is Array else src)
			_Kind.DICT:
				var dst = get(prop_name)
				if dst is Dictionary and src is Dictionary and not is_same(dst, src):
					dst.clear()
					dst.merge(src)
				else:
					set(prop_name, src.duplicate() if src is Dictionary else src)
			_:
				_copy_object_value(prop_name, src)


func _copy_object_value(prop_name: StringName, src) -> void:
	# Plain object refs (Nodes, managers) and shared library resources are
	# passed straight through — only owned sub-resources are per-layer state
	# that a mod may have written to.
	if not (src is Resource) or not _is_owned_resource(src):
		set(prop_name, src)
		return

	var dst = get(prop_name)
	if dst != null and not is_same(dst, src) and dst.get_script() == src.get_script():
		_copy_resource_in_place(dst, src)
	else:
		set(prop_name, src.duplicate(true))


## True when a Resource is per-layer state rather than a shared library asset.
## Memoised per instance: the underlying test does string work, and the reset
## path asks the same question about the same objects every time.
static func _is_owned_resource(res: Resource) -> bool:
	var cached = _owned_resource_cache.get(res)
	if cached != null:
		return cached
	var owned: bool = res.get_script() != null or res.resource_path == "" or res.resource_path.contains("::")
	_owned_resource_cache[res] = owned
	return owned


## Value-copies one plain Resource into another of the same script, without
## allocating. Used for sub-resources such as ShellParams.
static func _copy_resource_in_place(dst: Resource, src: Resource) -> void:
	var plan: Array = _plan_for(src)

	for prop_name in plan[0]:
		dst.set(prop_name, src.get(prop_name))

	for entry in plan[1]:
		var prop_name: StringName = entry[0]
		var val = src.get(prop_name)
		var sub = dst.get(prop_name)

		match entry[1]:
			_Kind.ARRAY:
				if sub is Array and val is Array and not is_same(sub, val):
					sub.assign(val)
				else:
					dst.set(prop_name, val.duplicate() if val is Array else val)
			_Kind.DICT:
				if sub is Dictionary and val is Dictionary and not is_same(sub, val):
					sub.clear()
					sub.merge(val)
				else:
					dst.set(prop_name, val.duplicate() if val is Dictionary else val)
			_:
				if val is Resource and _is_owned_resource(val):
					if sub != null and not is_same(sub, val) and sub.get_script() == val.get_script():
						_copy_resource_in_place(sub, val)
					else:
						dst.set(prop_name, val.duplicate(true))
				else:
					dst.set(prop_name, val)


## Built once per script, as [plain_names, special_entries]:
##   plain_names     — Array[StringName] copied with a bare get/set
##   special_entries — Array of [StringName, _Kind] needing container/resource care
## The kind comes from the declared property type rather than the current value,
## so a property that happens to be null at startup is still classified right.
static func _plan_for(obj: Object) -> Array:
	var script: Script = obj.get_script()
	var cached = _copy_plan_cache.get(script)
	if cached != null:
		return cached

	var plain: Array = []
	var special: Array = []
	for prop in obj.get_property_list():
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue

		var prop_name: StringName = prop.name
		if _RUNTIME_PROP_NAMES.has(prop_name):
			continue

		match prop.type:
			TYPE_ARRAY:
				special.append([prop_name, _Kind.ARRAY])
			TYPE_DICTIONARY:
				special.append([prop_name, _Kind.DICT])
			TYPE_OBJECT, TYPE_NIL:
				# TYPE_NIL means an untyped `var`, which may hold anything.
				special.append([prop_name, _Kind.OBJECT])
			_:
				plain.append(prop_name)

	var plan: Array = [plain, special]
	_copy_plan_cache[script] = plan
	return plan


func _copy_plan() -> Array:
	return _plan_for(self)


func _plan_all_names() -> Array:
	var plan: Array = _copy_plan()
	var names: Array = plan[0].duplicate()
	for entry in plan[1]:
		names.append(entry[0])
	return names


func _copy_property_names() -> Array:
	return _plan_all_names()


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
	# dynamic_mod is intentionally NOT refreshed here: Ship._update_static_mods()
	# always runs _update_dynamic_mods() straight after, which rebuilds it from
	# the freshly-modded static_mod. Copying from base first was pure waste.

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
