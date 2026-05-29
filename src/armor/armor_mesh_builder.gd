## ArmorMeshBuilder
## Builds a visualisation ArrayMesh directly from an ArmorPart's collision shape.
##
## The face indices stored by ArmorRegistry / ArmorSystemV2 are the same indices
## that physics raycasts return against the ConcavePolygonShape3D.
## ConcavePolygonShape3D.get_faces() returns those triangles unindexed and in
## the identical order, so face_armor_values[i] maps exactly to the three
## vertices at positions i*3 .. i*3+2 in the faces array.
##
## Encoding (16-bit, survives 8-bit-per-channel color storage):
##   COLOR.r = float(armor_mm & 0xFF)        / 255.0   low byte
##   COLOR.g = float((armor_mm >> 8) & 0xFF) / 255.0   high byte
## The armor_thickness_viewer.gdshader decodes COLOR.r/g back to mm.

class_name ArmorMeshBuilder
extends RefCounted

static func build_from_collision(armor_part: ArmorPart, face_armor_values: Array) -> ArrayMesh:
	assert(armor_part != null, "ArmorMeshBuilder: armor_part is null")

	var col_shape_node: CollisionShape3D = null
	for child in armor_part.get_children():
		if child is CollisionShape3D:
			col_shape_node = child as CollisionShape3D
			break
	assert(col_shape_node != null,
		"ArmorMeshBuilder: ArmorPart '%s' has no CollisionShape3D child" % armor_part.name)

	var shape := col_shape_node.shape as ConcavePolygonShape3D
	assert(shape != null,
		"ArmorMeshBuilder: CollisionShape3D in '%s' does not use ConcavePolygonShape3D" % armor_part.name)

	var faces: PackedVector3Array = shape.get_faces()
	var face_count := faces.size() / 3

	assert(face_count == face_armor_values.size(),
		"ArmorMeshBuilder: face count mismatch in '%s' — shape has %d faces, armor data has %d" \
			% [armor_part.name, face_count, face_armor_values.size()])

	var out_pos := PackedVector3Array()
	var out_col := PackedColorArray()

	# CollisionShape3D may have its own local offset relative to the ArmorPart.
	var shape_xform: Transform3D = col_shape_node.transform

	for face_idx in range(face_count):
		var armor_mm: int = int(face_armor_values[face_idx])
		var c := Color(
			float(armor_mm & 0xFF) / 255.0,
			float((armor_mm >> 8) & 0xFF) / 255.0,
			0.0, 1.0)
		for v in range(3):
			out_pos.append(shape_xform * faces[face_idx * 3 + v])
			out_col.append(c)

	var new_arrays: Array = []
	new_arrays.resize(Mesh.ARRAY_MAX)
	new_arrays[Mesh.ARRAY_VERTEX] = out_pos
	new_arrays[Mesh.ARRAY_COLOR] = out_col

	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays)
	return result
