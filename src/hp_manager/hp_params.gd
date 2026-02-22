extends Moddable
class_name HPParams

# @export var max_hp: float = 10000.0
@export var citadel_repair: float = 0.15
@export var pen_repair: float = 0.5
@export var light_repair: float = 0.9

@export var torpedo_protection: float = 0.0

# No need for @export — Moddable.create_copy() copies ALL script variables,
# including plain vars, so this will be properly propagated to
# static_mod / dynamic_mod layers.
var mult: float = 1.0
