class_name DamageExpectation

## What bots expect incoming damage to be, from the baked model corrected by what matches measured.
## `make learn` folds the per-match samples (GunneryCalibration) into TABLE_PATH; a cell with few
## samples leans on its class pair, and that on BotGunnery's static table.

const TABLE_PATH := "res://assets/damage_prior.json"
const RANGE_BAND_M := 2500.0
## Aspect off the target's bow, folded to 0-90: bow-on, angled, broadside.
const ASPECT_EDGES := [25.0, 65.0]
## Salvos a cell needs to count as much as its parent.
const PRIOR_SALVOS := 50.0
## Ends of the time slices a turn-out's fire is booked in.
const TURNOUT_SLICES_S := [15.0, 30.0, 60.0, 120.0, 300.0]
## Runs a turn-out cell needs to count as much as its parent.
const PRIOR_RUNS := 30.0
static var _turnout_cache: Dictionary = {}

static var _table: Dictionary = {}
static var _loaded := false
static var _fingerprints: Dictionary = {}


static func table() -> Dictionary:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(TABLE_PATH):
			var t = JSON.parse_string(FileAccess.get_file_as_string(TABLE_PATH))
			if t is Dictionary and int(t.get("bake", -1)) == BotGunnery.SOLVER_VERSION:
				_table = t
	return _table


static func range_band(range_m: float) -> int:
	return int(range_m / RANGE_BAND_M)


static func aspect_band(aspect_deg: float) -> int:
	if is_nan(aspect_deg):
		return -1
	var a: float = minf(aspect_deg, 180.0 - aspect_deg)
	return 0 if a < ASPECT_EDGES[0] else 1 if a < ASPECT_EDGES[1] else 2


static func class_name_of(ship: Ship) -> String:
	return Ship.ShipClass.keys()[mini(ship.ship_class, 2)]


## Share of the model's main-battery damage `shooter` lands on `target` at this range and aspect
## (NAN: any aspect).
static func salvo_factor(shooter: Ship, target: Ship, range_m: float, aspect_deg: float = NAN) -> float:
	var root: float = BotGunnery.static_calibration(shooter, target, range_m)
	var t := table()
	if t.is_empty():
		return root
	var b := range_band(range_m)
	var a := aspect_band(aspect_deg)
	var tail := "%d|%s" % [b, "*" if a < 0 else str(a)]
	var cls := _shrink((t.salvo_class as Dictionary).get("%s|%s|%s" % [class_name_of(shooter), class_name_of(target), tail], {}), root)
	return _shrink((t.salvo_pair as Dictionary).get("%s|%s|%s" % [shooter.ship_name, target.ship_name, tail], {}), cls)


## Per TURNOUT_SLICES_S slice, what `ship` doing `kind` ("turn", "astern") really takes over what SkillStance
## priced from shooters on it and from bystanders, and the mean damage from ships it did not price:
## [on factors, by factors, ambient]; empty without a learned table.
static func turnout(ship: Ship, kind: String) -> Array:
	var t := table()
	if t.is_empty():
		return []
	var key := "%s|%s" % [ship.ship_name, kind]
	if _turnout_cache.has(key):
		return _turnout_cache[key]
	var out := [[], [], []]
	for i in TURNOUT_SLICES_S.size():
		var cls: Dictionary = (t.turnout_class as Dictionary).get("%s|%s|%d" % [class_name_of(ship), kind, i], {})
		var hull: Dictionary = (t.turnout_hull as Dictionary).get("%s|%s|%d" % [ship.ship_name, kind, i], {})
		for j in 2:
			var real := "real_on" if j == 0 else "real_by"
			var pred := "pred_on" if j == 0 else "pred_by"
			out[j].append(_shrink_runs(hull, real, pred, _shrink_runs(cls, real, pred, 1.0)))
		out[2].append(_shrink_runs(hull, "real_other", "", _shrink_runs(cls, "real_other", "", 0.0)))
	_turnout_cache[key] = out
	return out


## `on` and `by` (per slice, as SkillStance prices them) as learned turn-outs say they land within
## `window_s`, plus the ships it did not price; their plain sum without a learned table.
static func price(ship: Ship, kind: String, on: Array, by: Array, window_s: float) -> float:
	var f := turnout(ship, kind)
	var sum := 0.0
	var lo := 0.0
	for i in TURNOUT_SLICES_S.size():
		var hi: float = TURNOUT_SLICES_S[i]
		if f.is_empty():
			sum += float(on[i]) + float(by[i])
		else:
			var covered: float = clampf((minf(window_s, hi) - lo) / (hi - lo), 0.0, 1.0)
			sum += float(on[i]) * float(f[0][i]) + float(by[i]) * float(f[1][i]) + float(f[2][i]) * covered
		lo = hi
	return sum


static func learned() -> bool:
	return not table().is_empty()


## Ratio real / pred of a turn-out cell (mean real per run when `pred` is ""), leaning on `parent` by runs.
static func _shrink_runs(cell: Dictionary, real: String, pred: String, parent: float) -> float:
	var n: float = float(cell.get("n", 0.0))
	if n <= 0.0:
		return parent
	var v: float
	if pred == "":
		v = float(cell.get(real, 0.0)) / n
	elif float(cell.get(pred, 0.0)) > 0.0:
		v = float(cell.get(real, 0.0)) / float(cell[pred])
	else:
		return parent
	var w: float = n / (n + PRIOR_RUNS)
	return w * v + (1.0 - w) * parent


static func _shrink(cell: Dictionary, parent: float) -> float:
	var n: float = float(cell.get("n", 0.0))
	var pred: float = float(cell.get("pred", 0.0))
	if n <= 0.0 or pred <= 0.0:
		return parent
	var w: float = n / (n + PRIOR_SALVOS)
	return w * float(cell.real) / pred + (1.0 - w) * parent


## Hash of what makes a hull shoot and take damage as it does: base gun, shell, dispersion, secondary,
## HP, movement and concealment parameters. A balance change changes it.
static func fingerprint(ship: Ship) -> String:
	var key := ship.scene_file_path
	if _fingerprints.has(key):
		return _fingerprints[key]
	var parts := PackedStringArray([key])
	var res: Array = []
	if ship.artillery_controller != null:
		res.append(ship.artillery_controller.params)
	if is_instance_valid(ship.secondary_controller):
		for sc in ship.secondary_controller.sub_controllers:
			res.append(sc.params)
	res.append(ship.health_controller.params)
	if ship.movement_controller != null:
		res.append(ship.movement_controller.params)
	if ship.concealment != null:
		res.append(ship.concealment.params)
	for r in res:
		_props(r.base if r is Moddable and r.base != null else r, parts, 0)
	var fp := "%08x" % ("|".join(parts)).hash()
	_fingerprints[key] = fp
	return fp


static func _props(r: Object, out: PackedStringArray, depth: int) -> void:
	if r == null or depth > 3:
		out.append("null")
		return
	for p in r.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE) or p.name in ["script", "resource_path", "resource_name",
				"resource_local_to_scene", "resource_scene_unique_id", "base", "static_mod", "dynamic_mod"]:
			continue
		var v = r.get(p.name)
		if v is Resource:
			_props(v, out, depth + 1)
		elif not (v is Object):
			out.append("%s=%s" % [p.name, v])
