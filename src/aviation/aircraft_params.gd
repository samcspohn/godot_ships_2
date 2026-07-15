extends Moddable
class_name AircraftParams

@export var type: String = "Spotter"
@export var squadron_size: int = 1
@export var hp: float = 1000.0 # per-aircraft hit points; depleted by AA fire
@export var formation_spacing: float = 60.0
@export var _range: float = 6000.0
@export var speed: float = 300.0
@export var turning_radius: float = 200.0
@export var catch_up_speed_mult: float = 1.5 # max speed multiplier used to catch up to a lagging target
@export var attack_catch_up_speed_mult: float = 3.0 # catch-up speed multiplier used instead while the squadron is on its attack run, so wingmen snap into the tighter attack formation faster
@export var spotting_range: float = 1000.0
@export var idle_radius: float = 1000.0
@export var circle_range: float = 2000.0 # orbit radius flown while holding station over an attack point (e.g. spotting)
@export var radio_range: float = 8000.0
@export var altitude: float = 200.0
@export var attack_altitude: float = -1.0 # altitude flown while attacking; negative uses `altitude`
@export var attack_descent_radius: float = 1000.0 # distance from the attack point at which the squadron descends to attack_altitude
@export var climb_rate: float = 100.0 # vertical speed used to reach a newly targeted altitude, independent of horizontal distance remaining
@export var return_altitude_mult: float = 2.0 # multiplier applied to `altitude` while cruising home after an attack run
@export var landing_descent_radius: float = 500.0 # distance from the launcher at which a returning squadron descends and tightens into landing formation
@export var ordnance_scene: PackedScene
@export var plane_scene: PackedScene

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_string(type)
	writer.put_double(_range)
	writer.put_double(speed)
	writer.put_double(spotting_range)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	type = reader.get_string()
	_range = reader.get_double()
	speed = reader.get_double()
	spotting_range = reader.get_double()
