extends VBoxContainer
class_name ShipStatsPanel

## Stats panel for the port main menu. Builds four collapsible accordion
## sections (Survivability, Artillery, Torpedo, Maneuverability) populated
## from the selected ship's controllers. Every stat reads from
## `params.dynamic_mod` so upgrade and skill effects show up automatically.
## Values that differ from `params.base` are highlighted green.

const EPS: float = 0.001

var _ship: Ship = null

@onready var _title: Label = $Title
@onready var _survivability: AccordionPanel = $Survivability
@onready var _artillery: AccordionPanel = $Artillery
@onready var _torpedo: AccordionPanel = $Torpedo
@onready var _maneuv: AccordionPanel = $Maneuverability

func _ready() -> void:
	_clear_all()

## Called whenever the selected ship changes.
func set_ship(ship: Ship) -> void:
	_ship = ship
	# Wait until the ship has had a chance to run _ready and initialize params.
	call_deferred("refresh")

## Re-reads all controller params and rebuilds the rows. Safe to call any
## time the ship's mod state may have changed (after upgrade/skill toggles).
func refresh() -> void:
	if _ship == null or not is_instance_valid(_ship):
		_clear_all()
		return
	# Mods get baked into dynamic_mod inside the ship's _physics_process
	# (when update_static_mods / update_dynamic_mods flags are set). In the
	# port main menu the ship is not the network authority, so its
	# _physics_process returns early and the flags are never consumed.
	# Bake the mod layers here explicitly before reading values.
	if _ship.update_static_mods:
		_ship._update_static_mods()
	if _ship.update_dynamic_mods:
		_ship._update_dynamic_mods()
	# Yield one frame so any controllers that defer initialization complete.
	await get_tree().process_frame
	if _ship == null or not is_instance_valid(_ship):
		return
	_populate_survivability()
	_populate_artillery()
	_populate_torpedo()
	_populate_maneuverability()

func _clear_all() -> void:
	for section in [_survivability, _artillery, _torpedo, _maneuv]:
		if section:
			section.clear_stats()
			section.clear_rating()

# ─────────────────────────────────────────────────────────────────────────────
#  Maneuverability
# ─────────────────────────────────────────────────────────────────────────────
func _populate_maneuverability() -> void:
	_maneuv.clear_stats()
	var mc: ShipMovementV4 = _ship.movement_controller
	if mc == null or mc.params == null:
		_maneuv.clear_rating()
		_maneuv.add_stat_row("(no movement controller)", "")
		return
	var p := mc.get_params()
	var b := mc.get_base_params()

	# Effectiveness score: weighted blend of speed, turning, rudder, accel.
	# Each sub-score is roughly calibrated so an "average" ship lands near 50.
	var speed_score: float  = p.max_speed_knots * 2.5
	var turn_score: float   = 30000.0 / max(p.turning_circle_radius, 1.0)
	var rudder_score: float = 50.0 / max(p.rudder_response_time, 0.1)
	var accel_score: float  = 400.0 / max(p.acceleration_time, 0.1)
	var rating: float = speed_score * 0.35 + turn_score * 0.30 + rudder_score * 0.20 + accel_score * 0.15
	_maneuv.set_rating(rating)

	_maneuv.add_stat_row("Max speed",        "%.1f kts" % p.max_speed_knots,        not _eq(p.max_speed_knots, b.max_speed_knots))
	_maneuv.add_stat_row("Reverse speed",    "%.1f kts" % (p.max_speed_knots * p.reverse_speed_ratio), not (_eq(p.max_speed_knots, b.max_speed_knots) and _eq(p.reverse_speed_ratio, b.reverse_speed_ratio)))
	_maneuv.add_stat_row("0 → full",         "%.1f s"   % p.acceleration_time,      not _eq(p.acceleration_time, b.acceleration_time))
	_maneuv.add_stat_row("Full → 0",         "%.1f s"   % p.deceleration_time,      not _eq(p.deceleration_time, b.deceleration_time))
	_maneuv.add_separator()
	_maneuv.add_stat_row("Turning circle",   "%.0f m"   % p.turning_circle_radius,  not _eq(p.turning_circle_radius, b.turning_circle_radius))
	_maneuv.add_stat_row("Rudder shift",     "%.1f s"   % p.rudder_response_time,   not _eq(p.rudder_response_time, b.rudder_response_time))
	_maneuv.add_stat_row("Turn speed loss",  "%.0f %%"  % (p.turn_speed_loss * 100.0), not _eq(p.turn_speed_loss, b.turn_speed_loss))

