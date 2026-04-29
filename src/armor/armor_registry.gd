extends Node

## ArmorRegistry — autoload singleton
## Caches armor data keyed by canonical GLB path so that multiple ships or
## turrets sharing the same GLB file never load or store duplicate data.
##
## Usage:
##   var data: Dictionary = ArmorRegistry.get_or_load("res://ships/yamato.glb")
##   # data is the shared { "node_path": [armor_values…] } dictionary.
##   # Subsequent calls with the same path return the same Dictionary object
##   # (reference equality) at zero cost.

# _cache: { canonical_glb_path: String -> armor_data: Dictionary }
var _cache: Dictionary = {}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Return the armor-data dictionary for *glb_path*, loading it from the GLB
## the first time it is requested.  Returns an empty Dictionary on failure.
func get_or_load(glb_path: String) -> Dictionary:
	if _cache.has(glb_path):
		return _cache[glb_path]

	print("ArmorRegistry: extracting armor from '", glb_path, "' ...")
	var extractor := EnhancedArmorExtractorV2.new()
	var data: Dictionary = extractor.extract_armor_with_node_mapping(glb_path)

	if data.is_empty():
		print("ArmorRegistry: ⚠️  no armor data found in '", glb_path, "'")
		# Cache the empty result so we don't retry on every load.
		_cache[glb_path] = {}
		return {}

	var total_faces: int = 0
	for v in data.values():
		total_faces += (v as Array).size()

	print("ArmorRegistry: ✅ cached armor for '", glb_path.get_file(),
		  "' — ", data.size(), " nodes, ", total_faces, " faces total")
	_cache[glb_path] = data
	return data


## Returns true if armor data for *glb_path* has already been loaded and
## cached (regardless of whether the result was empty or not).
func is_loaded(glb_path: String) -> bool:
	return _cache.has(glb_path)


## Remove the cached entry for *glb_path* so it will be re-extracted on the
## next call to get_or_load().  Useful if the asset is hot-reloaded.
func evict(glb_path: String) -> void:
	_cache.erase(glb_path)


## Drop the entire cache.
func clear_cache() -> void:
	_cache.clear()
	print("ArmorRegistry: cache cleared")


## Diagnostic helper — print a summary of all currently cached entries.
func print_cache_summary() -> void:
	print("\n=== ArmorRegistry cache (", _cache.size(), " entries) ===")
	for path in _cache.keys():
		var d: Dictionary = _cache[path]
		var faces: int = 0
		for v in d.values():
			faces += (v as Array).size()
		print("  ", path.get_file(), "  — ", d.size(), " nodes, ", faces, " faces")
	print("===========================================\n")
