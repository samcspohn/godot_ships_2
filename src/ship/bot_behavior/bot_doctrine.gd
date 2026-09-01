class_name BotDoctrine
extends RefCounted

## The numbers that make one bot play differently from another.
##
## Same move BotAptitude made for how GOOD a bot is, applied to how it FIGHTS:
## a doctrine is a row in a table rather than a branch buried in a per-class
## nav function. Everything here is read by the shared ladder in
## BotBehavior._nav_core(); nothing here contains logic.
##
## Step (a) of the unification: these rows reproduce exactly what bb_behav,
## ca_behav and dd_behav each hard-coded, so behaviour is unchanged and the
## three near-identical ladders collapse into one. Later steps derive these
## numbers from hull stats and situation instead of naming them per class,
## at which point archetypes ("sniping BB", "gunboat DD") become presets that
## override a few fields rather than scripts.

# ---------------------------------------------------------------------------
# Skill menu — which arms of the ladder exist for this bot at all
# ---------------------------------------------------------------------------

## Skills tried in order when no enemy is known to exist anywhere.
var idle_chain: Array[StringName] = [&"Hunt", &"SailForward"]

## Skills tried in order when enemies exist but none are spotted. Empty means
## this bot has no separate dark arm and falls through to the engaged ladder.
var dark_chain: Array[StringName] = []

## Whether the dark arm may take cover instead of chasing when threat is high.
var dark_takes_cover: bool = false

## Whether the close-quarters arm is gated on nearest_threat_dist < ra_threshold
## (BB/CA) or fires on detection alone (DD).
var close_arm_range_gated: bool = true

## Whether the close-quarters kite path first looks for cover along the way.
var close_arm_uses_cover: bool = true

## Whether the close arm aligns the hull with the desired-heading line before
## engaging reverse. Keeps a slow ship from swinging its broadside through a
## turn; a destroyer would rather just leave.
var close_arm_reverse_align: bool = true

## Whether a low threat score short-circuits the ladder before the distance
## check. CA decides on odds first: a cruiser that likes its chances pushes
## whether or not the enemy is close aboard. BB and DD check distance first.
var low_threat_arm_first: bool = false

## Whether a ladder that produced nothing falls back to sailing forward. With
## this off a behaviour may return null, which the controller reads as "hold the
## previous destination".
var universal_sail_forward_fallback: bool = false

## Whether the idle and dark arms get the broadside/spread post-processors. CA
## returned early from those arms and so never did.
var post_process_idle_arms: bool = true

# ---------------------------------------------------------------------------
# Threat thresholds — where the ladder switches between skills
# ---------------------------------------------------------------------------

## Below this threat the bot pushes rather than kites when engaged up close.
var push_threat: float = 0.5

## Threat below/above which the close arm refuses to be post-processed, so a
## committed push or a committed kite is not steered off course.
var force_below: float = 0.25
var force_above: float = 0.75

## Engaged-ladder thresholds. Only read by behaviours whose engaged arm uses
## them (BB); CA and DD override _select_engaged_skill entirely.
var flank_max_threat: float = 0.4
var camp_max_threat: float = 0.6
var cover_max_threat: float = 0.7

## Minimum distance to the nearest non-DD threat before cover is preferred to
## kiting at high threat.
var cover_min_threat_dist: float = 10000.0

## Threat above which a cruiser stops accepting cover that is off the
## engagement path and kites instead.
var cover_abandon_threat: float = 0.85

# ---------------------------------------------------------------------------
# Engagement range — how close this bot wants to fight, read off its build
# ---------------------------------------------------------------------------

## Fraction of main-battery range the bot fights at when the main battery is the
## only thing it has to bring to bear.
var gun_engage_ratio: float = 0.60

## How far the secondaries must reach, as a fraction of main-battery range,
## before they justify giving up standoff to use them. Below this the hull is a
## gunship that happens to carry secondaries, and the water it would cross to
## bring them into play costs more than the second battery is worth.
var secondary_commit_ratio: float = 0.5

## Where inside secondary range a brawler wants to sit. Short of the maximum,
## because a ship parked exactly on the edge of its own secondary range spends
## most of the fight drifting outside it.
var secondary_engage_ratio: float = 0.9

## Threat above which the bot stops trying to bring its secondaries to bear and
## reverts to main-battery range. Closing into a losing fight to use a shorter
## gun is how a brawler dies.
var secondary_yield_threat: float = 0.6

