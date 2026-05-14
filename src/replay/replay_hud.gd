extends CanvasLayer
class_name ReplayHUD

## In-replay HUD that mirrors the in-game UI's read-only widgets.
##
## Driven from a `ReplayPlayback`'s snapshot stream and event signal. Builds
## its widgets programmatically in `_ready` so the .tscn stays trivial.
##
## Phase 1 scope (see doc/REPLAY_HUD_PHASE1.md):
##   - Kill feed (lifted out of match_replay.gd)
##   - HitStatCounters (driven by ReplayStatsAccumulator)
##   - HP bar, speed/throttle/rudder, visibility indicator
##   - Fire/flood icons, gun reload bars, active consumable strip
##   - FPS, simple team tracker
##
## Out of Phase 1: aim crosshair, weapon buttons, sniper reticle, minimap,
## consumable cooldown rings, skills.

const KillFeedScene = preload("res://src/ui/kill_feed.tscn")
const HitStatCountersScene = preload("res://src/ui/hit_stat_counters.tscn")

# ---------------------------------------------------------------------------
# Bindings (set via bind())
# ---------------------------------------------------------------------------
var _playback: ReplayPlayback = null
var _ghost_ships: Array = []
var _stats: ReplayStatsAccumulator = null
var _followed_ship_id: int = -1
var _local_team_id: int = 0  ## team viewed as "friendly" in kill feed colours

# ---------------------------------------------------------------------------
# Throttle / rudder display tables
# ---------------------------------------------------------------------------
const THROTTLE_TEXT := {
	-1: "Reverse",
	 0: "Stop",
	 1: "1/4",
	 2: "1/2",
	 3: "3/4",
	 4: "Full",
}

# ---------------------------------------------------------------------------
# Widget references (built in _ready)
# ---------------------------------------------------------------------------
var _root: Control = null

# Kill feed (top right)
var _kill_feed: KillFeed = null

# Hit/stat counters (top right, above kill feed)
var _stat_counters: HitStatCounters = null

# Top-left: FPS
var _fps_label: Label = null

# Bottom-center: HP bar + reload bars + status icons
var _hp_bar: ProgressBar = null
var _hp_label: Label = null
var _reload_bars_container: HBoxContainer = null
var _reload_bars: Array[ProgressBar] = []
var _consumables_container: HBoxContainer = null
var _consumable_widgets: Array = []   ## Array[Dictionary] {panel, label, slot_id}

# Bottom-left: speed / throttle / rudder
var _speed_label: Label = null
var _throttle_label: Label = null
var _throttle_slider: VSlider = null
var _rudder_label: Label = null
var _rudder_slider: HSlider = null

# Bottom-center, below HP: status row
var _visibility_indicator: ColorRect = null
var _visibility_color: ColorRect = null
var _fire_icons: Array[ColorRect] = []
var _flood_icons: Array[ColorRect] = []
const MAX_STATUS_ICONS := 8

# Tinted inactive colours so a row of unlit icons still reads as "these are
# fire slots" vs "these are flood slots". Without distinct base colours an
# unburned/undamaged ship looks like a row of identical gray boxes, which
# previously reads as one big strip of fires.
const _FIRE_INACTIVE  := Color(0.30, 0.10, 0.05, 0.55)
const _FIRE_ACTIVE    := Color(1.00, 0.40, 0.10, 0.95)
const _FLOOD_INACTIVE := Color(0.05, 0.12, 0.30, 0.55)
const _FLOOD_ACTIVE   := Color(0.30, 0.50, 1.00, 0.95)

# Top-center: team tracker
var _friendlies_container: HBoxContainer = null
var _enemies_container: HBoxContainer = null
var _team_indicators: Dictionary = {}  ## ghost_ship -> Dictionary {bar, label}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Bind this HUD to an active ReplayPlayback. Call after the playback has
## loaded a replay and ghost ships have been registered.
func bind(playback: ReplayPlayback, ghost_ships: Array) -> void:
	_playback = playback
	_ghost_ships = ghost_ships

	if _stats == null:
		_stats = ReplayStatsAccumulator.new()
	_stats.clear_attribution()

	# Wire signals
	playback.event_fired.connect(_on_event_fired)
	playback.seek_jumped.connect(_on_seek_jumped)

	# Hook stats into the HitStatCounters widget
	if _stat_counters:
		_stat_counters.set_stats(_stats)

	# Build team tracker rows now that ghost ships are known
	_build_team_tracker()

