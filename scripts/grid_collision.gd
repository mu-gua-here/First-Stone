extends GridMap

## Gives every MeshLibrary item a collision shape at game start, so no per-model collision setup
## in Blender or the import dialog is needed. Items that already carry shapes are left alone.
##
##  * Flat tiles (name contains one of flat_keywords: grass, pavement, road...) get a thin slab on
##    their top surface, so characters walk across them. That includes the tree tiles: their
##    canopy does not block anything.
##  * Everything else (buildings, props) gets a convex hull of its mesh.
##  * shape_overrides replaces an item's shape by item name. Assign any Shape3D in the Inspector.

@export var generate_collision := true
@export var flat_keywords: PackedStringArray = ["grass", "pavement", "road"]
## Thickness of the walkable slab on flat tiles, in the item's mesh units (before cell_scale).
@export var slab_height := 0.25
@export var shape_overrides: Dictionary[String, Shape3D] = {}

func _ready() -> void:
	if not generate_collision or mesh_library == null:
		return
	for item in mesh_library.get_item_list():
		if not mesh_library.get_item_shapes(item).is_empty():
			continue
		var mesh := mesh_library.get_item_mesh(item)
		if mesh == null:
			continue
		var item_name := mesh_library.get_item_name(item)

		var shape: Shape3D = shape_overrides.get(item_name)
		var shape_transform := Transform3D.IDENTITY
		if shape == null:
			if _is_flat(item_name):
				var aabb := mesh.get_aabb()
				var slab := BoxShape3D.new()
				slab.size = Vector3(aabb.size.x, slab_height, aabb.size.z)
				shape = slab
				# on the tile's top surface
				shape_transform.origin = Vector3(aabb.get_center().x, aabb.end.y - slab_height * 0.5, aabb.get_center().z)
			else:
				shape = mesh.create_convex_shape(true, true)
		mesh_library.set_item_shapes(item, [shape, shape_transform])

func _is_flat(item_name: String) -> bool:
	for keyword in flat_keywords:
		if item_name.contains(keyword):
			return true
	return false
