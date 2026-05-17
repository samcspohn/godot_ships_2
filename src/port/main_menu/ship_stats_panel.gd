extends VBoxContainer
class_name ShipStatsPanel

## Stats panel for the port main menu. Builds four collapsible accordion
## sections (Maneuverability, Artillery, Survivability, Torpedo) populated
## from the selected ship's controllers. Every stat reads from
## `params.dynamic_mod` so upgrade and skill effects show up automatically.
## Values that differ from `params.base` are highlighted green.

const EPS: float = 0.001

var _ship: Ship = null

@onready var _title: Label = $Title
@onready var _maneuv: AccordionPanel = $Maneuverability
@onready var _artillery: AccordionPanel = $Artillery
@onready var _survivability: AccordionPanel = $Survivability
@onready var _torpedo: AccordionPanel = $Torpedo

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
	_populate_maneuverability()
	_populate_artillery()
	_populate_survivability()
	_populate_torpedo()

func _clear_all() -> void:
	for section in [_maneuv, _artillery, _survivability, _torpedo]:
		if section:
			section.clear_stats()

# ─────────────────────────────────────────────────────────────────────────────
#  Maneuverability
# ─────────────────────────────────────────────────────────────────────────────
func _populate_maneuverability() -> void:
	_maneuv.clear_stats()
	var mc: ShipMovementV4 = _ship.movement_controller
	if mc == null or mc.params == null:
		_maneuv.add_stat_row("(no movement controller)", "")
		return
	var p := mc.get_params()
	var b := mc.get_base_params()

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
			_artillery.add_stat_row("  %s damage" % label, "%d" % int(sp.damage))
			_artillery.add_stat_row("  %s DPM" % label,    "%s" % _fmt_int(dpm))
			if sp.type == ShellParams.ShellType.HE:
				_artillery.add_stat_row("  HE fire chance", "%.0f" % sp.fire_buildup)
				_artillery.add_stat_row("  HE penetration",   "%d mm" % sp.overmatch)
			else:
				_artillery.add_stat_row("  AP velocity",    "%.0f m/s" % sp.speed)

	# ── Secondaries ──
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

# ─────────────────────────────────────────────────────────────────────────────
#  Survivability (HP + torpedo protection)
# ─────────────────────────────────────────────────────────────────────────────
func _populate_survivability() -> void:
	_survivability.clear_stats()
	var hp: HPManager = _ship.health_controller
	if hp == null or hp.params == null:
		_survivability.add_stat_row("(no HP manager)", "")
		return
	var hp_p := hp.params.p() as HPParams
	var hp_b := hp.params.base as HPParams

	_survivability.add_stat_row("Max HP", _fmt_int(hp._max_hp * hp_p.mult), not _eq(hp_p.mult, hp_b.mult))
	_survivability.add_separator()
	_survivability.add_subheader("Damage repair")
	_survivability.add_stat_row("  Citadel repair", "%.0f %%" % (hp_p.citadel_repair * 100.0), not _eq(hp_p.citadel_repair, hp_b.citadel_repair))
	_survivability.add_stat_row("  Pen repair",     "%.0f %%" % (hp_p.pen_repair     * 100.0), not _eq(hp_p.pen_repair,     hp_b.pen_repair))
	_survivability.add_stat_row("  Light repair",   "%.0f %%" % (hp_p.light_repair   * 100.0), not _eq(hp_p.light_repair,   hp_b.light_repair))
	_survivability.add_separator()
	_survivability.add_subheader("Torpedo protection")
	_survivability.add_stat_row("  Damage reduction", "%.0f %%" % (hp_p.torpedo_protection * 100.0), not _eq(hp_p.torpedo_protection, hp_b.torpedo_protection))

# ─────────────────────────────────────────────────────────────────────────────
#  Torpedo
# ─────────────────────────────────────────────────────────────────────────────
func _populate_torpedo() -> void:
	_torpedo.clear_stats()
	var tc: TorpedoController = _ship.torpedo_controller
	if tc == null or tc.params == null:
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
	if lp.reload_time > 0.0:
		var dpm := tp.damage * tubes_total * 60.0 / lp.reload_time
		_torpedo.add_stat_row("  Theoretical DPM", _fmt_int(dpm))

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
