extends Skill

## Precision Lock — Tier 4.
## All guns must be fully loaded, aimed (can_fire), and the aim point must lie
## within 400 m of an enemy's leading position (full ballistic-with-drag solve,
## same as Gun._aim_leading).
##
## Buildup phase: 10 s delay then –2%/s up to –20%.
## Firing: the built-up accuracy is frozen and applied for 10 s after the
##         salvo, then completely reset (delay + buildup both wiped).
## Conditions broken (not firing): 5 s grace then 4%/s decay.
## Switching target: –10% buildup + delay resets.

const max_bonus:        float = 0.20   # –20% max dispersion reduction
const buildup_rate:     float = 0.02   # 2%/s buildup
const delay_time:       float = 10.0   # seconds before buildup starts
const lock_radius:      float = 1500.0  # metres: aim_point to predicted target pos
const decay_delay_time: float = 5.0    # grace seconds before decay begins
const decay_rate:       float = 0.01   # 4%/s decay
const switch_penalty:   float = 0.50   # –10% absolute buildup on target switch
const buff_duration:    float = 10.0   # seconds the reduction is held after firing

var _spread_reduction:  float = 0.0
var _delay_timer:       float = 0.0
var _decay_delay_timer: float = 0.0
var _current_target:    Ship  = null
var _buff_timer:        float = 0.0    # counts down during post-fire window
var _prev_all_ready:    bool  = false  # previous frame's ready state for edge detection

func _init():
	name = "Precision Lock"
	tier = 4
	cost = 4
	icon = load("res://icons/precision_lock.svg")
	flavor_text = "Hold your aim on the target's predicted path. The guns will find their mark."
	tooltip_stats = [
		{"stat": "Lock radius", "value": "%.0f m" % lock_radius},
		{"stat": "Delay before buildup", "value": "%.0f s" % delay_time},
		{"stat": "Buildup rate", "value": "–%.0f%% / s" % (buildup_rate * 100), "positive": true},
		{"stat": "Max dispersion reduction", "value": "–%.0f%%" % (max_bonus * 100), "positive": true},
		{"stat": "Post-fire buff duration", "value": "%.0f s" % buff_duration},
		{"stat": "Grace period before decay", "value": "%.0f s" % decay_delay_time},
		{"stat": "Decay rate", "value": "+%.0f%% / s" % (decay_rate * 100), "positive": false},
		{"stat": "Target switch penalty", "value": "–%.0f%% buildup" % (switch_penalty * 100), "positive": false},
	]

func _a(ship: Ship) -> void:
	var main := ship.artillery_controller.params.dynamic_mod as GunParams
	main.base_spread *= (1.0 - _spread_reduction)

func _proc(delta: float) -> void:
	var ac := _ship.artillery_controller

	# ── Determine ready state and detect firing edge ──────────────────────────
	var all_ready := true
	for gun: Gun in ac.guns:
		if gun.reload < 1.0 or not gun.can_fire:
			all_ready = false
			break

	var just_fired: bool = _prev_all_ready and not all_ready
	_prev_all_ready = all_ready

	# Firing while there is buildup → freeze the buff and start the countdown.
	if just_fired and _spread_reduction > 0.0:
		_buff_timer        = buff_duration
		_delay_timer       = 0.0
		_decay_delay_timer = 0.0
		_current_target    = null

	# ── Buff window: hold reduction, count down, then hard-reset ─────────────
	if _buff_timer > 0.0:
		_buff_timer -= delta
		if _buff_timer <= 0.0:
			_full_reset()
		return

	# ── Normal condition checks (only runs outside the buff window) ───────────
	if not all_ready:
		_on_conditions_lost(delta)
		return

	var server: GameServer = _ship.get_tree().root.get_node_or_null("/root/Server")
	if server == null:
		_on_conditions_lost(delta)
		return

	var enemies := server.get_valid_targets(_ship.team.team_id)
	if enemies.is_empty():
		_on_conditions_lost(delta)
		return

	# ── Aim must be within lock_radius of a predicted leading position ────────
	var aim_point := ac.aim_point
	var shell     := ac.get_shell_params()
	var ship_pos  := _ship.global_position
	var aim_2d    := Vector2(aim_point.x, aim_point.z)

	var best_dist:  float = INF
	var best_enemy: Ship  = null
	for enemy: Ship in enemies:
		# var result: Array = ProjectilePhysicsWithDragV2.calculate_leading_launch_vector(
		# 	ship_pos,
		# 	enemy.global_position,
		# 	enemy.linear_velocity,
		# 	shell
		# )
		# if result[0] == null:
		# 	continue
		var predicted_pos: Vector3 = enemy.global_position
		var d := aim_2d.distance_to(Vector2(predicted_pos.x, predicted_pos.z))
		if d < best_dist:
			best_dist = d
			best_enemy = enemy

	if best_dist > lock_radius or best_enemy == null:
		_on_conditions_lost(delta)
		return

	# ── All conditions met ────────────────────────────────────────────────────
	_decay_delay_timer = 0.0

	if _current_target != null and _current_target != best_enemy:
		_apply_switch_penalty()
	_current_target = best_enemy

	if _delay_timer < delay_time:
		_delay_timer += delta
		return

	_set_reduction(minf(_spread_reduction + buildup_rate * delta, max_bonus))

