class_name TacticalState
extends RefCounted

enum State {
	HUNTING,
	SNEAKING,
	ENGAGED,
	DISENGAGING,
}


class BloomProbe:
	enum Phase {
		SHOOTING,
		PROBING,
	}

	var phase: Phase = Phase.SHOOTING
	var _probe_timer: float = 0.0
	var probe_timeout: float = 4.0
	var last_pos: Vector3 = Vector3.ZERO

	## One-tick signals — true for exactly one frame when triggered.
	var went_dark: bool = false
	var probe_failed: bool = false

	## Reset everything for a new disengagement sequence.
	func enter() -> void:
		phase = Phase.SHOOTING
		_probe_timer = 0.0
		probe_timeout = 4.0
		went_dark = false
		probe_failed = false

	## Call once per physics tick.
	func update(ship: Ship, delta: float) -> void:
		# Reset one-tick signals each frame.
		went_dark = false
		probe_failed = false

		# If the ship is no longer visible to the enemy we went dark.
		if not ship.visible_to_enemy:
			went_dark = true
			return

		match phase:
			Phase.SHOOTING:
				if ship.global_position.distance_to(last_pos) > 1_000.0:
					phase = Phase.PROBING
					# _probe_timer = 0.0
					# last_pos = ship.global_position
				# _probe_timer += delta

				# if _is_bloom_decayed(ship):
				# 	phase = Phase.PROBING
				# 	_probe_timer = 0.0

			Phase.PROBING:
				if _is_bloom_decayed(ship) and ship.visible_to_enemy:
					(func():
						if ship.visible_to_enemy:
							last_pos = ship.global_position
							phase = Phase.SHOOTING
							probe_failed = true
						else:
							went_dark = true
					).call_deferred()
					# _probe_timer = 0.0
				# else:
				# 	went_dark = true
					# return
				# _probe_timer += delta
				# if not ship.visible_to_enemy:
				# 	went_dark = true
				# elif _probe_timer >= probe_timeout:
				# 	probe_failed = true
				# 	phase = Phase.SHOOTING

	## Returns true only while in the SHOOTING phase.
	func can_fire() -> bool:
		return phase == Phase.SHOOTING

	## Check whether the bloom has decayed back to (or below) the base concealment radius.
	func _is_bloom_decayed(ship: Ship) -> bool:
		var concealment_params: ConcealmentParams = ship.concealment.params.p() as ConcealmentParams
		return ship.concealment.bloom_radius <= concealment_params.radius
