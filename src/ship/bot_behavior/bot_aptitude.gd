extends Resource
class_name BotAptitude

## How good a bot is meant to be, as data rather than as branches.
##
## Deliberately NOT called a "skill": this codebase already uses that word twice
## - for captain skills the player picks (src/Skills/) and for the tactics a bot
## chooses between (src/ship/bot_behavior/skills/). A third meaning would make
## every future search for either of them ambiguous.
##
## One of these hangs off each Behavior, set at spawn (see
## GameServer._add_player). Every dial is a number a system reads, so a tier is
## a row in a table rather than a special case scattered through the AI. Nothing
## here may hand a bot information it has not earned through a channel that
## exists for every ship - what the higher tiers get is a better READ of the
## same battle, and where they eventually get more than that (see
## `intuition_interval`) it stays walled off in the positioning picture and out
## of reach of anything that fires.

enum Level {
	RECRUIT,   ## Believes only what the team has actually seen.
	REGULAR,   ## The baseline every bot behaved as before aptitude existed.
	VETERAN,   ## Reads the battle: thinks ahead, tracks where ships are going.
	ACE,       ## Reads it well, and periodically just knows.
}

## Which tier this is, as one of the Level constants. Typed int rather than
## Level so that ordinals coming out of a match config assign without fighting
## GDScript over int-versus-enum; Level stays the namespace the values are
## named in.
@export var level: int = Level.REGULAR

# ---------------------------------------------------------------------------
# Gunnery
# ---------------------------------------------------------------------------

## How stale a last-known position may be and still be offered to the guns.
## Was a flat constant on Behavior. Holding a dead-reckoned solution together
## while a ship is dark is a real gunnery skill, and it is the RIGHT place to
## express "better shot" - unlike intel, which the tiers must not differ on in
## any way a gun can read.
@export var lkp_target_max_age: float = 10.0

## Standard deviation of the error this bot makes judging how fast a target is
## going, as a fraction of the real speed. 0.2 means it typically leads a ship
## as if it were doing 20% more or less than it is - the classic novice miss,
## short or long along the target's own track rather than scattered at random.
##
## Held for AIM_ERROR_HOLD_MS at a time rather than re-rolled per shot. A fresh
## roll every frame would average out to a perfect solution over a salvo and
## just look like extra dispersion; a bot that is wrong about a ship's speed
## should stay wrong about it for a while, and then work it out.
@export var lead_speed_jitter: float = 0.0

## Whether this bot leads a turning target along its arc rather than along its
## instantaneous heading (ProjectilePhysicsWithDragV2 turning solver). Without
## it, shots at a ship under helm consistently miss to the outside of the turn.
@export var turn_reckoning: bool = false

## Standard deviation of the error this bot makes judging HOW HARD a target is
## turning, as a fraction of the real rate. Only meaningful with turn_reckoning
## on: it is the difference between seeing that a ship is turning and reading
## exactly how tight. Held on the same clock as lead_speed_jitter.
@export var turn_rate_jitter: float = 0.0

# ---------------------------------------------------------------------------
# Presumption - see EnemyPresumption, which reads all of these off whichever
# aptitude owns it (Behavior.get_presumed_contacts pushes them in).
# ---------------------------------------------------------------------------

## Whether this bot believes in ships nobody has ever seen. With
## it off the bot has only what the team has observed, which is how bots behaved
## before EnemyPresumption existed - it parks broadside to the flank nobody has
## looked at. That is what the bottom tier is supposed to look like.
@export var use_spawn_line: bool = true

## Multiplier on how fast a presumption's uncertainty radius
## opens up. Above 1 the bot loses confidence in its own picture quickly; below
## 1 it holds a coherent read of the battle for longer.
@export var radius_growth_mult: float = 1.0

## How far ahead this bot positions, in seconds. Zero means it
## solves for where the enemy is now - which is how a ship ends up behind an
## island that masks it this instant and leaves it naked once the push arrives.
@export var lead_horizon: float = 0.0

## Whether presumption projects a contact along the course and
## speed it was last observed making, rather than along the fleet's spawn axis.
## This is what lets a bot notice that a particular ship is pushing rather than
## that the enemy line in general is advancing.
@export var kinematic_reckoning: bool = false

## Seconds between ground-truth refreshes of this bot's own
## presumption anchors, or <= 0 to never refresh. This is the sanctioned cheat,
## and the reason it is a fix every so often rather than a live feed: the error
## bar grows between refreshes, so it plays as a good player's map read rather
## than as seeing through islands. It feeds the positioning picture ONLY - never
## get_contact_solution, never a gun.
@export var intuition_interval: float = 0.0