# ─────────────────────────────────────────────────────────────────────────────
#  Artillery (main + secondaries + DPM)
# ─────────────────────────────────────────────────────────────────────────────
func _populate_artillery() -> void:
	_artillery.clear_stats()

	var total_main_dpm := 0.0
	var main_range_km := 0.0
	var main_caliber := 0.0

	# ── Main battery ──
	var ac: ArtilleryController = _ship.artillery_controller
	if ac != null and ac.params != null:
		var gp := ac.get_params()
		var gb := ac.get_base_params()
		var num_guns := ac.guns.size()
		var barrels_total := 0
		for g in ac.guns:
			barrels_total += g.muzzles.size()

		_artillery.add_subheader("Main Battery")
		var s1: ShellParams = gp.shell1
		main_caliber = s1.caliber
		main_range_km = gp._range / 1000.0
		_artillery.add_stat_row("Guns",     "%d × %d × %.0f mm" % [num_guns, (barrels_total / num_guns) if num_guns > 0 else 0, s1.caliber])
		_artillery.add_stat_row("Range",    "%.1f km" % (gp._range / 1000.0),   not _eq(gp._range, gb._range))
		_artillery.add_stat_row("Reload",   "%.1f s"  % gp.reload_time,         not _eq(gp.reload_time, gb.reload_time))
		_artillery.add_stat_row("180° traverse", ("%.1f s" % (180.0 / gp.traverse_speed)) if gp.traverse_speed > 0.0 else "—", not _eq(gp.traverse_speed, gb.traverse_speed))

		# AP / HE breakdown with DPM (shells fired per volley = sum of all barrels)
		for shell_idx in [0, 1]:
			var sp: ShellParams = gp.shell1 if shell_idx == 0 else gp.shell2
			if sp == null:
				continue
			var label := "AP" if sp.type == ShellParams.ShellType.AP else "HE"
			var dpm := 0.0
			if gp.reload_time > 0.0:
				dpm = sp.damage * barrels_total * 60.0 / gp.reload_time
			total_main_dpm = max(total_main_dpm, dpm)
			_artillery.add_stat_row("  %s damage" % label, "%d" % int(sp.damage))
			_artillery.add_stat_row("  %s DPM" % label,    "%s" % _fmt_int(dpm))
			if sp.type == ShellParams.ShellType.HE:
				_artillery.add_stat_row("  HE fire chance", "%.0f" % sp.fire_buildup)
				_artillery.add_stat_row("  HE penetration",   "%d mm" % (sp.overmatch * sp.penetration_modifier))
			else:
				_artillery.add_stat_row("  AP velocity",    "%.0f m/s" % sp.speed)

	# ── Secondaries ──
	var sec_total_dpm := 0.0
	var sc: SecondaryController_ = _ship.secondary_controller
	if sc != null and sc.sub_controllers.size() > 0:
		_artillery.add_separator()
		_artillery.add_subheader("Secondaries")
		var total_dpm_he := 0.0
		var total_dpm_ap := 0.0
		var max_range := 0.0
		for sub: SecSubController in sc.sub_controllers:
			var p := sub.params.p() as GunParams
			var b := sub.params.base as GunParams
			max_range = max(max_range, p._range)
			var n := sub.guns.size()
			var barrels := 0
			for g in sub.guns:
				barrels += g.muzzles.size()
			var cal: float = (p.shell1.caliber if p.shell1 else (p.shell2.caliber if p.shell2 else 0.0))
			var bpg := (barrels / n) if n > 0 else 0
			_artillery.add_stat_row("  %d × %d × %.0f mm" % [n, bpg, cal], "%.1f s reload" % p.reload_time, not _eq(p.reload_time, b.reload_time))
			if p.reload_time > 0.0:
				if p.shell1: total_dpm_ap += p.shell1.damage * barrels * 60.0 / p.reload_time
				if p.shell2: total_dpm_he += p.shell2.damage * barrels * 60.0 / p.reload_time
		_artillery.add_stat_row("Range",    "%.1f km" % (max_range / 1000.0))
		if total_dpm_ap > 0.0:
			_artillery.add_stat_row("Total AP DPM", "%s" % _fmt_int(total_dpm_ap))
		if total_dpm_he > 0.0:
			_artillery.add_stat_row("Total HE DPM", "%s" % _fmt_int(total_dpm_he))
		sec_total_dpm = max(total_dpm_ap, total_dpm_he)

	# Effectiveness rating: best main DPM weighted with caliber & range, plus
	# secondaries contribution. Tuned so an average BB lands near 50.
	var main_dpm_score := total_main_dpm / 1500.0       # 75k DPM → 50, 150k → 100
	var caliber_score  := main_caliber / 5.0            # 380 mm → 76, 460 mm → 92
	var range_score    := main_range_km * 4.0           # 20 km → 80, 25 km → 100
	var sec_score      := sec_total_dpm / 2000.0        # 100k sec DPM → 50
	var rating := main_dpm_score * 0.45 + range_score * 0.25 + caliber_score * 0.20 + sec_score * 0.10
	rating *= 0.5
	if total_main_dpm > 0.0 or sec_total_dpm > 0.0:
		_artillery.set_rating(rating)
	else:
		_artillery.clear_rating()

