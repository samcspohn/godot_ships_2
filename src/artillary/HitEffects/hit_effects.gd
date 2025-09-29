extends Node
class_name HitEffects_

var splash: HitEffect
var he_explosion: HitEffect
var muzzle_blast: HitEffect
# var ap_explosion: HitEffect = $"AP_Explosion"
var sparks: HitEffect

var splash_pool: Array[HitEffect] = []
var he_explosion_pool: Array[HitEffect] = []
var ap_explosion_pool: Array[HitEffect] = []
var sparks_pool: Array[HitEffect] = []
var muzzle_blast_pool: Array[HitEffect] = []

var splash_material_cache: Dictionary[float, ParticleProcessMaterial] = {}
var he_explosion_material_cache: Dictionary[float, ParticleProcessMaterial] = {}
var sparks_material_cache: Dictionary[float, ParticleProcessMaterial] = {}
var muzzle_blast_material_cache: Dictionary[float, ParticleProcessMaterial] = {}

var splash_count: int = 0
var he_explosion_count: int = 0
var sparks_count: int = 0
var muzzle_blast_count: int = 0

# Pool sizes for preallocation
const POOL_SIZE_SPLASH: int = 50
const POOL_SIZE_HE_EXPLOSION: int = 15
const POOL_SIZE_SPARKS: int = 20
const POOL_SIZE_MUZZLE_BLAST: int = 30

func print_status() -> void:
	print("Splash count: ", splash_count, " Pool size: ", splash_pool.size(), "Active: ", splash_count - splash_pool.size())
	print("HE Explosion count: ", he_explosion_count, " Pool size: ", he_explosion_pool.size(), "Active: ", he_explosion_count - he_explosion_pool.size())
	print("Sparks count: ", sparks_count, " Pool size: ", sparks_pool.size(), "Active: ", sparks_count - sparks_pool.size())
	print("Muzzle Blast count: ", muzzle_blast_count, " Pool size: ", muzzle_blast_pool.size(), "Active: ", muzzle_blast_count - muzzle_blast_pool.size())
	get_tree().create_timer(5.0).timeout.connect(print_status)

func _ready() -> void:

	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

	splash = get_node("Splash") as HitEffect
	splash.emitting = false
	splash.visible = false
	splash.type = HitEffect.EffectType.SPLASH
	he_explosion = get_node("HE_Explosion") as HitEffect
	he_explosion.emitting = false
	he_explosion.visible = false
	he_explosion.type = HitEffect.EffectType.HE_EXPLOSION
	muzzle_blast = get_node("MuzzleBlast") as HitEffect
	muzzle_blast.emitting = false
	muzzle_blast.visible = false
	muzzle_blast.type = HitEffect.EffectType.MUZZLE_BLAST
	# ap_explosion = get_node("AP_Explosion") as HitEffect
	# ap_explosion.emitting = false
	# ap_explosion.visible = false
	sparks = get_node("Sparks") as HitEffect
	sparks.emitting = false
	sparks.visible = false
	sparks.type = HitEffect.EffectType.SPARKS

	# Preallocate pools to avoid lag spikes during gameplay
	_preallocate_pools()
	get_tree().create_timer(5.0).timeout.connect(print_status)

func _preallocate_pools() -> void:
	# Preallocate splash effects
	for i in range(POOL_SIZE_SPLASH):
		var p: HitEffect = splash.duplicate() as HitEffect
		p.visible = false
		p.emitting = false
		add_child(p)
		splash_pool.append(p)
	splash_count = POOL_SIZE_SPLASH
	
	# Preallocate HE explosion effects
	for i in range(POOL_SIZE_HE_EXPLOSION):
		var p: HitEffect = he_explosion.duplicate() as HitEffect
		p.visible = false
		p.emitting = false
		add_child(p)
		he_explosion_pool.append(p)
	he_explosion_count = POOL_SIZE_HE_EXPLOSION
	
	# Preallocate sparks effects
	for i in range(POOL_SIZE_SPARKS):
		var p: HitEffect = sparks.duplicate() as HitEffect
		p.visible = false
		p.emitting = false
		add_child(p)
		sparks_pool.append(p)
	sparks_count = POOL_SIZE_SPARKS
	
	# Preallocate muzzle blast effects
	for i in range(POOL_SIZE_MUZZLE_BLAST):
		var p: HitEffect = muzzle_blast.duplicate() as HitEffect
		p.visible = false
		p.emitting = false
		add_child(p)
		muzzle_blast_pool.append(p)
	muzzle_blast_count = POOL_SIZE_MUZZLE_BLAST