## The tier table. One place to read what separates a recruit from an ace.
static func for_level(l: int) -> BotAptitude:
	var a := BotAptitude.new()
	a.level = l
	match l:
		Level.RECRUIT:
			a.lkp_target_max_age = 5.0
			a.use_spawn_line = false
			a.radius_growth_mult = 1.6
			a.lead_horizon = 0.0
			a.kinematic_reckoning = false
			a.intuition_interval = 0.0
			a.lead_speed_jitter = 0.20
			a.turn_reckoning = false
			a.turn_rate_jitter = 0.0
		Level.REGULAR:
			a.lkp_target_max_age = 10.0
			a.use_spawn_line = true
			a.radius_growth_mult = 1.0
			a.lead_horizon = 0.0
			a.kinematic_reckoning = false
			a.intuition_interval = 0.0
			a.lead_speed_jitter = 0.10
			a.turn_reckoning = false
			a.turn_rate_jitter = 0.0
		Level.VETERAN:
			a.lkp_target_max_age = 14.0
			a.use_spawn_line = true
			a.radius_growth_mult = 0.8
			a.lead_horizon = 30.0
			a.kinematic_reckoning = true
			a.intuition_interval = 60.0
			a.lead_speed_jitter = 0.04
			a.turn_reckoning = true
			a.turn_rate_jitter = 0.30
		Level.ACE:
			a.lkp_target_max_age = 18.0
			a.use_spawn_line = true
			a.radius_growth_mult = 0.6
			a.lead_horizon = 60.0
			a.kinematic_reckoning = true
			a.intuition_interval = 30.0
			a.lead_speed_jitter = 0.0
			a.turn_reckoning = true
			a.turn_rate_jitter = 0.0
	return a


## Resolves whatever a match config put in the `aptitude` field to a tier.
## Accepts the enum ordinal or the tier name in any casing, so a lineup can be
## written as either 3 or "ace". Anything unrecognised is REGULAR, which is the
## behaviour every bot had before this existed.
static func from_config(value: Variant) -> BotAptitude:
	if value is BotAptitude:
		return value
	if value is int or value is float:
		var i := int(value)
		if i >= 0 and i < Level.keys().size():
			return for_level(i)
		return for_level(Level.REGULAR)
	if value is String:
		var key := String(value).strip_edges().to_upper()
		for name in Level.keys():
			if name == key:
				return for_level(int(Level[name]))
	return for_level(Level.REGULAR)


func level_name() -> String:
	return Level.keys()[level]


# ---------------------------------------------------------------------------
# DEALING A TEAM
# ---------------------------------------------------------------------------

## Relative share of a team each tier should take. Shaped like the spread of
## people you actually get in a match rather than flat: most of a team is
## competent, a couple are excellent, a few are out of their depth. Scaled to
## whatever the team size is, so these are proportions and not counts - at the
## usual twelve they work out to roughly 3 recruits, 5 regulars, 3 veterans and
## between one and two aces.
const LEVEL_WEIGHTS := {
	Level.RECRUIT: 3.0,
	Level.REGULAR: 5.0,
	Level.VETERAN: 3.5,
	Level.ACE:     1.5,
}

## `count` tiers making up one team, shuffled so a bot's quality has nothing to
## do with where it spawned.
##
## Dealt as a composition rather than rolled per bot. Independent rolls have the
## right average and the wrong matches: sooner or later a team comes up with five
## aces or none at all, and neither plays like the game is supposed to. This
## gives each tier its whole-number share, then hands the leftover slots out at
## random weighted by the fractions that were dropped - so the shape holds every
## match while which side gets the odd extra ace does not.
static func deal(count: int, rng: RandomNumberGenerator = null) -> Array[int]:
	var out: Array[int] = []
	if count <= 0:
		return out
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	var total_weight: float = 0.0
	for w in LEVEL_WEIGHTS.values():
		total_weight += float(w)
	if total_weight <= 0.0:
		for i in range(count):
			out.append(Level.REGULAR)
		return out

	# Whole-number share per tier, keeping what each was rounded down by.
	var remainders: Array[Dictionary] = []
	var dealt: int = 0
	for lv in LEVEL_WEIGHTS.keys():
		var exact: float = count * float(LEVEL_WEIGHTS[lv]) / total_weight
		var whole: int = int(floor(exact))
		for i in range(whole):
			out.append(int(lv))
		dealt += whole
		remainders.append({level = int(lv), frac = exact - float(whole)})

	# Leftover slots go to whoever was rounded down hardest, but by weighted draw
	# rather than by rank, so the composition breathes between matches.
	while dealt < count:
		var pool: float = 0.0
		for r in remainders:
			pool += float(r.frac)
		var pick: int = Level.REGULAR
		if pool <= 0.0:
			pick = int(remainders[rng.randi() % remainders.size()].level)
		else:
			var roll: float = rng.randf() * pool
			for r in remainders:
				roll -= float(r.frac)
				if roll <= 0.0:
					pick = int(r.level)
					# Spent: a tier cannot take two leftover slots on the
					# strength of one rounding.
					r.frac = 0.0
					break
		out.append(pick)
		dealt += 1

	# Shuffle in place with the same rng, so a seeded deal is fully reproducible.
	for i in range(out.size() - 1, 0, -1):
		var j: int = rng.randi() % (i + 1)
		var tmp: int = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out
