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

## Whether contacts being lit but unshootable — all of them out of range or
## behind terrain — sends this bot straight to Chase, ahead of the arms that
## decide on threat.  On for the gun line, whose whole job is measured in time
## spent with the batteries on something.  Off for the destroyer, whose engaged
## arm already ladders Spot before Chase on purpose: a boat that runs down every
## last-known position at flank speed arrives lit, alone, and dead.
var chase_when_unshootable: bool = true

## Whether the close-quarters arm is gated on nearest_threat_dist < ra_threshold
## (BB/CA) or fires on detection alone (DD).
var close_arm_range_gated: bool = true

## Whether a low threat score short-circuits the ladder before the distance
## check. CA decides on odds first: a cruiser that likes its chances pushes
## whether or not the enemy is close aboard. BB and DD check distance first.
var low_threat_arm_first: bool = false

## Whether a ladder that produced nothing falls back to sailing forward. With
## this off a behaviour may return null, which the controller reads as "hold the
## previous destination".
var universal_sail_forward_fallback: bool = false

## Extra HPA step cost per unit of detection exposure while routing under
## wants_stealth. Finite: detection is priced, not walled, and the router
## crosses it when the detour would cost more. 0 or INF restores the wall.
var detection_cost_gain: float = 4.0

## Extra HPA step cost per enemy able to land shells on the node, for any
## hull not routing under wants_stealth. 0 = off.
var fire_cost_gain: float = 0.25

## Whether the idle and dark arms get the evade/spread post-processors. CA
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

## Above this threat the engaged arm stops engaging and disengages.
var engage_max_threat: float = 0.75

## Below this threat the bot reads the fight as its own: a hidden station may
## open fire (BotBehavior._hold_fire_hidden).
var duel_threat: float = 0.5
## A held Cover station outranks every arm until threat drops below this.
var cover_release_threat: float = 0.4

## Threat at which an open-water gun boat breaks off its push and kites, paired
## with push_threat above, which is where it turns back in. The gap between the
## two is the hysteresis that makes the pair an oscillation rather than a
## chatter: one threshold would leave the boat alternating destinations every
## tick while threat sat on it. See DDBehavior._open_water_kiting().
var kite_threat: float = 0.6

## Whether this bot's escape route is concealment rather than manoeuvre. Set for
## a hull that can actually go dark and gain something by it: it stops shooting
## under pressure, routes around enemy detection zones, and holds fire whenever
## letting bloom decay would drop it. A gun-armed hull that cannot break contact
## by any of that only loses its own damage output by trying.
var trades_on_concealment: bool = false

## Threat above which a bot that trades on concealment stops shooting and starts
## hiding. Read only when trades_on_concealment is set.
var stealth_threat: float = 0.5

# ---------------------------------------------------------------------------
# Engagement range — how close this bot wants to fight, read off its build
# ---------------------------------------------------------------------------

## Main-battery range fractions the engagement range passes through: at
## threat 1, and at threat 0.5. In between and below it follows
## far * threat^p (p fitted through the two), so an unopposed bot closes to
## point blank and opens out as the fight turns against it.
var engage_far_ratio: float = 0.99
var engage_mid_ratio: float = 0.65

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

## Evasion post-process, off in the reload gap (stance's to use) unless threat is past this.
var evade_override_threat: float = 0.75
var evade_exclude: Array[StringName] = [&"SailForward"]
var evade_params: Dictionary = {}

var spread_exclude: Array[StringName] = [&"Engage", &"Disengage", &"Hold"]
var spread_distance: float = 1000.0
var spread_multiplier: float = 1.0

## Skills that get their own spread tuning instead of the defaults above.
var spread_overrides: Dictionary = {}

# ---------------------------------------------------------------------------
# THE TABLE
# ---------------------------------------------------------------------------

static func for_battleship() -> BotDoctrine:
	var d := BotDoctrine.new()
	d.dark_chain = [&"Chase"]
	d.dark_takes_cover = true
	d.push_threat = 0.5
	d.force_below = 0.25
	d.force_above = 0.75
	# A battleship stations on what it can shoot and how many can shoot back;
	# being seen costs it nothing it was not already paying.
	# The close arm pushes below push_threat and kites above it, so that is where
	# the standoff has to have finished opening back out.
	d.ra_bb_shooter_hurt = 13000.0
	d.spread_exclude = [&"Engage", &"Disengage", &"Camp", &"Hold"]
	# A battleship's evasion IS its angling, so it is never worth suppressing:
	# the presentation weave costs it nothing it was going to use anyway.
	d.evade_override_threat = 0.6
	d.post_process_idle_arms = true
	return d

static func for_cruiser() -> BotDoctrine:
	var d := BotDoctrine.new()
	d.dark_chain = [&"Chase", &"Hunt", &"SailForward"]
	d.dark_takes_cover = true
	d.push_threat = 0.5
	d.ra_bb_shooter_hurt = 11000.0
	d.spread_exclude = [&"Engage", &"Disengage", &"Hold"]
	d.low_threat_arm_first = true
	# CA forces the post-processors off for its whole high-threat close arm,
	# rather than only at the extremes the way BB does.
	d.force_below = -1.0
	d.force_above = 0.5
	# The idle and dark arms returned before the post-processors ran.
	d.post_process_idle_arms = false
	# A cruiser's position is covered or it is not held: nobody can shoot it,
	# or nobody can see it. The 1.0 cap on top keeps a battleship out of even
	# the unseen case until the 1-v-x rule reads threat and hull points.
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
	d.push_threat = 0.5
	d.spread_exclude = [&"Engage", &"Disengage", &"Retreat", &"Hold"]
	# The DD never marks an intent forced, so nothing is ever skipped for it.
	d.force_below = -1.0
	d.force_above = INF
	d.universal_sail_forward_fallback = true
	d.post_process_idle_arms = true
	# Spot first — see _select_engaged_skill(), which reaches Chase anyway once
	# there is no station worth holding.
	d.chase_when_unshootable = false
	d.trades_on_concealment = true
	d.stealth_threat = 0.5
	# A torpedo boat pushes to its launch band in the dark.
	return d

## The open-water gunboat destroyer, for a hull with no undetected launch band -
## tubes that do not reach meaningfully past its own detection radius, or no
## tubes at all. See DDBehavior._is_gunboat(), which measures the band rather
## than naming the hull.
##
## Such a boat cannot fight the way for_destroyer() assumes. Going dark buys it
## nothing it can shoot from, so it does the opposite: it fights in the open at
## the edge of its own guns, keeps firing, and survives on helm rather than on
## concealment. Everything below is that one decision.
static func for_gunboat_destroyer() -> BotDoctrine:
	var d := for_destroyer()
	# The whole reversal, in one flag: no hiding, no held fire, no routing
	# around detection zones. stealth_threat is left where for_destroyer() put
	# it and simply stops being read.
	d.trades_on_concealment = false
	# Being seen is this boat's normal condition rather than the emergency it is
	# for a torpedo boat, so distance decides the close arm again - the same way
	# it does for every other gun-armed hull. Fighting out near maximum gun
	# range, the close arm should be reached only when something has genuinely
	# closed.
	d.close_arm_range_gated = true
	# Threat opens the gunboat band instead; cover only hides it from its targets.
	# The engaged arm swings between push and kite on these two (see
	# DDBehavior._open_water_kiting). push_threat comes from for_destroyer() and
	# is the turn-back-in edge; this is the break-off edge.
	d.kite_threat = 0.6
	# The gunboat fights lit; it still takes no more than a 1v1 on a station.
	return d