## Switch the HUD to track a different ship (-1 = none / free camera).
## Rebuilds all event-derived state from t=0 to current_time.
func set_followed_ship_id(ship_id: int) -> void:
	_followed_ship_id = ship_id
	_local_team_id = _team_id_for_ship(ship_id)

	if _stats:
		_stats.set_followed_ship(ship_id, _playback.reader.ships if _playback and _playback.reader else [])
		_stats.reset()
		# Re-replay events from t=0 to now so stats reflect the new perspective
		if _playback and _playback.reader:
			# Make sure torpedo attribution is rebuilt too
			_stats.clear_attribution()
			var events: Array = _playback.reader.read_events_in_range(0.0, _playback.current_time)
			for ev in events:
				_stats.observe_for_attribution(ev)
			_stats.replay_events(events)
		# HitStatCounters only refreshes its labels when damage_events fire; the
		# replay above is silent, so push an explicit refresh now.
		if _stat_counters:
			_stat_counters.update_counters()

	# Rebuild reload bars to match the new ship's gun count
	_build_reload_bars()
	_build_consumables_strip()
	_build_status_icons()
	# Rebuild team tracker because friendly/enemy assignment depends on the
	# local team id, which just changed.
	_build_team_tracker()

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_build_layout()

func _process(_dt: float) -> void:
	if _fps_label:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

	if _playback == null:
		return
	_update_followed_ship_widgets()
	_update_team_tracker()

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
func _build_layout() -> void:
	_root = Control.new()
	_root.name = "HUDRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_top_left()
	_build_top_center()
	_build_top_right()
	_build_bottom_left()
	_build_bottom_center()

func _build_top_left() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(10, 60)
	panel.add_theme_stylebox_override("panel", _make_dark_style())
	_root.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_fps_label = Label.new()
	_fps_label.text = "FPS: 0"
	_fps_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_fps_label)

func _build_top_center() -> void:
	# Anchor at the horizontal centre of the screen and let the PanelContainer
	# size itself to its content (grow in both directions from the anchor).
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = 0.0
	panel.offset_right = 0.0
	panel.offset_top = 60.0
	panel.offset_bottom = 60.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_END
	panel.add_theme_stylebox_override("panel", _make_dark_style())
	_root.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	panel.add_child(hbox)

	_friendlies_container = HBoxContainer.new()
	_friendlies_container.add_theme_constant_override("separation", 4)
	hbox.add_child(_friendlies_container)

	var sep := VSeparator.new()
	hbox.add_child(sep)

	_enemies_container = HBoxContainer.new()
	_enemies_container.add_theme_constant_override("separation", 4)
	hbox.add_child(_enemies_container)

func _build_top_right() -> void:
	# Anchor a VBox to the top-right corner, growing left/down, so its children
	# (HitStatCounters and KillFeed) hug the right edge regardless of width.
	var vbox := VBoxContainer.new()
	vbox.anchor_left = 1.0
	vbox.anchor_right = 1.0
	vbox.anchor_top = 0.0
	vbox.anchor_bottom = 0.0
	vbox.offset_left = -10.0
	vbox.offset_right = -10.0
	vbox.offset_top = 60.0
	vbox.offset_bottom = 60.0
	vbox.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	vbox.grow_vertical = Control.GROW_DIRECTION_END
	vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)

	# Hit/stat counters (right-aligned within the column)
	_stat_counters = HitStatCountersScene.instantiate()
	_stat_counters.size_flags_horizontal = Control.SIZE_SHRINK_END
	vbox.add_child(_stat_counters)

	# Kill feed below counters
	_kill_feed = KillFeedScene.instantiate()
	_kill_feed.custom_minimum_size = Vector2(400, 200)
	_kill_feed.size_flags_horizontal = Control.SIZE_SHRINK_END
	vbox.add_child(_kill_feed)

