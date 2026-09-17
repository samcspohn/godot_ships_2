extends Node3D
## Where the bytes go in the baked gunnery db.
## `godot --headless --path . res://tools/gunnery_stat.tscn --`

const HDR := BotGunnery.BLOB_HDR


func _ready() -> void:
	var idx := GunneryDb.read_index(BotGunnery.SOLVER_VERSION)
	if idx.is_empty() or int(idx.get("version", -1)) != BotGunnery.SOLVER_VERSION:
		print("no gunnery.db at version %d" % BotGunnery.SOLVER_VERSION)
		get_tree().quit(1)
		return
	var hulls: Dictionary = idx["hulls"]
	print("db %s" % idx["_path"])
	var disk := FileAccess.open(idx["_path"], FileAccess.READ).get_length()
	var raw := 0
	var n_buckets := 0
	var n_cells := 0
	var n_prof := 0
	var n_bp := 0
	var n_bp_om := 0
	var max_np := 0
	var max_ny := 0
	var keys := hulls.keys()
	keys.sort()
	for key in keys:
		var e: Dictionary = hulls[key]
		var t = GunneryDb.read_hull(key, idx)
		raw += int(e["rsize"])
		var buckets: Dictionary = t["buckets"]
		n_buckets += buckets.size()
		for bid in buckets:
			var b: PackedByteArray = buckets[bid]
			var np: int = b.decode_u16(2)
			var ncell: int = b.decode_u8(0) * b.decode_u8(1)
			var a0: int = BotGunnery.bucket_prof_off(b)
			n_cells += ncell
			n_prof += np
			max_np = maxi(max_np, np)
			max_ny = maxi(max_ny, b.decode_u8(1))
			for i in np:
				n_bp += b.decode_u8(a0 + 3 * np + i)
				n_bp_om += b.decode_u8(a0 + 4 * np + i)
		print("  %-40s %7d -> %7d" % [key.get_file(), int(e["rsize"]), int(e["csize"])])
	print("\n%d hulls  %d buckets  %d cells  %d profiles  %d bp  %d bp_om   max profiles/bucket %d  max ny %d"
		% [hulls.size(), n_buckets, n_cells, n_prof, n_bp, n_bp_om, max_np, max_ny])
	print("raw %d  disk %d  ratio %.2f  per hull %d" % [raw, disk, float(raw) / disk,
		disk / maxi(hulls.size(), 1)])
	var payload := HDR * n_buckets + n_cells + 5 * n_prof + 3 * (n_bp + n_bp_om)
	print("blob payload %d of %d raw (%.1f%%): header %d  cells %d  profiles %d  bp %d"
		% [payload, raw, 100.0 * payload / raw, HDR * n_buckets, n_cells, 5 * n_prof,
		3 * (n_bp + n_bp_om)])
	_sequences(idx)
	get_tree().quit()


## Could a fixed slot per result replace the breakpoint list? Only if every
## profile's results appear at most once each and in one canonical order.
const CANON := {4: 0, 2: 1, 1: 2, 0: 3, 3: 4, 5: 5, 6: 6}  # shatter ric partial pen open cit citopen
func _sequences(idx: Dictionary) -> void:
	var lists := 0
	var len_hist := {}
	var repeat := 0
	var non_mono := 0
	var sec_change := 0
	var codes_seen := {}
	for key in idx["hulls"]:
		var t = GunneryDb.read_hull(key, idx)
		for bid in t["buckets"]:
			var b: PackedByteArray = t["buckets"][bid]
			var np: int = b.decode_u16(2)
			var a: int = BotGunnery.bucket_prof_off(b)
			var off := a + 5 * np
			for which in 2:
				var cnt_o := a + (3 + which) * np
				for i in np:
					var n: int = b.decode_u8(cnt_o + i)
					if n == 0:
						continue
					lists += 1
					len_hist[n] = int(len_hist.get(n, 0)) + 1
					var seen := {}
					var last_rank := -1
					var last_sec := -1
					var rep := false
					var mono := true
					var secs := false
					for k in n:
						var c: int = b.decode_u8(off + 3 * k + 2)
						var r: int = c & 0x0F
						var sec: int = (c & 0xE0) >> 5
						codes_seen[r] = int(codes_seen.get(r, 0)) + 1
						if seen.has(r):
							rep = true
						seen[r] = true
						var rank: int = CANON.get(r, 99)
						if rank < last_rank:
							mono = false
						last_rank = rank
						if last_sec >= 0 and sec != last_sec:
							secs = true
						last_sec = sec
					off += 3 * n
					if rep: repeat += 1
					if not mono: non_mono += 1
					if secs: sec_change += 1
	print("\nbreakpoint lists %d (base + om)" % lists)
	var lr := []
	for k in len_hist: lr.append([k, len_hist[k]])
	lr.sort()
	var acc := ""
	for r in lr:
		if r[0] <= 8: acc += "  %d:%.1f%%" % [r[0], 100.0 * r[1] / lists]
	print("  length histogram:" + acc)
	print("  same result twice in one list:  %d  (%.1f%%)" % [repeat, 100.0 * repeat / lists])
	print("  out of canonical order:         %d  (%.1f%%)" % [non_mono, 100.0 * non_mono / lists])
	print("  section changes along the list: %d  (%.1f%%)" % [sec_change, 100.0 * sec_change / lists])
	var cs := ""
	for r in [4, 2, 1, 0, 3, 5, 6, 7, 8]:
		if codes_seen.has(r): cs += "  %d:%d" % [r, codes_seen[r]]
	print("  result codes in lists:" + cs)