func splash_effect(pos: Vector3, size: float) -> void:
	var p: HitEffect
	if splash_pool.size() > 0:
		p = splash_pool.pop_back()
	else:
		p = splash.duplicate() as HitEffect
		add_child(p)
		splash_count += 1

	p.global_transform.origin = pos
	p.scale = Vector3(size, size, size)
	if not splash_material_cache.has(size):
		var mat: ParticleProcessMaterial = splash.process_material.duplicate() as ParticleProcessMaterial
		mat.scale_min = size * 4
		splash_material_cache[size] = mat
	p.process_material = splash_material_cache[size]
	p.speed_scale = 4 / size
	p.start_effect()

func he_explosion_effect(pos: Vector3, size: float) -> void:
	var p: HitEffect
	if he_explosion_pool.size() > 0:
		p = he_explosion_pool.pop_back()
	else:
		p = he_explosion.duplicate() as HitEffect
		add_child(p)
		he_explosion_count += 1
	
	p.global_transform.origin = pos
	p.scale = Vector3(size, size, size)
	if not he_explosion_material_cache.has(size):
		var mat: ParticleProcessMaterial = he_explosion.process_material.duplicate() as ParticleProcessMaterial
		mat.scale_min = size * size * 2
		mat.scale_max = size * size * 3
		he_explosion_material_cache[size] = mat
	p.process_material = he_explosion_material_cache[size]
	p.start_effect()

# func ap_explosion_effect(pos: Vector3) -> void:

func sparks_effect(pos: Vector3, size: float) -> void:
	var p: HitEffect
	if sparks_pool.size() > 0:
		p = sparks_pool.pop_back()
	else:
		p = sparks.duplicate() as HitEffect
		# p.pool = sparks_pool
		add_child(p)
		sparks_count += 1

	p.global_transform.origin = pos
	p.scale = Vector3(size, size, size)
	if not sparks_material_cache.has(size):
		var mat: ParticleProcessMaterial = sparks.process_material.duplicate() as ParticleProcessMaterial
		mat.scale_min = size * randf_range(0.3, 0.6)
		sparks_material_cache[size] = mat
	p.process_material = sparks_material_cache[size]
	p.start_effect()


func muzzle_blast_effect(pos: Vector3, basis: Basis, size: float) -> void:
	var p: HitEffect
	if muzzle_blast_pool.size() > 0:
		p = muzzle_blast_pool.pop_back()
	else:
		p = muzzle_blast.duplicate() as HitEffect
		# p.pool = muzzle_blast_pool
		add_child(p)
		muzzle_blast_count += 1

	p.global_transform.origin = pos
	p.global_transform.basis = basis
	p.speed_scale = 2.0 / size
	var s = pow(size, 1.75)
	p.scale = Vector3(s, s, s)
	if not muzzle_blast_material_cache.has(size):
		var mat: ParticleProcessMaterial = muzzle_blast.process_material.duplicate() as ParticleProcessMaterial
		mat.scale_min = s
		mat.scale_max = s * 1.5
		muzzle_blast_material_cache[size] = mat
	p.process_material = muzzle_blast_material_cache[size]
	p.start_effect()

func return_to_pool(effect: HitEffect) -> void:
	match effect.type:
		HitEffect.EffectType.SPLASH:
			splash_pool.append(effect)
		HitEffect.EffectType.HE_EXPLOSION:
			he_explosion_pool.append(effect)
		HitEffect.EffectType.SPARKS:
			sparks_pool.append(effect)
		HitEffect.EffectType.MUZZLE_BLAST:
			muzzle_blast_pool.append(effect)
		_:
			print("Unknown effect type in return_to_pool")