func _build_bottom_left() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 10
	panel.offset_top = -200
	panel.offset_right = 240
	panel.offset_bottom = -90
	panel.add_theme_stylebox_override("panel", _make_dark_style())
	_root.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	panel.add_child(hbox)

	# Throttle slider on the left
	_throttle_slider = VSlider.new()
	_throttle_slider.editable = false
	_throttle_slider.min_value = -1
	_throttle_slider.max_value = 4
	_throttle_slider.step = 1
	_throttle_slider.value = 0
	_throttle_slider.custom_minimum_size = Vector2(20, 100)
	hbox.add_child(_throttle_slider)

	# Labels stacked
	var labels_vbox := VBoxContainer.new()
	hbox.add_child(labels_vbox)

	_speed_label = Label.new()
	_speed_label.text = "Speed: 0 kn"
	labels_vbox.add_child(_speed_label)

	_throttle_label = Label.new()
	_throttle_label.text = "Throttle: Stop"
	labels_vbox.add_child(_throttle_label)

	_rudder_label = Label.new()
	_rudder_label.text = "Rudder: Center"
	labels_vbox.add_child(_rudder_label)

	_rudder_slider = HSlider.new()
	_rudder_slider.editable = false
	_rudder_slider.min_value = -1.0
	_rudder_slider.max_value = 1.0
	_rudder_slider.step = 0.01
	_rudder_slider.value = 0.0
	_rudder_slider.custom_minimum_size = Vector2(180, 12)
	labels_vbox.add_child(_rudder_slider)

func _build_bottom_center() -> void:
	# Sits above the BottomBar (replay scrubber) which is ~75 px tall.
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel.offset_left = -300
	panel.offset_right = 300
	panel.offset_top = -180
	panel.offset_bottom = -90
	panel.add_theme_stylebox_override("panel", _make_dark_style())
	_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# HP bar with overlaid label
	var hp_holder := Control.new()
	hp_holder.custom_minimum_size = Vector2(0, 22)
	vbox.add_child(hp_holder)

	_hp_bar = ProgressBar.new()
	_hp_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hp_bar.show_percentage = false
	_hp_bar.min_value = 0
	_hp_bar.max_value = 100
	_hp_bar.value = 100
	hp_holder.add_child(_hp_bar)

	_hp_label = Label.new()
	_hp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_label.text = "0/0"
	hp_holder.add_child(_hp_label)

	# Reload bars
	_reload_bars_container = HBoxContainer.new()
	_reload_bars_container.add_theme_constant_override("separation", 2)
	vbox.add_child(_reload_bars_container)

	# Status row: visibility | fires | floods
	var status_hbox := HBoxContainer.new()
	status_hbox.add_theme_constant_override("separation", 12)
	vbox.add_child(status_hbox)

	# Visibility indicator (small square that lights up when detected)
	var vis_holder := PanelContainer.new()
	vis_holder.custom_minimum_size = Vector2(20, 20)
	status_hbox.add_child(vis_holder)
	_visibility_indicator = ColorRect.new()
	_visibility_indicator.color = Color(0, 0, 0, 0.5)
	vis_holder.add_child(_visibility_indicator)
	_visibility_color = ColorRect.new()
	_visibility_color.set_anchors_preset(Control.PRESET_FULL_RECT)
	_visibility_color.color = Color(0, 0, 0, 0)
	_visibility_indicator.add_child(_visibility_color)

	# Fire and flood icon containers (filled by _build_status_icons)
	var fire_box := HBoxContainer.new()
	fire_box.name = "FireBox"
	fire_box.add_theme_constant_override("separation", 2)
	status_hbox.add_child(fire_box)
	for i in MAX_STATUS_ICONS:
		var r := ColorRect.new()
		r.color = _FIRE_INACTIVE
		r.custom_minimum_size = Vector2(14, 14)
		r.visible = false
		fire_box.add_child(r)
		_fire_icons.append(r)

	var flood_box := HBoxContainer.new()
	flood_box.name = "FloodBox"
	flood_box.add_theme_constant_override("separation", 2)
	status_hbox.add_child(flood_box)
	for i in MAX_STATUS_ICONS:
		var r := ColorRect.new()
		r.color = _FLOOD_INACTIVE
		r.custom_minimum_size = Vector2(14, 14)
		r.visible = false
		flood_box.add_child(r)
		_flood_icons.append(r)

	# Active consumables strip
	_consumables_container = HBoxContainer.new()
	_consumables_container.add_theme_constant_override("separation", 4)
	vbox.add_child(_consumables_container)

