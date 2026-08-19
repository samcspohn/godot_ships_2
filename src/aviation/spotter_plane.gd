extends Aircraft
class_name SpottingAircraft

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

# Spotters have no ordnance - once the squadron reaches the attack point it
# holds station there (see Squadron._fire), so there's nothing to do here
# except stay on the squadron's roster (don't recall).
func fire_ordnance(_direction: Vector2) -> bool:
	return false

# A spotter's payload is the sortie itself: it is spent the moment the squadron
# leaves the deck, so the squadron owes its full rearm on landing even though it
# never dropped anything.
func expends_on_launch() -> bool:
	return true
