extends ShipModule
class_name Concealment

@export var params: ConcealmentParams
var bloom_value: float = 0.0
var bloom_radius: float = 0.0

var blooms: Dictionary[float, float] = {} # value : time_remaining
# var bloom_radii: Dictionary[float, float] = {} # radius : time_remaining
var bloom_while_not_visible: float = 0.0
var prev_visible: bool = false
var last_spotted_time: float = -101.0

## Which channel is holding us. Ranked for attribution by _SPOT_RANK, not by
## their ordinals — the three last-known-position channels are worth the same, so
## credit between them falls to distance. Only eyes on outrank them.
enum SpotSource { NONE = 0, AIR = 1, HYDRO = 2, RADAR = 3, LOS = 4 }

const _SPOT_RANK: Dictionary = {
	SpotSource.NONE: 0,
	SpotSource.AIR: 1,
	SpotSource.HYDRO: 1,
	SpotSource.RADAR: 1,
	SpotSource.LOS: 2,
}

## Enemy ship the other team has to thank for holding us: eyes on, the pinging
## hydro/radar, or the carrier whose aircraft are overhead (planes have no stat
## line, so the credit lands on their carrier). Rebuilt every server detection
## frame, never latched — spotting damage is for damage taken WHILE lit.
var spotted_by: Ship = null
var spot_source: SpotSource = SpotSource.NONE
## Last frame anything at all held us. last_spotted_time is LOS-only because the
## bloom rules key on LOS.
var last_detected_time: float = -101.0

var _pending_spotter: Ship = null
var _pending_source: SpotSource = SpotSource.NONE
var _pending_dist: float = INF

func _ready() -> void:
	params = params.instantiate(_ship) as ConcealmentParams
	_ship.concealment = self


func _physics_process(delta: float) -> void:
	if not _Utils.authority():
		return

	if blooms.size() == 0:
		bloom_value = 0.0
		bloom_radius = params.p().radius
		if _ship.visible_to_enemy:
			last_spotted_time = Time.get_ticks_msec() / 1000.0
		prev_visible = _ship.visible_to_enemy
		return

	# handle bloom while not visible
	if !_ship.visible_to_enemy:
		if prev_visible: # ship was visible now isn't
			bloom_while_not_visible = 1.0
			last_spotted_time = Time.get_ticks_msec() / 1000.0
		bloom_while_not_visible -= delta / params.p().unspotted_bloom_duration
		if bloom_while_not_visible <= 0.0:
			blooms.clear()
			bloom_value = 0.0
			bloom_radius = params.p().radius
	else:
		bloom_while_not_visible = 0.0
		last_spotted_time = Time.get_ticks_msec() / 1000.0

	# update bloom values
	var to_remove: Array[float] = []
	var max_bloom: float = 0.0
	var min_bloom_value: float = 0.0
	for amount in blooms.keys():
		blooms[amount] -= delta / params.p().bloom_duration
		if blooms[amount] <= 0.0:
			to_remove.append(amount)
		else:
			if amount > max_bloom:
				max_bloom = amount
			if blooms[amount] > min_bloom_value:
				min_bloom_value = blooms[amount]
	bloom_value = min_bloom_value
	for amount in to_remove:
		blooms.erase(amount)
	bloom_radius = max(max_bloom, params.p().radius)


## Called by the server alongside the det_* flag reset.
func begin_spot_frame() -> void:
	_pending_spotter = null
	_pending_source = SpotSource.NONE
	_pending_dist = INF


## Higher rank wins; at equal rank, the nearest spotter does.
func propose_spotter(spotter: Ship, source: SpotSource, dist: float) -> void:
	if spotter == null or source == SpotSource.NONE:
		return
	var rank: int = _SPOT_RANK[source]
	var pending_rank: int = _SPOT_RANK[_pending_source]
	if rank < pending_rank:
		return
	if rank == pending_rank and dist >= _pending_dist:
		return
	_pending_spotter = spotter
	_pending_source = source
	_pending_dist = dist


## Returns the source in force before this frame, so the caller can tell a fresh
## contact from one already being held.
func commit_spot_frame(now: float) -> SpotSource:
	var prev := spot_source
	spotted_by = _pending_spotter
	spot_source = _pending_source
	if spot_source != SpotSource.NONE:
		last_detected_time = now
	return prev


func bloom(amount: float) -> void:
	blooms[amount] = 1.0
	if !_ship.visible_to_enemy:
		bloom_while_not_visible = 1.0

func get_concealment() -> float:
	return bloom_radius

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(bloom_value)
	writer.put_float(bloom_radius)
	writer.put_var(params.dynamic_mod.to_bytes())
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	bloom_value = reader.get_float()
	bloom_radius = reader.get_float()
	var mod_bytes = reader.get_var()
	params.dynamic_mod.from_bytes(mod_bytes)
