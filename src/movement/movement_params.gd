extends Moddable
class_name MovementParams

# Top speed and acceleration
@export var max_speed_knots: float = 30.0
@export var acceleration_time: float = 8.0
@export var deceleration_time: float = 4.0
@export var reverse_speed_ratio: float = 0.5

# Turning
@export var turning_circle_radius: float = 200.0
@export var slow_speed_turn_tightening: float = 0.8
@export var turn_speed_loss: float = 0.2
@export var rudder_response_time: float = 1.5


# Hull / hydrodynamics
@export var lateral_drag_multiplier: float = 1.7

# Roll and stability
@export var max_turn_roll_angle: float = 8.0
@export var roll_response_time: float = 2.0
@export var righting_strength: float = 5.0
@export var righting_damping: float = 3.0
@export var pitch_righting_strength: float = 8.0
