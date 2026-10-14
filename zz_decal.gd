extends SceneTree

func _initialize() -> void:
	create_timer(100.0).timeout.connect(func(): print("DC watchdog"); quit(1))
	var scene: Node = load("res://src/port/main_menu/main_menu_3d.tscn").instantiate()
	root.add_child(scene)
	_run.call_deferred(scene)

func _run(scene: Node) -> void:
	for i in 60: await process_frame
	var wm = root.get_node("/root/WaveManager")
	wm.set_process(false)
	var ship := Node3D.new(); scene.add_child(ship)
	ship.global_position = Vector3(3000, 0, 3000)
	var hm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(36, 20, 250); hm.mesh = bm; ship.add_child(hm)
	ship.look_at(ship.global_position + Vector3(0, 0, -1), Vector3.UP)
	wm.register_ship(ship, 112.0, 18.0, 9.0)
	var cam := Camera3D.new(); cam.far = 60000.0; cam.fov = 40.0; scene.add_child(cam)
	var ocean = scene.find_child("Ocean", true, false)
	ocean.camera = cam
	cam.make_current()
	var dt := 1.0 / 60.0
	for f in 600:
		ship.global_position += Vector3(0, 0, -28.0 * dt)
		if f % 30 == 0:
			wm.add_shell_splash(Vector3(2850, 0, 2700), 12.0)
		if f % 180 == 0 or f == 520:
			wm.add_muzzle_blast(ship.global_position + Vector3(25, 0, 0), 12.0)
		wm._process(dt)
		cam.global_position = ship.global_position + Vector3(260, 160, 60)
		cam.look_at(ship.global_position + Vector3(-40, 0, 140), Vector3.UP)
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/oceancalc/dec.png")
	cam.global_position = ship.global_position + Vector3(-60, 700, 160)
	cam.look_at(ship.global_position + Vector3(-60, 0, 150), Vector3.UP)
	for i in 3:
		wm._process(dt)
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/oceancalc/dec_top.png")
	print("DC done")
	quit()
