extends Node

## Correctness + cost check for the Moddable mod-layer system.
##   godot --headless --path . res://test/test_moddable.tscn
##
## Runs as a scene rather than a `--script` SceneTree: Ship.gd reaches the
## autoloads, which are not up yet when a --script tree is compiled.

var _failures: int = 0

func _check(label: String, ok: bool) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1

func _approx(a: float, b: float) -> bool:
	return abs(a - b) < 0.0001


func _ready() -> void:
	# Hold the tree: an autoload may swap the main scene out from under us,
	# which detaches this node and makes get_tree() null.
	var tree := get_tree()
	await tree.process_frame
	_test_layering()
	_test_template_untouched()
	_test_reference_stability()
	_test_clean_layer_skip()
	_bench()
	print("\n%d failure(s)" % _failures)
	tree.quit(1 if _failures > 0 else 0)


func _test_layering() -> void:
	print("\n[layering] static and dynamic mods stack without compounding")
	var ship := Ship.new()
	var tmpl: GunParams = load("res://src/artillary/Guns/BB_gun1.tres")
	var params: GunParams = tmpl.instantiate(ship) as GunParams
	var base_reload := tmpl.reload_time

	ship.add_static_mod(func(_s: Ship) -> void:
		(params.static_mod as GunParams).reload_time *= 0.9)
	ship.add_dynamic_mod(func(_s: Ship) -> void:
		(params.p() as GunParams).reload_time *= 0.5)

	ship._update_static_mods()
	_check("static layer = base * 0.9", _approx(params.static_mod.reload_time, base_reload * 0.9))
	_check("dynamic layer = base * 0.9 * 0.5", _approx(params.p().reload_time, base_reload * 0.45))

	# Re-running must be idempotent — this is what the reset layers exist for.
	for i in 5:
		ship._update_static_mods()
	_check("static rebuild x5 does not compound", _approx(params.p().reload_time, base_reload * 0.45))
	for i in 5:
		ship._update_dynamic_mods()
	_check("dynamic rebuild x5 does not compound", _approx(params.p().reload_time, base_reload * 0.45))

	ship.free()


func _test_template_untouched() -> void:
	print("\n[template] mods never write through to the shared .tres")
	var ship := Ship.new()
	var tmpl: GunParams = load("res://src/artillary/Guns/BB_gun1.tres")
	var tmpl_reload := tmpl.reload_time
	var tmpl_damage: float = tmpl.shell1.damage
	var params: GunParams = tmpl.instantiate(ship) as GunParams

	ship.add_dynamic_mod(func(_s: Ship) -> void:
		var p := params.p() as GunParams
		p.reload_time *= 0.5
		p.shell1.damage *= 2.0)
	ship._update_static_mods()

	_check("template reload_time unchanged", _approx(tmpl.reload_time, tmpl_reload))
	_check("template shell1.damage unchanged", _approx(tmpl.shell1.damage, tmpl_damage))
	_check("layer owns its own shell1", not is_same(params.p().shell1, tmpl.shell1))
	_check("modded shell damage applied", _approx(params.p().shell1.damage, tmpl_damage * 2.0))

	ship._update_static_mods()
	_check("shell damage does not compound", _approx(params.p().shell1.damage, tmpl_damage * 2.0))
	ship.free()


func _test_reference_stability() -> void:
	print("\n[refs] sub-resource identity survives a rebuild")
	var ship := Ship.new()
	var tmpl: GunParams = load("res://src/artillary/Guns/BB_gun1.tres")
	var params: GunParams = tmpl.instantiate(ship) as GunParams
	ship.add_dynamic_mod(func(_s: Ship) -> void:
		(params.p() as GunParams).reload_time *= 0.9)
	ship._update_static_mods()

	var shell_ref: ShellParams = params.p().shell1
	var curve_ref: Curve = params.p().dispersion_
	ship._update_static_mods()
	_check("shell1 is the same object after rebuild", is_same(shell_ref, params.p().shell1))
	_check("shared Curve stays shared with template", is_same(curve_ref, tmpl.dispersion_))
	ship.free()


func _test_clean_layer_skip() -> void:
	print("\n[clean] a ship with no mods does no reset work")
	var ship := Ship.new()
	var tmpl: GunParams = load("res://src/artillary/Guns/BB_gun1.tres")
	var params: GunParams = tmpl.instantiate(ship) as GunParams
	# Counter lives in an Array: GDScript lambdas capture locals by value.
	var resets: Array[int] = [0]
	ship.reset_mods.connect(func() -> void: resets[0] += 1)
	ship.reset_dynamic_mods.connect(func() -> void: resets[0] += 1)

	for i in 10:
		ship._update_static_mods()
	_check("no reset signals emitted while mod lists are empty (got %d)" % resets[0], resets[0] == 0)
	_check("values still correct", _approx(params.p().reload_time, tmpl.reload_time))
	ship.free()


func _mk(m: Moddable, ship: Ship) -> Moddable:
	return m.instantiate(ship)


func _bench() -> void:
	print("\n[cost] full rebuild for a battleship-sized Moddable set")
	var ship := Ship.new()
	var gun = load("res://src/artillary/Guns/BB_gun1.tres")
	var sec = load("res://src/artillary/Guns/sec_gun1.tres")
	var mods: Array[Moddable] = [_mk(gun, ship)]
	for i in 3: mods.append(_mk(sec, ship))
	mods.append(_mk(MovementParams.new(), ship))
	mods.append(_mk(HPParams.new(), ship))
	mods.append(_mk(ConcealmentParams.new(), ship))
	for i in 5: mods.append(_mk(HpPartMod.new(), ship))
	for i in 4: mods.append(_mk(TargetMod.new(), ship))
	for i in 2: mods.append(_mk(DOTParams.new(), ship))
	for i in 2: mods.append(_mk(ResistanceParams.new(), ship))
	mods.append(_mk(AAAParams.new(), ship))
	for i in 3: mods.append(_mk(ConsumableItem.new(), ship))
	# one no-op mod on each layer so the dirty guards stay armed
	ship.add_static_mod(func(_s: Ship) -> void: pass)
	ship.add_dynamic_mod(func(_s: Ship) -> void: pass)

	var N := 2000
	var t := Time.get_ticks_usec()
	for i in N:
		ship._update_static_mods()
	var static_us := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for i in N:
		ship._update_dynamic_mods()
	var dyn_us := float(Time.get_ticks_usec() - t) / N
	print("  %d Moddables/ship" % mods.size())
	print("  static rebuild : %6.1f us/ship  (%.2f ms if all 24 ships rebuild in one frame)" % [static_us, static_us * 24.0 / 1000.0])
	print("  dynamic rebuild: %6.1f us/ship  (%.2f ms if all 24 ships rebuild in one frame)" % [dyn_us, dyn_us * 24.0 / 1000.0])
	ship.free()
