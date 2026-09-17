class_name GunneryDb
extends RefCounted
## One container for every hull's baked gunnery table.
##
## Blobs are compressed individually rather than the file as a whole, so a hull
## can be seeked to and decompressed on its own; `FileAccess.open_compressed`
## would force the whole 12-hull payload through on first use.
##
## `u32 index_len | index_len bytes var_to_bytes(index) | blob*`
## index = {"version": int, "hulls": {scene_path: {"md5", "off", "csize", "rsize"}}}

## A downloaded db wins over the one in the tree, so a client can be updated
## without a rebuild - but only if it is the version the solver wants. A stale
## user copy must not shadow a fresh shipped one. `make bake` writes SHIPPED;
## only a fetch writes PATH.
const PATH: String = "user://gunnery.db"
const SHIPPED: String = "res://assets/gunnery.db"
const MAGIC: int = 0x594E5547  # "GUNY"


static func _read_head(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 12 or f.get_32() != MAGIC:
		return {}
	var n := f.get_32()
	if n == 0 or n > f.get_length():
		return {}
	var d = bytes_to_var(f.get_buffer(n))
	if not (d is Dictionary):
		return {}
	d["_path"] = path
	return d


## {"version", "hulls", "_path"} of the first db whose version is `want`
## (user copy first), else whichever was found so the caller can say which
## version it was. Cheap: reads only the heads.
static func read_index(want: int = -1) -> Dictionary:
	var found := {}
	for p in [PATH, SHIPPED]:
		var d := _read_head(p)
		if d.is_empty():
			continue
		if want < 0 or int(d.get("version", -1)) == want:
			return d
		if found.is_empty():
			found = d
	return found


## The table for one hull, or null, from the db `index` was read from.
static func read_hull(key: String, index: Dictionary) -> Variant:
	var p: String = String(index.get("_path", SHIPPED))
	var idx := index
	var hulls = idx.get("hulls")
	if not (hulls is Dictionary) or not hulls.has(key):
		return null
	var e: Dictionary = hulls[key]
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	f.seek(int(e["off"]))
	var raw := f.get_buffer(int(e["csize"]))
	if raw.size() != int(e["csize"]):
		return null
	var plain := raw.decompress(int(e["rsize"]), FileAccess.COMPRESSION_ZSTD)
	return bytes_to_var(plain)


## Compress one hull's table into an entry for `write_blobs`.
static func pack(table: Dictionary) -> Dictionary:
	var plain := var_to_bytes(table)
	return {"md5": String(table.get("glb_md5", "")), "rsize": plain.size(),
		"data": plain.compress(FileAccess.COMPRESSION_ZSTD)}


static func write(tables: Dictionary, version: int, path: String = SHIPPED) -> bool:
	var entries := {}
	for key in tables:
		entries[key] = pack(tables[key])
	return write_blobs(entries, version, path)


## Rewrite `path` from already-compressed entries (see `pack`). Whole-file: the
## index sits at the head, so any size change shifts every blob after it. That
## is a streaming copy, not a recompress, so it stays cheap as hulls are added.
static func write_blobs(entries: Dictionary, version: int, path: String = SHIPPED) -> bool:
	var blobs := {}
	var hulls := {}
	var off := 0
	for key in entries:
		var e: Dictionary = entries[key]
		var comp: PackedByteArray = e["data"]
		hulls[key] = {"md5": String(e.get("md5", "")), "off": off,
			"csize": comp.size(), "rsize": int(e["rsize"])}
		blobs[key] = comp
		off += comp.size()
	var index := var_to_bytes({"version": version, "hulls": hulls})
	# Offsets were counted from zero; shift them past the head now that it is sized.
	var head := 8 + index.size()
	for key in hulls:
		hulls[key]["off"] = int(hulls[key]["off"]) + head
	index = var_to_bytes({"version": version, "hulls": hulls})
	if index.size() + 8 != head:
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_32(MAGIC)
	f.store_32(index.size())
	f.store_buffer(index)
	for key in entries:
		f.store_buffer(blobs[key])
	f.close()
	return true
