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

## Threat at which an open-water gun boat breaks off its push and kites, paired
## with push_threat above, which is where it turns back in. The gap between the
## two is the hysteresis that makes the pair an oscillation rather than a
## chatter: one threshold would leave the boat alternating destinations every
## tick while threat sat on it. See DDBehavior._open_water_kiting().
var kite_threat: float = 0.6

## Minimum distance to the nearest non-DD threat before cover is preferred to
## kiting at high threat.
var cover_min_threat_dist: float = 10000.0

## Threat above which a cruiser stops accepting cover that is off the
## engagement path and kites instead.
var cover_abandon_threat: float = 0.85

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

## Threat at which a push holds the FULL engagement range, and the fraction of
## it a push at zero threat closes to.
##
## The engagement range is a ceiling, not a station. A push that always stopped
## on it fought every engagement at the same distance whether it was winning or
## losing, and the only thing that ever moved the ship back out was the ladder
## above swapping the skill for a kite - one step, at one threshold. Scaling the
## standoff with threat instead makes the range itself the negotiation: with
## nothing shooting, the bot keeps coming; as closing raises the threat it is
## closing into, the standoff opens back out and the approach stalls of its own
## accord. The ship settles where threat sits at push_equalize_threat, and the
## push/kite pair swings around that point rather than around a fixed circle.
##
## Set to the threat where this bot stops pushing at all, so the standoff has
## reached the full engagement range exactly as the ladder takes the push away.
## 0 disables the scaling and the push stops on the flat engagement range.
var push_equalize_threat: float = 0.5

## Floor on the above, as a fraction of the engagement range, so an unopposed
## push closes hard without driving onto the enemy's hull.
var push_equalize_floor: float = 0.5

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
	# The close arm pushes below push_threat and kites above it, so that is where
	# the standoff has to have finished opening back out.
	d.push_equalize_threat = d.push_threat
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
	d.push_equalize_threat = d.push_threat
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
	# No range negotiation for a torpedo boat: its engagement range is the
	# closest standoff that keeps it dark (DDBehavior.engagement_range), and
	# water given up for a quiet approach is not water low threat should be
	# spending. Inside it the boat is seen, which is the one thing the whole
	# approach was buying.
	d.push_equalize_threat = 0.0
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
	d.trades_on_concealment = true
	d.stealth_threat = 0.5
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
	d.close_arm_uses_cover = true
	# The engaged arm swings between push and kite on these two (see
	# DDBehavior._open_water_kiting). push_threat comes from for_destroyer() and
	# is the turn-back-in edge; this is the break-off edge.
	d.kite_threat = 0.6
	# The push leg gets the range back gradually rather than all at once: this
	# boat's push and kite are the two halves of one swing, so the standoff it
	# is pushing to should be full only where the next kite leg breaks off.
	d.push_equalize_threat = d.kite_threat
	return d
