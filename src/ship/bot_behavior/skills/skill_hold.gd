class_name SkillHold
extends BotSkill

## Stopping somewhere worth being: one posture, the mode says what makes a
## position good. SPOT sees targets a friend can shoot from outside detection;
## FIGHT is the firing station on the engagement band (gunboats ask it for a
## radius to ride and a target in sight); COVER hides behind an island. Params: hold
## (the Mode), then the mode's own (SkillSpot, SkillFight, SkillCover).

enum Mode { SPOT, FIGHT, COVER }

var mode: int = Mode.FIGHT
var spot := SkillSpot.new()
var fight := SkillFight.new()
var cover := SkillCover.new()

func reset() -> void:
	spot.reset()
	fight.reset()
	cover.reset()

func current() -> SkillPosition:
	return [spot, fight, cover][mode]

func debug_text() -> String:
	return current().debug_text()

func execute(ctx: SkillContext, params: Dictionary) -> NavIntent:
	var m: int = params.get("hold", Mode.FIGHT)
	if m != mode:
		current().reset()
		mode = m
	return current().execute(ctx, params)