# ── Helpers ───────────────────────────────────────────────────────────────────

func _on_conditions_lost(delta: float) -> void:
	_delay_timer = 0.0
	_current_target = null
	_decay_delay_timer += delta
	if _decay_delay_timer < decay_delay_time:
		return
	_set_reduction(maxf(_spread_reduction - decay_rate * delta, 0.0))

func _apply_switch_penalty() -> void:
	_delay_timer = 0.0
	_set_reduction(maxf(_spread_reduction - switch_penalty, 0.0))

## Full wipe called when the post-fire buff window expires.
func _full_reset() -> void:
	_buff_timer        = 0.0
	_delay_timer       = 0.0
	_decay_delay_timer = 0.0
	_current_target    = null
	_set_reduction(0.0)

func _set_reduction(new_val: float) -> void:
	if abs(new_val - _spread_reduction) < 0.0005:
		_spread_reduction = new_val
		return
	_spread_reduction = new_val
	_ship.remove_dynamic_mod(_a)
	_ship.add_dynamic_mod(_a)

# ── Network serialization ─────────────────────────────────────────────────────

func to_bytes() -> PackedByteArray:
	var writer := StreamPeerBuffer.new()
	writer.put_float(_spread_reduction)
	writer.put_float(_delay_timer)
	writer.put_float(_decay_delay_timer)
	writer.put_float(_buff_timer)
	return writer.get_data_array()

func from_bytes(data: PackedByteArray) -> void:
	var reader := StreamPeerBuffer.new()
	reader.data_array = data
	_spread_reduction  = reader.get_float()
	_delay_timer       = reader.get_float()
	_decay_delay_timer = reader.get_float()
	_buff_timer        = reader.get_float()

# ── Battle HUD indicator ──────────────────────────────────────────────────────

func init_ui(control: Control) -> void:
	var ui: PackedScene = load("res://Skills/skill_ui/precision_lock.tscn")
	var root := ui.instantiate()
	var desired_size := 30.0
	var texture_size := 256.0
	var s := desired_size / texture_size
	root.scale = Vector2(s, s)
	control.custom_minimum_size = Vector2(desired_size, desired_size)
	control.size = Vector2(desired_size, desired_size)
	control.add_child(root)

func update_ui(container: Control) -> void:
	var active := _spread_reduction > 0.0 or _delay_timer > 0.0 or _decay_delay_timer > 0.0 or _buff_timer > 0.0
	if not active:
		container.visible = false
		return
	container.visible = true
	var root        := container.get_child(0) as Control
	var delay_bar   := root.get_child(0) as TextureProgressBar
	var buildup_bar := root.get_child(1) as TextureProgressBar
	buildup_bar.value = _spread_reduction / max_bonus
	if _buff_timer > 0.0:
		# During the post-fire window show the buff countdown on the delay bar.
		delay_bar.value = _buff_timer / buff_duration
	else:
		delay_bar.value = _delay_timer / delay_time

# ── Port preview ──────────────────────────────────────────────────────────────

var _preview_pct: float = 0.0

func preview_at_reduction(pct: float) -> void:
	_spread_reduction = pct / 100.0
	if _ship != null:
		_ship.remove_dynamic_mod(_a)
		_ship.add_dynamic_mod(_a)

func build_preview_modal(container: Control, on_change: Callable) -> void:
	var label := Label.new()
	label.text = "Simulate buildup %"
	container.add_child(label)

	var hbox := HBoxContainer.new()
	container.add_child(hbox)

	var val_label := Label.new()
	val_label.text = "%.0f%%" % _preview_pct
	val_label.custom_minimum_size = Vector2(44, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = _preview_pct
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(slider)
	hbox.add_child(val_label)

	slider.value_changed.connect(func(v: float) -> void:
		_preview_pct = v
		val_label.text = "%.0f%%" % v
		preview_at_reduction(v * max_bonus)
		on_change.call()
	)
