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
				if ship.global_position.distance_to(last_pos) > 1_000.0 \
						and _all_enemies_safe(ship):
					phase = Phase.PROBING

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

	## Returns true only while in the SHOOTING phase.
	func can_fire() -> bool:
		return phase == Phase.SHOOTING

	## Check whether the bloom has decayed back to (or below) the base concealment radius.
	func _is_bloom_decayed(ship: Ship) -> bool:
		var concealment_params: ConcealmentParams = ship.concealment.params.p() as ConcealmentParams
		return ship.concealment.bloom_radius <= concealment_params.radius

	## Returns true when every visible enemy is "safe" for probing.
	## An enemy is safe if:
	##   1) Terrain blocks line-of-sight (shell arc cannot clear terrain), OR
	##   2) The enemy is outside the ship's base concealment radius.
	## If there are no visible enemies, returns true.
	func _all_enemies_safe(ship: Ship) -> bool:
		var server_node: GameServer = ship.get_node_or_null("/root/Server")
		if server_node == null:
			return false

		var visible_enemies = server_node.get_valid_targets(ship.team.team_id)
		if visible_enemies.is_empty():
			return true

		var concealment_params: ConcealmentParams = ship.concealment.params.p() as ConcealmentParams
		var concealment_radius: float = concealment_params.radius
		var check_pos: Vector3 = ship.global_position
		var has_nav: bool = NavigationMapManager.is_map_ready()

		for enemy in visible_enemies:
			# # Check if terrain blocks line-of-sight using the navigation map raycast.
			# if has_nav and NavigationMapManager.is_los_blocked(check_pos, enemy.global_position):
			# 	# Island blocks LoS — enemy cannot see us, safe.
			# 	continue
			var map = NavigationMapManager.get_map()
			var result = map.raycast(Vector2(check_pos.x, check_pos.z), Vector2(enemy.global_position.x, enemy.global_position.z), -50)
			var clear = not result["hit"]
			if !clear:
				continue


			# Enemy has line of sight — only safe if outside concealment radius.
			var dist: float = check_pos.distance_to(enemy.global_position)
			if dist > concealment_radius:
				continue

			# Enemy has LoS AND is within concealment radius — not safe.
			return false

		return true
