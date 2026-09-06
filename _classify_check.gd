extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var behav = load("res://src/ship/bot_behavior/dd_behav.gd").new()
	for path in ["res://assets/Ships/Shimakaze/Shimakaze.tscn",
				 "res://assets/Ships/SP1/SP1.tscn"]:
		var ship = load(path).instantiate()
		root.add_child(ship)
		await process_frame
		var torp := -1.0
		if ship.torpedo_controller != null:
			torp = ship.torpedo_controller.get_params()._range
		var conceal: float = (ship.concealment.params.p() as ConcealmentParams).radius
		var guns: float = ship.artillery_controller.get_params()._range
		var band: float = torp * 0.8 - conceal * 1.15
		print("%-12s guns=%6.0f torps=%6.0f conceal=%6.0f | band=%7.0f m  ratio=%.2f  -> %s"
			% [ship.name, guns, torp, conceal, band,
			   (torp * 0.8) / (conceal * 1.15),
			   "GUNBOAT" if behav._is_gunboat(ship) else "torpedo boat"])
		ship.queue_free()
		await process_frame
	quit()