# ---------------------------------------------------------------------------
# Reverse-alignment band — how close a threat must be before the bot will back
# out of a turn rather than swing its broadside through it.
# ---------------------------------------------------------------------------

var ra_base: float = 8000.0
var ra_bb_shooter: float = 10000.0
var ra_bb_shooter_hurt: float = 13000.0
var ra_hurt_hp_ratio: float = 0.5

# ---------------------------------------------------------------------------
# Post-processing
# ---------------------------------------------------------------------------

## Apply the broadside post-process at all, and the skills it is skipped for.
var use_broadside: bool = true
var broadside_exclude: Array[StringName] = [&"Hunt", &"SailForward"]
var broadside_params: Dictionary = {}

var spread_exclude: Array[StringName] = [&"FindCover", &"Push", &"Kite"]
var spread_distance: float = 1000.0
var spread_multiplier: float = 1.0

## Skills that get their own spread tuning instead of the defaults above.
var spread_overrides: Dictionary = {}


# ---------------------------------------------------------------------------
# THE TABLE
# ---------------------------------------------------------------------------

static func for_battleship() -> BotDoctrine:
	var d := BotDoctrine.new()
	d.idle_chain = [&"Flank"]
	d.dark_chain = [&"Chase"]
	d.dark_takes_cover = true
	d.push_threat = 0.5
	d.force_below = 0.25
	d.force_above = 0.75
	d.flank_max_threat = 0.4
	d.camp_max_threat = 0.6
	d.cover_max_threat = 0.7
	d.cover_min_threat_dist = 10000.0
	d.gun_engage_ratio = 0.60
	d.ra_bb_shooter_hurt = 13000.0
	d.use_broadside = true
	d.broadside_exclude = [&"Hunt", &"SailForward"]
	d.broadside_params = {"oscillation_bias": 0.5}
	d.spread_exclude = [&"FindCover", &"Push", &"Kite", &"Camp"]
	d.post_process_idle_arms = true
	return d


static func for_cruiser() -> BotDoctrine:
	var d := BotDoctrine.new()
	d.idle_chain = [&"FindCover", &"Flank", &"Hunt", &"SailForward"]
	d.dark_chain = [&"Chase", &"Hunt", &"SailForward"]
	d.dark_takes_cover = true
	d.push_threat = 0.5
	d.gun_engage_ratio = 0.70
	d.ra_bb_shooter_hurt = 11000.0
	# The CA's broadside post-process is deliberately off: its engaged arm sets
	# heading_weight itself and a second opinion on heading fights it.
	d.use_broadside = false
	d.spread_exclude = [&"FindCover", &"Push", &"Kite"]
	d.low_threat_arm_first = true
	# CA forces the post-processors off for its whole high-threat close arm,
	# rather than only at the extremes the way BB does.
	d.force_below = -1.0
	d.force_above = 0.5
	d.cover_abandon_threat = 0.85
	# The idle and dark arms returned before the post-processors ran.
	d.post_process_idle_arms = false
	return d


static func for_destroyer() -> BotDoctrine:
	var d := BotDoctrine.new()
	# Spot first, Hunt only if it declines. The idle arm is reached when the
	# team has never seen anything at all, which for a destroyer is not an
	# absence of work - it is the description of its job. Hunting picks a
	# position off the friendly line and drives to it; spotting goes and finds
	# out where the enemy actually is, which is the thing nobody else can do.
	d.idle_chain = [&"Spot", &"Hunt"]
	# No dark arm: a DD with nothing spotted is still doing its job (making
	# vision for the team), so it goes straight to the engaged ladder.
	d.dark_chain = []
	d.close_arm_range_gated = false
	d.close_arm_uses_cover = false
	d.close_arm_reverse_align = false
	d.push_threat = 0.5
	# A destroyer that is shooting rather than launching is already committed,
	# so it fights near the edge of its guns instead of holding a standoff.
	d.gun_engage_ratio = 0.85
	d.use_broadside = true
	d.broadside_exclude = [&"Retreat", &"Spot"]
	d.spread_exclude = [&"FindCover", &"Push", &"Kite", &"Retreat"]
	d.spread_overrides = {
		&"Spot": {"spread_distance": 5000.0, "spread_multiplier": 1.0},
	}
	# The DD never marks an intent forced, so nothing is ever skipped for it.
	d.force_below = -1.0
	d.force_above = INF
	d.universal_sail_forward_fallback = true
	d.post_process_idle_arms = true
	return d