# ---------------------------------------------------------------------------
# Per-ship rebuilds (run when followed ship changes)
# ---------------------------------------------------------------------------
func _build_reload_bars() -> void:
	if _reload_bars_container == null:
		return
	for child in _reload_bars_container.get_children():
		child.queue_free()
	_reload_bars.clear()

	var entry := _ship_manifest_entry(_followed_ship_id)
	if entry.is_empty():
		return
	var gun_count: int = entry.get("gun_count", 0)
	for i in gun_count:
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = 1.0
		bar.custom_minimum_size = Vector2(40, 8)
		_reload_bars_container.add_child(bar)
		_reload_bars.append(bar)

func _build_consumables_strip() -> void:
	if _consumables_container == null:
		return
	for child in _consumables_container.get_children():
		child.queue_free()
	_consumable_widgets.clear()

	var entry := _ship_manifest_entry(_followed_ship_id)
	if entry.is_empty():
		return
	var consumables: Array = entry.get("consumables", [])
	for c in consumables:
		var slot_id: int = c.get("slot_id", 0)
		var label_text: String = c.get("label", "?")
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(50, 26)
		panel.add_theme_stylebox_override("panel", _make_dim_style())
		var lbl := Label.new()
		lbl.text = label_text.left(6)
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		panel.add_child(lbl)
		_consumables_container.add_child(panel)
		_consumable_widgets.append({"panel": panel, "label": lbl, "slot_id": slot_id})

func _build_status_icons() -> void:
	# Only the *number* of slots that this ship can have on fire / flooded
	# matters for visibility; the icons themselves are pre-built. Hide the
	# excess slots so we don't show bogus rectangles for ships with fewer
	# possible zones.
	var entry := _ship_manifest_entry(_followed_ship_id)
	var fire_count: int  = entry.get("fire_count",  0) if not entry.is_empty() else 0
	var flood_count: int = entry.get("flood_count", 0) if not entry.is_empty() else 0
	for i in _fire_icons.size():
		_fire_icons[i].visible = i < fire_count
	for i in _flood_icons.size():
		_flood_icons[i].visible = i < flood_count

# ---------------------------------------------------------------------------
# Per-frame updates
# ---------------------------------------------------------------------------
func _update_followed_ship_widgets() -> void:
	if _followed_ship_id < 0:
		_set_followed_widgets_visible(false)
		return
	_set_followed_widgets_visible(true)

	var snap: Dictionary = _playback._snap_b.get(_followed_ship_id, {})
	if snap.is_empty():
		# Try _snap_a as fallback (we may be exactly on a snapshot boundary)
		snap = _playback._snap_a.get(_followed_ship_id, {})
		if snap.is_empty():
			return

	# HP
	var gs: GhostShip = _ghost_ship_for(_followed_ship_id)
	var max_hp: float = gs.max_hp if gs else 0.0
	if max_hp <= 0.0:
		max_hp = max(snap.get("hp", 1.0), 1.0)
	var hp: float = snap.get("hp", 0.0)
	if max_hp > 0.0:
		_hp_bar.value = (hp / max_hp) * 100.0
	_hp_label.text = "%d / %d" % [int(round(hp)), int(round(max_hp))]
	_apply_hp_bar_color((hp / max_hp) * 100.0 if max_hp > 0.0 else 0.0)

	# Speed (knots)
	var velocity: Vector3 = snap.get("velocity", Vector3.ZERO)
	var speed_knots: float = velocity.length() * 1.94384
	_speed_label.text = "Speed: %.1f kn" % speed_knots

	# Throttle
	var throttle: int = snap.get("throttle", 0)
	_throttle_label.text = "Throttle: %s" % THROTTLE_TEXT.get(throttle, str(throttle))
	_throttle_slider.value = throttle
	if throttle > 0:
		_throttle_slider.modulate = Color(0.5, 0.8, 1.0)
	elif throttle < 0:
		_throttle_slider.modulate = Color(1.0, 0.8, 0.5)
	else:
		_throttle_slider.modulate = Color.WHITE

	# Rudder
	var rudder: float = snap.get("rudder", 0.0)
	_rudder_label.text = "Rudder: %s" % _rudder_text(rudder)
	_rudder_slider.value = rudder

	# Visibility indicator (matches in-game UI mapping)
	var flags: int = snap.get("flags", 0)
	var detection_type: int = (flags >> 1) & 0x03
	_apply_visibility(detection_type)

	# Reload bars
	var guns: Array = snap.get("guns", [])
	for i in min(guns.size(), _reload_bars.size()):
		var r: float = guns[i].get("reload", 0.0)
		_reload_bars[i].value = clampf(r, 0.0, 1.0)
		# Tint: red while reloading, green when ready
		if r >= 0.999:
			_reload_bars[i].modulate = Color(0.4, 1.0, 0.4)
		else:
			_reload_bars[i].modulate = Color(1.0, 0.5, 0.4)

	# Fires
	var fire_mask: int = snap.get("fire_mask", 0)
	for i in _fire_icons.size():
		if not _fire_icons[i].visible:
			continue
		_fire_icons[i].color = _FIRE_ACTIVE if ((fire_mask >> i) & 1) == 1 else _FIRE_INACTIVE

	# Floods
	var flood_mask: int = snap.get("flood_mask", 0)
	for i in _flood_icons.size():
		if not _flood_icons[i].visible:
			continue
		_flood_icons[i].color = _FLOOD_ACTIVE if ((flood_mask >> i) & 1) == 1 else _FLOOD_INACTIVE

	# Consumables (active = bit set in consumable_mask, indexed by slot_id)
	var cons_mask: int = snap.get("consumable_mask", 0)
	for w in _consumable_widgets:
		var sid: int = w["slot_id"]
		var active: bool = sid < 8 and ((cons_mask >> sid) & 1) == 1
		var panel: PanelContainer = w["panel"]
		var lbl: Label = w["label"]
		if active:
			panel.add_theme_stylebox_override("panel", _make_active_style())
			lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.4))
		else:
			panel.add_theme_stylebox_override("panel", _make_dim_style())
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

