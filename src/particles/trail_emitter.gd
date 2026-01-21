extends Node3D
class_name TrailEmitter

## GPU-based trail emitter for particle effects along a moving path.
## Uses UnifiedParticleSystem's GPU emitter API to emit particles along the path traveled.
## General purpose emitter that works with any particle template (wakes, trails, smoke, etc.)

@export_group("Template")
## The name of the particle template to use (must be registered in ParticleTemplateManager)
@export var template_name: String = "shell_trail"

@export_group("Emission")
## Particles emitted per unit distance traveled
@export var emit_rate: float = 0.1
## Scale multiplier for emitted particles
@export var size_multiplier: float = 1.0
## Time scale for particle simulation
@export var speed_scale: float = 1.0
## Extra velocity added in the direction of travel
@export var velocity_boost: float = 0.0

@export_group("Behavior")
## If true, starts emitting automatically when added to the scene
@export var auto_start: bool = false
## If true, updates position automatically in _process. Set to false for manual control.
@export var auto_update_position: bool = true

var _emitter_id: int = -1
var _unified_system: UnifiedParticleSystem = null
var _template_id: int = -1
var _is_active: bool = false
var _initialized: bool = false

signal emitter_started
signal emitter_stopped
signal initialization_failed(reason: String)


func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		set_process(false)
		return

	# Defer initialization to ensure particle system is ready
	_wait_for_particle_system()


func _process(_delta: float) -> void:
	if auto_update_position and _is_active and _emitter_id >= 0 and _unified_system != null:
		_unified_system.update_emitter_position(_emitter_id, global_position)


func _exit_tree() -> void:
	stop_emitting()


# ============================================================================
# INITIALIZATION
# ============================================================================

var _init_retry_count: int = 0
const MAX_INIT_RETRIES: int = 20  # 2 seconds max wait

func _wait_for_particle_system() -> void:
	"""Wait for particle system to be ready before initializing."""
	if _try_initialize():
		return

	# If not ready, create a timer and retry
	var timer = get_tree().create_timer(0.1)
	timer.timeout.connect(_on_init_timer_timeout)


func _on_init_timer_timeout() -> void:
	"""Retry initialization."""
	_init_retry_count += 1
	if _try_initialize():
		return

	if _init_retry_count < MAX_INIT_RETRIES:
		var timer = get_tree().create_timer(0.1)
		timer.timeout.connect(_on_init_timer_timeout)
	else:
		var reason = "Timed out waiting for particle system"
		push_warning("TrailEmitter: %s" % reason)
		initialization_failed.emit(reason)


func _try_initialize() -> bool:
	"""Try to initialize the emitter. Returns true if successful."""
	# Get ParticleSystemInit autoload
	if not has_node("/root/ParticleSystemInit"):
		return false

	var particle_init = get_node("/root/ParticleSystemInit")

	# Get unified particle system
	_unified_system = particle_init.unified_system
	if _unified_system == null:
		return false

	# Get template ID
	if particle_init.template_manager != null:
		_template_id = particle_init.template_manager.get_template_id(template_name)

	if _template_id < 0:
		# Template not registered yet, keep waiting
		return false

	_initialized = true

	if auto_start:
		start_emitting()

	return true


# ============================================================================
# PUBLIC API
# ============================================================================

func start_emitting() -> void:
	"""Start emitting particles. Allocates a GPU emitter."""
	if not _initialized:
		push_warning("TrailEmitter: Cannot start - not initialized yet")
		return

	if _unified_system == null or _template_id < 0:
		push_warning("TrailEmitter: Cannot start - system or template not available")
		return

	if _emitter_id >= 0:
		# Already emitting
		return

	_emitter_id = _unified_system.allocate_emitter(
		_template_id,
		global_position,
		size_multiplier,
		emit_rate,
		speed_scale,
		velocity_boost
	)

	if _emitter_id >= 0:
		_is_active = true
		emitter_started.emit()
	else:
		push_warning("TrailEmitter: Failed to allocate emitter (pool may be full)")


func stop_emitting() -> void:
	"""Stop emitting and free the GPU emitter."""
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.free_emitter(_emitter_id)
		emitter_stopped.emit()

	_emitter_id = -1
	_is_active = false


func is_emitting() -> bool:
	"""Returns true if currently emitting."""
	return _is_active and _emitter_id >= 0


func is_initialized() -> bool:
	"""Returns true if the emitter has been successfully initialized."""
	return _initialized


func get_emitter_id() -> int:
	"""Returns the GPU emitter ID, or -1 if not emitting."""
	return _emitter_id


func get_template_id() -> int:
	"""Returns the template ID being used, or -1 if not initialized."""
	return _template_id


# ============================================================================
# PARAMETER UPDATES
# ============================================================================

func set_template(new_template_name: String) -> bool:
	"""
	Change the particle template. Must stop and restart emitting for this to take effect.
	Returns true if the template was found, false otherwise.
	"""
	if not _initialized or _unified_system == null:
		template_name = new_template_name
		return true  # Will be applied on initialization

	var particle_init = get_node("/root/ParticleSystemInit")
	if particle_init == null or particle_init.template_manager == null:
		return false

	var new_id = particle_init.template_manager.get_template_id(new_template_name)
	if new_id < 0:
		push_warning("TrailEmitter: Template '%s' not found" % new_template_name)
		return false

	template_name = new_template_name
	_template_id = new_id

	# If currently emitting, restart with new template
	if _is_active:
		stop_emitting()
		start_emitting()

	return true


func set_size(new_size: float) -> void:
	"""Update the size multiplier for emitted particles."""
	size_multiplier = new_size
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, size_multiplier, -1.0, -1.0)


func set_emit_rate(new_rate: float) -> void:
	"""Update the emit rate (particles per unit distance)."""
	emit_rate = new_rate
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, -1.0, emit_rate, -1.0)


func set_velocity_boost(new_boost: float) -> void:
	"""Update the velocity boost for emitted particles."""
	velocity_boost = new_boost
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, -1.0, -1.0, velocity_boost)


func set_speed_scale(new_speed_scale: float) -> void:
	"""
	Update the speed scale for particle simulation.
	Note: This requires restarting the emitter to take effect.
	"""
	speed_scale = new_speed_scale
	if _is_active:
		stop_emitting()
		start_emitting()


func set_all_params(new_size: float, new_emit_rate: float, new_velocity_boost: float) -> void:
	"""Update all emitter parameters at once."""
	size_multiplier = new_size
	emit_rate = new_emit_rate
	velocity_boost = new_velocity_boost
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, size_multiplier, emit_rate, velocity_boost)


# ============================================================================
# MANUAL POSITION CONTROL
# ============================================================================

func update_position(pos: Vector3) -> void:
	"""
	Manually update the emitter position.
	Use this when auto_update_position is false, or when the emitter
	is not a child of the moving object.
	"""
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.update_emitter_position(_emitter_id, pos)
