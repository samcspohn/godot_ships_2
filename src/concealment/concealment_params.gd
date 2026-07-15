extends Moddable
class_name ConcealmentParams

@export var radius: float = 5000.0
@export var air_radius: float = 2500.0
@export var bloom_duration: float = 15.0
@export var unspotted_bloom_duration: float = 1.0
## Multiplicative modifier applied to a torpedo's base detection_range when
## this ship checks whether it can spot an incoming torpedo.
## 1.0 = no change; 1.5 = Torpedo Lookout System (+50%).
var torpedo_detection_multiplier: float = 1.0
## When > 0, acts as a minimum detection range floor (metres).
## Used by Hydroacoustic Search (3 000 m) to guarantee detection regardless
## of the torpedo's base range or the multiplier.
var torpedo_detection_range_override: float = -1.0
## When > 0, this ship can force-spot any enemy ship within this distance
## (metres) even if that ship's concealment radius would normally hide it.
## Used by Hydroacoustic Search (4 000 m).
var spotting_range_override: float = -1.0
## When > 0, same as spotting_range_override but sourced from Radar
## (8 000 m default).  Checked alongside spotting_range_override in
## handle_spot and the no-LOS radar detection pass.
var radar_spotting_range_override: float = -1.0
## When > 0, ships within this distance spot each other unconditionally
## regardless of terrain or smoke.  Uses the max of both ships' values.
var assured_acquisition_range: float = 1000.0

## Returns the effective torpedo detection range for this ship given the
## torpedo's base detection_range.
## Upgrades scale via torpedo_detection_multiplier; consumables like
## Hydroacoustic Search impose a minimum floor via torpedo_detection_range_override.
func get_torpedo_detection_range(base_range: float) -> float:
	var effective := base_range * torpedo_detection_multiplier
	if torpedo_detection_range_override > 0.0:
		effective = max(effective, torpedo_detection_range_override)
	return effective

func from_bytes(data: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = data
	radius = reader.get_float()
	bloom_duration = reader.get_float()
	unspotted_bloom_duration = reader.get_float()
	torpedo_detection_multiplier = reader.get_float()
	torpedo_detection_range_override = reader.get_float()
	spotting_range_override = reader.get_float()
	radar_spotting_range_override = reader.get_float()
	assured_acquisition_range = reader.get_float()

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_float(radius)
	writer.put_float(bloom_duration)
	writer.put_float(unspotted_bloom_duration)
	writer.put_float(torpedo_detection_multiplier)
	writer.put_float(torpedo_detection_range_override)
	writer.put_float(spotting_range_override)
	writer.put_float(radar_spotting_range_override)
	writer.put_float(assured_acquisition_range)
	return writer.data_array