func _apply_visibility(detection_type: int) -> void:
	# 0 = NONE, 1 = LOS, 2 = HYDRO, 3 = RADAR (matches Ship.DetectionType)
	match detection_type:
		1:
			_visibility_color.color = Color(1, 1, 0, 0.9)   # yellow LOS
		2:
			_visibility_color.color = Color(0.4, 0.85, 1.0, 0.9)  # cyan hydro
		3:
			_visibility_color.color = Color(0.0, 0.706, 0.627, 1.0)  # teal radar
		_:
			_visibility_color.color = Color(0, 0, 0, 0)

func _apply_hp_bar_color(percent: float) -> void:
	if percent > 75:
		_hp_bar.modulate = Color(0.2, 0.9, 0.2)
	elif percent > 50:
		_hp_bar.modulate = Color(1.0, 1.0, 0.2)
	elif percent > 25:
		_hp_bar.modulate = Color(1.0, 0.6, 0.2)
	else:
		_hp_bar.modulate = Color(0.9, 0.2, 0.2)

func _rudder_text(v: float) -> String:
	if abs(v) < 0.1:
		return "Center"
	if v > 0:
		if v > 0.75: return "Hard Port"
		if v > 0.25: return "Port"
		return "Slight Port"
	if v < -0.75: return "Hard Starboard"
	if v < -0.25: return "Starboard"
	return "Slight Starboard"

func _set_followed_widgets_visible(v: bool) -> void:
	_hp_bar.get_parent().visible = v
	_reload_bars_container.visible = v
	_consumables_container.visible = v
	_speed_label.visible = v
	_throttle_label.visible = v
	_rudder_label.visible = v
	_throttle_slider.visible = v
	_rudder_slider.visible = v

# ---------------------------------------------------------------------------
# Team tracker
# ---------------------------------------------------------------------------
func _build_team_tracker() -> void:
	if _friendlies_container == null or _enemies_container == null:
		return
	for c in _friendlies_container.get_children():
		c.queue_free()
	for c in _enemies_container.get_children():
		c.queue_free()
	_team_indicators.clear()

	for gs in _ghost_ships:
		if gs == null or not is_instance_valid(gs):
			continue
		var entry: Dictionary = gs.ship_entry
		var team_id: int = entry.get("team_id", 0)
		var is_friendly: bool = (team_id == _local_team_id)
		var parent: HBoxContainer = _friendlies_container if is_friendly else _enemies_container

		var widget := _build_team_indicator(entry, is_friendly)
		parent.add_child(widget["root"])
		_team_indicators[gs] = widget

