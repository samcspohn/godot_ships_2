extends Skill

## Demolition Expert — BB / CA.
## Each visible enemy ship reduces main-gun reload time by 1 %, stacking up
## to 6 enemies (-6 % total). The mod is only re-baked when the spotted count
## actually changes, keeping overhead minimal.

const RELOAD_PER_ENEMY: float = 0.01
const MAX_STACKS: int = 6

func _init() -> void:
	name = "Demolition Expert"
	tier = 3
	cost = 3
	allowed_classes = [Ship.ShipClass.BB, Ship.ShipClass.CA]
	flavor_text = "Every enemy spotted is another reason to reload faster."
	tooltip_stats = [
		{"stat": "Reload per Spotted Enemy", "value": "-%.0f%% (max %d stacks, -%.0f%%)" % [RELOAD_PER_ENEMY * 100, MAX_STACKS, RELOAD_PER_ENEMY * MAX_STACKS * 100], "positive": true},
	]

var _reload_mod: float = 1.0
var _cached_spotted: int = -1  # -1 forces an update on first _proc tick

func _a(ship: Ship) -> void:
	(ship.artillery_controller.params.dynamic_mod as GunParams).reload_time *= _reload_mod

func _proc(_delta: float) -> void:
	var server: GameServer = _ship.get_tree().root.get_node_or_null("/root/Server")
	var spotted: int = 0
	if server != null:
		spotted = server.get_valid_targets(_ship.team.team_id).size()
		if spotted > MAX_STACKS:
			spotted = MAX_STACKS

	if spotted == _cached_spotted:
		return
	_cached_spotted = spotted

	if spotted == 0:
		_reload_mod = 1.0
	else:
		_reload_mod = 1.0 - RELOAD_PER_ENEMY * float(spotted)

	_ship.remove_dynamic_mod(_a)
	_ship.add_dynamic_mod(_a)
