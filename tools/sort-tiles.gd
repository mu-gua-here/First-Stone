
@tool
extends EditorScenePostImport

const ROW_TOLERANCE := 0.2
# Blender's top view has +Y at the top, which becomes -Z in Godot, so the top row has the smallest Z.
# If your rows come out upside down, set this to false.
const TOP_ROW_IS_NEGATIVE_Z := true

func _post_import(scene: Node) -> Object:
	print("\n--- TILE SORTING STARTED ---")

	# Find the base-tiles container.
	var target: Node = scene

	if scene.name != "base-tiles":
		target = scene.find_child("base-tiles", true, false)

	if target == null:
		push_error("Could not find base-tiles node!")
		return scene

	print("Sorting children of: ", target.get_path())

	# Collect the meshes.
	var meshes: Array[Node3D] = []

	for child in target.get_children():
		if child is Node3D:
			meshes.append(child)
			print(child.name, " | Position: ", child.position)

	print("Found ", meshes.size(), " meshes.")

	# Sort by Z position first (top row to bottom row).
	meshes.sort_custom(func(a: Node3D, b: Node3D):
		if TOP_ROW_IS_NEGATIVE_Z:
			return a.position.z > b.position.z
		return a.position.z > b.position.z
	)

	# Group meshes into rows.
	var rows: Array = []
	var current_row: Array[Node3D] = []
	var row_z := 0.0

	for mesh in meshes:
		var z := mesh.position.z

		if current_row.is_empty() or abs(z - row_z) <= ROW_TOLERANCE:
			current_row.append(mesh)

			if current_row.size() == 1:
				row_z = z
		else:
			rows.append(current_row)
			current_row = [mesh]
			row_z = z

	if not current_row.is_empty():
		rows.append(current_row)

	# Sort each row by X position (left to right).
	var sorted_meshes: Array[Node3D] = []

	for row in rows:
		row.sort_custom(func(a: Node3D, b: Node3D):
			return a.position.x < b.position.x
		)

		sorted_meshes.append_array(row)

	# Reorder the actual scene tree.
	for i in range(sorted_meshes.size()):
		target.move_child(sorted_meshes[i], i)
		print(i, ": ", sorted_meshes[i].name)

	print("--- TILE SORTING COMPLETE ---\n")

	return scene