# ─────────────────────────────────────────────────────────────────────────────
#  Survivability (HP + armor + torpedo protection)
# ─────────────────────────────────────────────────────────────────────────────
func _populate_survivability() -> void:
	_survivability.clear_stats()
	var hp: HPManager = _ship.health_controller
	if hp == null or hp.params == null:
		_survivability.clear_rating()
		_survivability.add_stat_row("(no HP manager)", "")
		return
	var hp_p := hp.params.p() as HPParams
	var hp_b := hp.params.base as HPParams
	var effective_hp := hp._max_hp * hp_p.mult

	# ── Repair-party consumable totals ──
	# Total heal % across all charges of every repair-party consumable. Infinite
	# stacks (max_stack == -1) are treated as 10 for scoring purposes.
	var repair_charges_str := ""
	var repair_total_pct := 0.0
	var repair_per_charge_pct := 0.0
	var repair_charges := 0
	var cm: ConsumableManager = _ship.consumable_manager
	if cm != null:
		for item in cm.equipped_consumables:
			if item == null:
				continue
			var rp := item as RepairParty
			if rp == null:
				continue
			rp = rp.p()
			var charges_for_score: float = (10.0 if rp.max_stack == -1 else float(rp.max_stack))
			repair_total_pct += rp.heal_per_sec * rp.duration * 100.0 * charges_for_score
			repair_per_charge_pct = max(repair_per_charge_pct, rp.heal_per_sec * rp.duration * 100.0)
			repair_charges += (-1 if rp.max_stack == -1 else rp.max_stack)
			repair_charges_str = "∞" if rp.max_stack == -1 else ("%d" % rp.max_stack)

	# Average repair efficiency across the three damage classes — this is the
	# fraction of damage that is actually healable, so repair-party heals and
	# the repair pools multiply together to give effective combat HP.
	var avg_repair_eff: float = (hp_p.citadel_repair * 0.1 + hp_p.pen_repair * 0.6 + hp_p.light_repair * 0.3)
	var heal_pool_frac: float = repair_total_pct / 100.0
	# Effective HP a player can soak across a match: base HP plus everything
	# that consumable heals can plausibly restore.
	var effective_combat_hp: float = effective_hp * (1.0 + heal_pool_frac * avg_repair_eff)

	# ── Armor breakdown ──
	var armor: Dictionary = _compute_armor_summary()
	var armor_mm: float = armor.avg_mm

	# Size penalty: larger ships are bigger targets. Use the ship's AABB broadside
	# silhouette (longest horizontal dimension × above-waterline height) — this is
	# the external envelope and is unaffected by internal armor geometry that would
	# skew a raw face-area sum. ~3000 m² (Bismarck-ish) = neutral 1.0.
	var ship_aabb: AABB = _ship.aabb
	var aabb_length: float = max(ship_aabb.size.x, ship_aabb.size.z)
	var aabb_height_aw: float = max(0.0, ship_aabb.end.y)
	var projected_area_m2: float = aabb_length * aabb_height_aw
	var size_penalty: float = clampf(projected_area_m2 / 3000.0, 0.55, 1.7) if projected_area_m2 > 0.0 else 1.0

	# Convert to a 0–100 sub-score. ~400 mm average armor at neutral size ≈ 100.
	var armor_score: float = (armor_mm / max(size_penalty, 0.01)) / 1.1

	# Rating: effective combat HP dominates, armor protection is a meaningful
	# secondary, torpedo protection rounds it out.
	var hp_score: float   = effective_combat_hp / 1000.0
	var torp_score: float = hp_p.torpedo_protection * 200.0
	var rating: float = hp_score * 0.65 + armor_score * 0.20 + torp_score * 0.15
	rating *= 0.85
	_survivability.set_rating(rating)

	_survivability.add_stat_row("Max HP", _fmt_int(effective_hp), not _eq(hp_p.mult, hp_b.mult))
	if repair_charges != 0 or repair_per_charge_pct > 0.0:
		_survivability.add_stat_row("Repair charges", repair_charges_str)
		_survivability.add_stat_row("Heal per charge", "%.0f %% max HP" % repair_per_charge_pct)
		_survivability.add_stat_row("Total heal pool", "%.0f %% max HP" % repair_total_pct)
		_survivability.add_stat_row("Effective HP", _fmt_int(effective_combat_hp))
	_survivability.add_separator()
	_survivability.add_subheader("Armor")
	if armor.has_data:
		_survivability.add_stat_row("  Avg armor",          "%.0f mm" % armor_mm)
		_survivability.add_stat_row("  Broadside profile",  "%.0f m²" % projected_area_m2)
	else:
		_survivability.add_stat_row("  (no armor data)", "")
	_survivability.add_separator()
	_survivability.add_subheader("Damage repair")
	_survivability.add_stat_row("  Citadel repair", "%.0f %%" % (hp_p.citadel_repair * 100.0), not _eq(hp_p.citadel_repair, hp_b.citadel_repair))
	_survivability.add_stat_row("  Pen repair",     "%.0f %%" % (hp_p.pen_repair     * 100.0), not _eq(hp_p.pen_repair,     hp_b.pen_repair))
	_survivability.add_stat_row("  Light repair",   "%.0f %%" % (hp_p.light_repair   * 100.0), not _eq(hp_p.light_repair,   hp_b.light_repair))
	_survivability.add_separator()
	_survivability.add_subheader("Torpedo protection")
	_survivability.add_stat_row("  Damage reduction", "%.0f %%" % (hp_p.torpedo_protection * 100.0), not _eq(hp_p.torpedo_protection, hp_b.torpedo_protection))

