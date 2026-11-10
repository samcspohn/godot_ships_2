class_name BotTiming
extends RefCounted

static var on: bool = false
static var _samples: Dictionary = {}
static var _frame: int = -1
static var _frame_us: int = 0
static var _frame_max_bot: int = 0

static func add(key: StringName, t0: int) -> void:
	if not on:
		return
	(_samples.get_or_add(key, []) as Array).append(Time.get_ticks_usec() - t0)

## The slowest calls with what they did, per key.
static var _worst: Dictionary = {}
const WORST_KEEP := 25

static func worst(key: StringName, us: int, info: Dictionary) -> void:
	if not on:
		return
	var a: Array = _worst.get_or_add(key, [])
	if a.size() >= WORST_KEEP and us <= int(a[-1][0]):
		return
	a.append([us, info])
	a.sort_custom(func(x, y): return x[0] > y[0])
	if a.size() > WORST_KEEP:
		a.resize(WORST_KEEP)

static func add_us(key: StringName, us: int) -> void:
	if on:
		(_samples.get_or_add(key, []) as Array).append(us)

## One bot's whole physics tick; also summed per physics frame across bots.
static func bot_frame(t0: int) -> void:
	if not on:
		return
	var us := Time.get_ticks_usec() - t0
	var f := Engine.get_physics_frames()
	if f != _frame:
		if _frame >= 0:
			_push(&"frame_bots", _frame_us)
			_push(&"frame_worst_bot", _frame_max_bot)
		_frame = f
		_frame_us = 0
		_frame_max_bot = 0
	_frame_us += us
	_frame_max_bot = maxi(_frame_max_bot, us)
	_push(&"bot_frame", us)

static func _push(key: StringName, us: int) -> void:
	(_samples.get_or_add(key, []) as Array).append(us)

## Per key in µs: n, mean, p50, p99, p999, max, total_s.
static func summary() -> Dictionary:
	var out := {}
	for k in _samples:
		var a: Array = (_samples[k] as Array).duplicate()
		a.sort()
		var n := a.size()
		var tot := 0
		for x in a:
			tot += x
		out[String(k)] = {"n": n, "mean": float(tot) / n, "p50": a[n / 2], "p99": a[mini(int(n * 0.99), n - 1)],
			"p999": a[mini(int(n * 0.999), n - 1)], "max": a[n - 1], "total_s": tot / 1e6}
	return out

static func print_worst() -> void:
	for k in _worst:
		for e in _worst[k]:
			print("[BotWorst] %s %d %s" % [k, e[0], JSON.stringify(e[1])])

static func print_table() -> void:
	print_worst()
	var d: PackedInt64Array = StanceSim.dodge_prof()
	if d.size() >= 7 and d[0] > 0:
		print("[DodgeProf] searches %d total %.1f ms/search land_shells %.1f%% hull %.1f%% steps/search %d shell checks/search %d hits tested/search %d" % [
			d[0], d[1] / 1e6 / d[0], 100.0 * d[2] / d[1], 100.0 * d[3] / d[1], d[4] / d[0], d[5] / d[0], d[6] / d[0]])
	var s := summary()
	var keys := s.keys()
	keys.sort_custom(func(x, y): return s[x].total_s > s[y].total_s)
	print("[BotTiming] %-18s %8s %8s %8s %8s %8s %8s %8s" % ["key", "n", "mean", "p50", "p99", "p999", "max", "tot_s"])
	for k in keys:
		var r: Dictionary = s[k]
		print("[BotTiming] %-18s %8d %8.0f %8d %8d %8d %8d %8.2f" % [k, r.n, r.mean, r.p50, r.p99, r.p999, r.max, r.total_s])
