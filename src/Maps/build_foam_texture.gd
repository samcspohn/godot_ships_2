@tool
extends EditorScript

## Run this (Script menu → Run) after generating the frames with gen_foam.py.
## Packs foam_NN.png into one COLS x rows sheet at TILE px per frame and writes
## ocean_foam_array.png, which the 2d_array_texture importer slices back into
## layers. Godot then ships a VRAM-compressed .ctexarray.
##
## It must be a sheet + importer, not a saved Texture2DArray: `ResourceSaver.save`
## to .tres inlines every pixel as base64, which cost 89 MB and 7 s per boot.
## Layers are row-major, so frame order matches the cross-fade in ocean.gdshader.

const FRAMES_DIR  := "res://src/Maps/ocean_foam_frames/"
const FRAME_COUNT := 16
const COLS        := 4
const TILE        := 512
const OUTPUT_PATH := "res://src/Maps/ocean_foam_array.png"


func _run() -> void:
	var rows := int(ceil(float(FRAME_COUNT) / COLS))
	var sheet := Image.create(COLS * TILE, rows * TILE, false, Image.FORMAT_RGBA8)
	for i in FRAME_COUNT:
		var path := FRAMES_DIR + "foam_%02d.png" % i
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		assert(img != null, "Failed to load: " + path)
		img.convert(Image.FORMAT_RGBA8)
		img.resize(TILE, TILE, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, TILE, TILE),
			Vector2i((i % COLS) * TILE, (i / COLS) * TILE))
	sheet.save_png(ProjectSettings.globalize_path(OUTPUT_PATH))
	print("Saved %dx%d sheet (%d layers) → %s" % [sheet.get_width(), sheet.get_height(),
		FRAME_COUNT, OUTPUT_PATH])
	print("If this is a new file, set the importer to '2D Array Texture' with %d x %d slices."
		% [COLS, rows])
