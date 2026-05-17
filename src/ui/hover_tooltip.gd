# Custom hover-tooltip overlay used by the in-battle HUD.
#
# Why this exists:
# Godot's built-in Control.tooltip_text system is suppressed while a modifier
# key (e.g. Ctrl) is held, and the tooltip-delay timer is also continuously
# reset by the stream of echo key events that holding Ctrl generates. In this
# project Ctrl is exactly the modifier the player uses to release the cursor
# and interact with the HUD, so the engine's tooltips effectively never appear
# on the weapon / consumable buttons.
#
# Control.mouse_entered / mouse_exited still fire normally while Ctrl is held,
# so we drive a custom popup off those signals instead. This avoids per-widget
# manual hover detection (the pattern used in hit_stat_counters) by reusing a
# single overlay node across every registered Control.
class_name HoverTooltip
extends PanelContainer

const SHOW_DELAY: float = 0.25
const CURSOR_OFFSET: Vector2 = Vector2(16, 16)
const SCREEN_MARGIN: float = 8.0

var _label: Label
var _current_target: Control = null
var _current_text_provider: Callable = Callable()
var _show_timer: float = 0.0
var _pending_show: bool = false

# attach_content() registrations: pre-built Control panels whose visibility we
# toggle on hover. Each entry tracks its own pending delay timer so callers can
# use a faster delay than the cursor-following text tooltips above.
var _content_targets: Dictionary = {}  # Control -> { content: Control, delay: float }
var _content_pending: Dictionary = {}  # Control -> remaining seconds until show
var _content_visible: Dictionary = {}  # Control -> Control (currently visible)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	z_index = 1000
	top_level = true  # position in absolute viewport coords, ignore parent transform

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	style.border_color = Color(0.6, 0.6, 0.7, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	add_theme_stylebox_override("panel", style)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	add_child(_label)

func _ready() -> void:
	set_process(true)

# Register a Control so hovering it shows `text_or_callable` as a tooltip.
# `text_or_callable` may be either a String (static) or a Callable returning
# String (evaluated each time the tooltip is shown, for live stats).
func attach(target: Control, text_or_callable) -> void:
	var provider: Callable
	if text_or_callable is Callable:
		provider = text_or_callable
	else:
		var text_str := String(text_or_callable)
		provider = func() -> String: return text_str

	target.mouse_entered.connect(_on_target_entered.bind(target, provider))
	target.mouse_exited.connect(_on_target_exited.bind(target))
	# Belt-and-suspenders: if the target is hidden / removed while hovered,
	# make sure we don't get stuck showing a stale popup.
	target.tree_exiting.connect(_on_target_exited.bind(target))
	target.hidden.connect(_on_target_exited.bind(target))

func _on_target_entered(target: Control, provider: Callable) -> void:
	_current_target = target
	_current_text_provider = provider
	_pending_show = true
	_show_timer = 0.0
	visible = false  # wait for delay before showing

func _on_target_exited(target: Control) -> void:
	if _current_target != target:
		return
	_current_target = null
	_current_text_provider = Callable()
	_pending_show = false
	_show_timer = 0.0
	visible = false

func _process(delta: float) -> void:
	if _pending_show and _current_target != null:
		_show_timer += delta
		if _show_timer >= SHOW_DELAY:
			_pending_show = false
			_show_now()

	if visible:
		_reposition()

	if not _content_pending.is_empty():
		var ready_targets: Array = []
		for target in _content_pending:
			_content_pending[target] -= delta
			if _content_pending[target] <= 0.0:
				ready_targets.append(target)
		for target in ready_targets:
			_content_pending.erase(target)
			var entry: Dictionary = _content_targets.get(target, {})
			var content: Control = entry.get("content", null)
			if content != null:
				content.visible = true
				_content_visible[target] = content

func _show_now() -> void:
	if not _current_text_provider.is_valid():
		return
	var text_val = _current_text_provider.call()
	if typeof(text_val) != TYPE_STRING or (text_val as String).is_empty():
		return
	_label.text = text_val
	reset_size()
	visible = true
	_reposition()

func _reposition() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var mouse_pos := vp.get_mouse_position()
	var vp_size := vp.get_visible_rect().size
	var pos := mouse_pos + CURSOR_OFFSET
	reset_size()
	var sz := size
	# Flip to the other side of the cursor if we would clip the viewport edge.
	if pos.x + sz.x + SCREEN_MARGIN > vp_size.x:
		pos.x = mouse_pos.x - sz.x - CURSOR_OFFSET.x
	if pos.y + sz.y + SCREEN_MARGIN > vp_size.y:
		pos.y = mouse_pos.y - sz.y - CURSOR_OFFSET.y
	pos.x = clamp(pos.x, SCREEN_MARGIN, vp_size.x - sz.x - SCREEN_MARGIN)
	pos.y = clamp(pos.y, SCREEN_MARGIN, vp_size.y - sz.y - SCREEN_MARGIN)
	global_position = pos

# Register `target` so hovering it shows the pre-built `content` Control.
# Unlike attach(), this does NOT reposition the content — the caller owns its
# layout (anchors, parent, etc.). HoverTooltip only flips content.visible based
# on the target's mouse_entered/mouse_exited signals (which Godot still fires
# while Ctrl is held — that's why we route everything through here).
#
# `delay` defaults to 0.0 so panels like the hit-counter drill-downs appear
# instantly, matching the prior polling-based behavior. Pass a positive value
# (or use HoverTooltip.SHOW_DELAY) for a hover-intent style delay.
func attach_content(target: Control, content: Control, delay: float = 0.0) -> void:
	_content_targets[target] = {"content": content, "delay": max(delay, 0.0)}
	target.mouse_entered.connect(_on_content_target_entered.bind(target))
	target.mouse_exited.connect(_on_content_target_exited.bind(target))
	target.tree_exiting.connect(_on_content_target_exited.bind(target))
	target.hidden.connect(_on_content_target_exited.bind(target))

# Some Controls (e.g. hit counters with 0 count) are toggled invisible to
# declutter the HUD. When they become visible again Godot won't fire any enter
# event until the cursor actually crosses their rect. That's the desired
# behavior — we just have to make sure we don't leave a stale popup behind, so
# we also listen for `hidden` on the target (above).
func _on_content_target_entered(target: Control) -> void:
	var entry: Dictionary = _content_targets.get(target, {})
	var content: Control = entry.get("content", null)
	if content == null:
		return
	var delay: float = entry.get("delay", 0.0)
	if delay <= 0.0:
		content.visible = true
		_content_visible[target] = content
	else:
		_content_pending[target] = delay

func _on_content_target_exited(target: Control) -> void:
	_content_pending.erase(target)
	if _content_visible.has(target):
		var content: Control = _content_visible[target]
		if content != null:
			content.visible = false
		_content_visible.erase(target)
	else:
		# Even if we hadn't shown it yet (cancelled during delay), make sure the
		# registered content isn't accidentally left visible from elsewhere.
		var entry: Dictionary = _content_targets.get(target, {})
		var content: Control = entry.get("content", null)
		if content != null:
			content.visible = false