func _build_team_indicator(entry: Dictionary, is_friendly: bool) -> Dictionary:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)

	var label := Label.new()
	label.text = entry.get("ship_name", "?").substr(0, 8)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color",
		Color(0.6, 1.0, 0.6) if is_friendly else Color(1.0, 0.5, 0.5))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(label)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 100
	bar.custom_minimum_size = Vector2(60, 6)
	bar.modulate = Color(0.4, 1.0, 0.4) if is_friendly else Color(1.0, 0.4, 0.4)
	vbox.add_child(bar)

	return {"root": vbox, "label": label, "bar": bar}

func _update_team_tracker() -> void:
	if _playback == null:
		return
	for gs in _team_indicators:
		if gs == null or not is_instance_valid(gs):
			continue
		var widget: Dictionary = _team_indicators[gs]
		var bar: ProgressBar = widget["bar"]
		if gs.is_sunk:
			bar.value = 0.0
			bar.modulate = Color(0.3, 0.3, 0.3)
			continue
		if gs.max_hp > 0.0:
			bar.value = clampf((gs.current_hp / gs.max_hp) * 100.0, 0.0, 100.0)

# ---------------------------------------------------------------------------
# Event handling
# ---------------------------------------------------------------------------
func _on_event_fired(ev: Dictionary) -> void:
	# Always observe for torpedo attribution, regardless of followed ship.
	if _stats:
		_stats.observe_for_attribution(ev)
		_stats.handle_event(ev, false)

	if ev.get("type", -1) == ReplayEvent.SHIP_SUNK:
		_add_kill_feed_entry(ev)

func _on_seek_jumped(t: float) -> void:
	if _stats == null or _playback == null or _playback.reader == null:
		return
	# Rebuild stats from t=0 so totals are exact at the new playhead.
	_stats.reset()
	_stats.clear_attribution()
	var events: Array = _playback.reader.read_events_in_range(0.0, t)
	for ev in events:
		_stats.observe_for_attribution(ev)
	_stats.replay_events(events)
	# Silent replay doesn't push damage_events, so HitStatCounters won't
	# auto-refresh its labels. Force a refresh now.
	if _stat_counters:
		_stat_counters.update_counters()

func _add_kill_feed_entry(ev: Dictionary) -> void:
	if _kill_feed == null or _playback == null or _playback.reader == null:
		return
	var victim_id: int = ev.get("victim_ship_id", -1)
	var sinker_id: int = ev.get("sinker_ship_id", -1)
	var damage_type: int = ev.get("damage_type", 0)

	var victim_entry := _ship_manifest_entry(victim_id)
	var sinker_entry := _ship_manifest_entry(sinker_id)

	_kill_feed.add_kill(
		sinker_entry.get("ship_name", "?"),
		sinker_entry.get("player_name", ""),
		sinker_entry.get("team_id", -1),
		damage_type,
		victim_entry.get("ship_name", "?"),
		victim_entry.get("player_name", ""),
		victim_entry.get("team_id", -1),
		_local_team_id,
	)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _ship_manifest_entry(ship_id: int) -> Dictionary:
	if _playback == null or _playback.reader == null:
		return {}
	for entry in _playback.reader.ships:
		if entry.get("ship_id", -1) == ship_id:
			return entry
	return {}

func _ghost_ship_for(ship_id: int) -> GhostShip:
	for gs in _ghost_ships:
		if gs == null or not is_instance_valid(gs):
			continue
		if gs.ship_entry.get("ship_id", -1) == ship_id:
			return gs
	return null

func _team_id_for_ship(ship_id: int) -> int:
	var e := _ship_manifest_entry(ship_id)
	return e.get("team_id", 0)

func _make_dark_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.05, 0.1, 0.75)
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s

func _make_dim_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.08, 0.08, 0.1, 0.75)
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_color = Color(0.3, 0.3, 0.35, 0.8)
	s.corner_radius_top_left = 3
	s.corner_radius_top_right = 3
	s.corner_radius_bottom_left = 3
	s.corner_radius_bottom_right = 3
	s.content_margin_left = 4
	s.content_margin_right = 4
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s

func _make_active_style() -> StyleBoxFlat:
	var s := _make_dim_style()
	s.bg_color = Color(0.25, 0.2, 0.05, 0.9)
	s.border_color = Color(1.0, 0.85, 0.2, 1.0)
	return s
