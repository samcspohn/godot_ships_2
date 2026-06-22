@tool
extends EditorScript

## Run this once (Script menu → Run) after generating the frames with gen_foam.py.
## It loads all foam_NN.png frames, packs them into a Texture2DArray, and saves
## the result as ocean_foam.tres next to this script.
## Assign ocean_foam.tres to the foam_tex slot on the ocean material.

const FRAMES_DIR  := "res://src/Maps/ocean_foam_frames/"
const FRAME_COUNT := 16
const OUTPUT_PATH := "res://src/Maps/ocean_foam.tres"

func _run() -> void:
	var images: Array[Image] = []
	for i in FRAME_COUNT:
		var path := FRAMES_DIR + "foam_%02d.png" % i
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		assert(img != null, "Failed to load: " + path)
		images.append(img)

	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	ResourceSaver.save(arr, OUTPUT_PATH)
	print("Saved Texture2DArray → ", OUTPUT_PATH)
