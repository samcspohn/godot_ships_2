extends Moddable
class_name AviationParams

## Flight-deck parameters shared by every squadron on a carrier (as opposed to
## AircraftParams, which is per squadron). Lives on AviationController.

# Minimum time between takeoffs: after any squadron launches, no other squadron
# on this deck may launch until this many seconds have passed.
@export var min_takeoff_interval: float = 8.0

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_double(min_takeoff_interval)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	min_takeoff_interval = reader.get_double()
