extends Node
class_name FireManager

@export var params: FireParams
#var _params: FireParams
@export var fires: Array[Fire] = []
var _ship: Ship

# func reset_dynamic_mod(): # copy static to dynamic
# 	# _params = params.static_mod.duplicate(true)
# 	# _params.init(params)
# 	params.reset_dynamic_mod()

# func update_static_mod():
# 	# _params = params.static_mod.duplicate(true)
# 	# _params.init(params)
# 	params.update_static_mod()

# func reset_static_mod():
# 	# _params = params.duplicate(true)
# 	# _params.init(params)
# 	params.reset_static_mod()

func _ready() -> void:
	await get_parent().get_parent().ready
	params.init(_ship)
	# _params = params.duplicate(true)
	# _params.init(params)
	for f in fires:
		f.manager = self
	
	# _ship.reset_mods.connect(params.reset)
	# _ship.reset_dynamic_mods.connect(params.reset_dynamic_mod)