## Computes the area-weighted average armor thickness (mm) across all
## above-waterline faces of every ArmorPart on the ship.
func _compute_armor_summary() -> Dictionary:
	var out: Dictionary = {
		"has_data": false,
		"avg_mm": 0.0,
	}
	if _ship.armor_parts.is_empty():
		return out

	var weighted_sum := 0.0
	var total_area := 0.0

	for part: ArmorPart in _ship.armor_parts:
		if part == null or not is_instance_valid(part):
			continue
		var shape_node: CollisionShape3D = null
		for child in part.get_children():
			if child is CollisionShape3D:
				shape_node = child
				break
		if shape_node == null or shape_node.shape == null:
			continue
		var tri_shape := shape_node.shape as ConcavePolygonShape3D
		if tri_shape == null:
			continue
		var verts: PackedVector3Array = tri_shape.get_faces()
		var face_count: int = verts.size() / 3
		if face_count == 0:
			continue

		# Use the shape node's global transform so vertices are in world space —
		# lets us cull faces below the waterline and handles parent-scale baking.
		var xform: Transform3D = shape_node.transform
		if shape_node.is_inside_tree():
			xform = shape_node.global_transform
		for face_idx in range(face_count):
			var armor_mm: float = 0.0
			if part.armor_system != null:
				armor_mm = float(part.armor_system.get_face_armor_thickness(part.armor_path, face_idx))
			# Skip unarmored faces — modeling artifacts that would dilute the average.
			if armor_mm <= 0.0:
				continue

			var v0: Vector3 = xform * verts[face_idx * 3 + 0]
			var v1: Vector3 = xform * verts[face_idx * 3 + 1]
			var v2: Vector3 = xform * verts[face_idx * 3 + 2]
			# Skip fully submerged faces — underwater plating isn't part of the
			# exposed profile a shell can hit.
			if v0.y <= 0.0 and v1.y <= 0.0 and v2.y <= 0.0:
				continue
			var area: float = 0.5 * (v1 - v0).cross(v2 - v0).length()
			weighted_sum += armor_mm * area
			total_area += area

	if total_area <= 0.0:
		return out

	out.has_data = true
	out.avg_mm = weighted_sum / total_area
	return out

