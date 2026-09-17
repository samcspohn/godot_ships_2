extends Node3D
## Where the bytes go in the baked gunnery db.
## `godot --headless --path . res://tools/gunnery_stat.tscn --`

const HDR := BotGunnery.BLOB_HDR


func _ready() -> void:
	var idx := GunneryDb.read_index()
	if idx.is_empty():
		print("no db at %s" % GunneryDb.read_path())
		get_tree().quit(1)
		return
	var hulls: Dictionary = idx["hulls"]
	var disk := FileAccess.open(GunneryDb.read_path(), FileAccess.READ).get_length()
	var raw := 0
	var n_buckets := 0
	var n_cells := 0
	var n_prof := 0
	var n_bp := 0
	var n_bp_om := 0
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
			n_cells += ncell
			n_prof += np
			for i in np:
				n_bp += b.decode_u8(HDR + ncell + 3 * np + i)
				n_bp_om += b.decode_u8(HDR + ncell + 4 * np + i)
		print("  %-40s %7d -> %7d" % [key.get_file(), int(e["rsize"]), int(e["csize"])])
	print("\n%d hulls  %d buckets  %d cells  %d profiles  %d bp  %d bp_om"
		% [hulls.size(), n_buckets, n_cells, n_prof, n_bp, n_bp_om])
	print("raw %d  disk %d  ratio %.2f  per hull %d" % [raw, disk, float(raw) / disk,
		disk / maxi(hulls.size(), 1)])
	var payload := HDR * n_buckets + n_cells + 5 * n_prof + 3 * (n_bp + n_bp_om)
	print("blob payload %d of %d raw (%.1f%%): header %d  cells %d  profiles %d  bp %d"
		% [payload, raw, 100.0 * payload / raw, HDR * n_buckets, n_cells, 5 * n_prof,
		3 * (n_bp + n_bp_om)])
	get_tree().quit()
