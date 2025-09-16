extends Node3D

class_name OrbitCamera

@onready var camera: Camera3D = $"./Pitch/Camera3D"
@onready var yaw_node: Node3D = $"."
@onready var pitch_node: Node3D = $"./Pitch"

@export var distance: float = 400.0
@export var min_distance: float = 100.0
@export var max_distance: float = 800.0

@export var rotation_speed: float = 0.4
@export var require_rmb: bool = true # Require right mouse button hold to rotate
@export var min_height: float = 5.0

# Internal state
var target_distance: float
var target_yaw: float = 0.0
var target_pitch: float = 0.0
var mouse_rotating: bool = false

func _ready():
    target_distance = distance
    # If RMB is not required, allow rotation immediately
    mouse_rotating = not require_rmb
    # Position camera initially along -Z at the chosen distance
    _update_camera_transform()

func _update_camera_transform():
    # Ensure the camera stays above min_height by limiting pitch based on distance
    # For our setup the camera local position is (0,0,target_distance) and
    # rotation.x (pitch) produces world Y = -target_distance * sin(pitch).
    # Solve for pitch to satisfy -r * sin(pitch) >= min_height -> sin(pitch) <= -min_height/r
    var min_pitch_rad = deg_to_rad(-89.0)
    var max_pitch_rad = deg_to_rad(89.0)
    if target_distance > 0.0:
        var allowed = asin(clamp(-min_height / target_distance, -1.0, 1.0))
        # allowed is the maximum pitch (may be <= 0) that keeps camera above min_height
        max_pitch_rad = min(max_pitch_rad, allowed)

    # Clamp pitch to both avoid flipping and to maintain min height
    target_pitch = clamp(target_pitch, min_pitch_rad, max_pitch_rad)

    # Apply rotation directly
    yaw_node.rotation.y = target_yaw
    pitch_node.rotation.x = target_pitch
    # Place camera at fixed offset from origin along local -Z
    camera.transform.origin = Vector3(0, 0, target_distance)

func _input(event):
    if event is InputEventMouseMotion:
        # Rotate around origin with mouse movement only when allowed
        if not require_rmb or mouse_rotating:
            target_yaw -= deg_to_rad(event.relative.x * rotation_speed * 0.2)
            target_pitch -= deg_to_rad(event.relative.y * rotation_speed * 0.2)
            # Clamp pitch to avoid flipping (between -89 and 89 degrees)
            target_pitch = clamp(target_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
            _update_camera_transform()

    elif event is InputEventMouseButton:
        # Handle wheel zoom (still works regardless of RMB)
        if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
            target_distance = clamp(target_distance - 20.0, min_distance, max_distance)
            _update_camera_transform()
        elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            target_distance = clamp(target_distance + 20.0, min_distance, max_distance)
            _update_camera_transform()

        # Track right-mouse button hold for rotation when required
        if require_rmb and event.button_index == MOUSE_BUTTON_RIGHT:
            mouse_rotating = event.pressed
