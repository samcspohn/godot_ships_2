class_name SkillContext
extends RefCounted

var ship: Ship
var target: Ship              # current primary target (may be null)
var server: GameServer
var behavior: BotBehavior     # access to shared utilities
var navigator: ShipNavigator  # current ship navigator (for waypoint/path context)

static func create(s: Ship, t: Ship, srv: GameServer, b: BotBehavior) -> SkillContext:
	var ctx = SkillContext.new()
	ctx.ship = s
	ctx.target = t
	ctx.server = srv
	ctx.behavior = b
	ctx.navigator = b.get_navigator() if b != null else null
	return ctx