func _mean(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var s := 0.0
	for v in arr:
		s += v
	return s / arr.size()

# ─────────────────────────────────────────────────────────────────────────────
#  Torpedo
# ─────────────────────────────────────────────────────────────────────────────
func _populate_torpedo() -> void:
	_torpedo.clear_stats()
	var tc: TorpedoController = _ship.torpedo_controller
	if tc == null or tc.params == null:
		_torpedo.clear_rating()
		_torpedo.add_stat_row("(no torpedo armament)", "")
		_torpedo.expanded = false
		return
	_torpedo.expanded = true
	var lp := tc.get_params()
	var lb := tc.params.base as TorpedoLauncherParams
	var tp := tc.get_torp_params()
	var num_launchers := tc.launchers.size()
	var tubes_total := 0
	for l in tc.launchers:
		tubes_total += l.muzzles.size()

	_torpedo.add_stat_row("Launchers",       "%d × %d tubes" % [num_launchers, (tubes_total / num_launchers) if num_launchers > 0 else 0])
	_torpedo.add_stat_row("Reload",          "%.1f s" % lp.reload_time, not _eq(lp.reload_time, lb.reload_time))
	_torpedo.add_stat_row("Range",           "%.1f km" % (lp._range / 1000.0), not _eq(lp._range, lb._range))
	_torpedo.add_stat_row("180° traverse",   ("%.1f s" % (180.0 / lp.traverse_speed)) if lp.traverse_speed > 0.0 else "—", not _eq(lp.traverse_speed, lb.traverse_speed))
	_torpedo.add_separator()
	_torpedo.add_subheader("Torpedo")
	_torpedo.add_stat_row("  Damage",        _fmt_int(tp.damage))
	_torpedo.add_stat_row("  Speed",         "%.0f kts" % tp.speed_knts)
	_torpedo.add_stat_row("  Flood buildup", "%.0f" % tp.flood_buildup)
	_torpedo.add_stat_row("  Detect range",  "%.0f m" % tp.detection_range)
	_torpedo.add_stat_row("  Arming dist",   "%.0f m" % tp.arming_distance)
	# DPM (volley damage / reload) — sum across all tubes
	var dpm := 0.0
	if lp.reload_time > 0.0:
		dpm = tp.damage * tubes_total * 60.0 / lp.reload_time
		_torpedo.add_stat_row("  Theoretical DPM", _fmt_int(dpm))

	# Rating: DPM dominates, plus range and speed contribute.
	var dpm_score   := dpm / 4000.0                  # 200k DPM → 50, 400k → 100
	var range_score := (lp._range / 1000.0) * 5.0    # 12 km → 60, 20 km → 100
	var speed_score := tp.speed_knts * 1.2           # 60 kts → 72
	var rating := dpm_score * 0.55 + range_score * 0.30 + speed_score * 0.15
	_torpedo.set_rating(rating)

# ─────────────────────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────────────────────
func _eq(a: float, b: float) -> bool:
	return absf(a - b) < EPS

func _fmt_int(v: float) -> String:
	# Thousands separator
	var s := "%d" % int(round(v))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count == 3 and i > 0 and s[i - 1] != "-":
			out = "," + out
			count = 0
	return out
