extends Resource
class_name TorpedoLauncherParams

@export var traverse_speed: float
@export var reload_time: float
@export var range: float
@export var torpedo_params: TorpedoParams

func from_params(params: TorpedoLauncherParams) -> void:
	traverse_speed = params.traverse_speed
	reload_time = params.reload_time
	range = params.range
	torpedo_params = params.torpedo_params
