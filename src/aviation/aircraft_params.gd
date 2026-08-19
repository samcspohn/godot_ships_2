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
@export var spotting_range: float = 2000.0 # radius within which this aircraft reveals enemy ships; spotter squadrons carry a far longer one so they can work from outside AA reach
@export var idle_radius: float = 1000.0
@export var circle_range: float = 2000.0 # orbit radius flown while holding station over an attack point (e.g. spotting)
@export var radio_range: float = 8000.0
@export var altitude: float = 200.0
@export var attack_altitude: float = -1.0 # altitude flown while attacking; negative uses `altitude`
@export var attack_descent_radius: float = 1000.0 # distance from the attack point at which the squadron descends to attack_altitude
@export var climb_rate: float = 100.0 # vertical speed used to reach a newly targeted altitude, independent of horizontal distance remaining
@export var return_altitude_mult: float = 2.0 # multiplier applied to `altitude` while cruising home after an attack run
@export var ordnance_reload_time: float = 40.0 # time after landing before the squadron has rearmed and can be launched again; only paid when it actually dropped its ordnance
@export var fuel_time: float = 180.0 # endurance: seconds a squadron can stay airborne before it runs low on fuel and turns for home on its own
@export var plane_regen_time: float = 100.0 # seconds to build one replacement aircraft; a squadron rebuilds its losses one plane at a time
@export var landing_descent_radius: float = 500.0 # distance from the launcher at which a returning squadron descends and tightens into landing formation
@export var ordnance_scene: PackedScene
@export var plane_scene: PackedScene

func to_bytes() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.put_string(type)
	writer.put_double(_range)
	writer.put_double(speed)
	writer.put_double(spotting_range)
	writer.put_double(ordnance_reload_time)
	writer.put_double(fuel_time)
	return writer.get_data_array()

func from_bytes(b: PackedByteArray) -> void:
	var reader = StreamPeerBuffer.new()
	reader.data_array = b
	type = reader.get_string()
	_range = reader.get_double()
	speed = reader.get_double()
	spotting_range = reader.get_double()
	ordnance_reload_time = reader.get_double()
	fuel_time = reader.get_double()
