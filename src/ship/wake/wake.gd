extends CSGSphere3D

@onready var t = $Timer
var vel: Vector2

func _ready() -> void:
	t.timeout.connect(queue_free)

func _physics_process(delta: float) -> void:
	self.global_position += Vector3(vel.x, -4.5, vel.y) * delta
	self.scale += Vector3.ONE * delta
