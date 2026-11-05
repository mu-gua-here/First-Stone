extends Node3D
class_name Builder

## Responsible for the construction and demolition of structures.
##
## Everything lives IN THE GRIDMAP: a structure is just a MeshLibrary item set into a cell
## (World.set_cell_item), so placing one costs a single cell write -- nothing is instantiated,
## and collision + navigation come from the MeshLibrary item's shapes / navigation mesh.
## Each Structure resource names the MeshLibrary item it uses (Structure.item_name).
## Tiles you paint into the GridMap by hand are picked up automatically at start: any cell whose
## item matches a Structure (e.g. the tree tiles) becomes a real placed structure that citizens
## can gather, assign jobs to, etc.

@export var structures: Array[Structure] = []

var map: DataMap

var index: int = 0 # Index of structure being built

@export var world: GridMap ## the GridMap that holds the structures you build (NOT the ground: that's the Base GridMap)
@export var ground: GridMap ## the Base GridMap under the structures; shows the construction tile while a site is being built
@export var selector: Node3D # The 'cursor'
@export var preview: MeshInstance3D ## shows the selected structure's MeshLibrary mesh on the cursor
@export var view_camera: Camera3D # Used for raycasting mouse
@export var citizen_scene: PackedScene
@export var objects_root: Node3D ## planted trees/props are added under this node (keeps the scene tree tidy)

@export_group("Assets")
## Scene for the little progress bar above construction sites / trees being chopped.
## Assigned in the Inspector -- no preload() in code, so nothing breaks at parse time if it moves.
@export var progress_indicator_scene: PackedScene
## Model of the physics prop spawned for each resource type: drag a .glb / scene in here, e.g.
## "wood" -> models/primitive/log.glb. The first MeshInstance3D found in it is used (with its
## transform), so no need to extract a mesh from the glb first.
## A type with no entry gets a plain placeholder sphere.
@export var resource_prop_meshes: Dictionary[String, PackedScene] = {}
var _prop_visuals := {} # resource_type -> {"mesh": Mesh, "xform": Transform3D}, built once from the scene above

@export_group("Grid")
## GridMap layer (cell Y) that structures are built on: the same layer as the ground tiles.
@export var build_layer := 0
## Height of the plane the mouse falls back to when its ray hits no collision.
@export var pick_plane_y := 0.0
## MeshLibrary item a cell reverts to when a structure is removed (empty = the cell is just cleared,
## right for a Structures map that sits on top of a separate ground map).
@export var ground_item_name := ""
## MeshLibrary item (in the GROUND map's library) shown under a structure while it is being built.
@export var construction_item_name := "construction-tile"
## Physics layers that count as GROUND for mouse picking (the GridMap's collision layer).
## Characters and resource props are excluded on top of this automatically.
@export_flags_3d_physics var ground_collision_mask := 1
## Layers the mouse ray hits when picking (ground + tree trunks), so clicking a trunk finds that tree.
@export_flags_3d_physics var pick_collision_mask := 2
## Layer of the PickBody in each free-standing object's scene (a tree's whole-shape click volume).
## Only pick_object_at() sees it, so it never affects the build cursor, movement or the camera.
@export_flags_3d_physics var object_pick_layer := 16
## Prints what each mouse click hits and how many trees/structures are registered (turn off when done).
@export var debug_picking := false

@export_group("Stockpile")
## Logs only count once pushed within reach of this point. On by default: it is set to wherever
## the player starts, so the pile is never stranded far from the action.
@export var stockpile_at_player_spawn := true
@export var stockpile_position := Vector3.ZERO
## How close (metres, flat) a settled log has to be to the stockpile point to count. The yellow disc is resized to
## match, so this one number is all you change.
@export var stockpile_radius := 3.0

@export_group("HUD nodes")
@export var stockpile_label: Label # top-left resource counter
@export var build_info_label: Label # what's selected while in build mode
@export var build_hint_label: Label # transient warnings (e.g. "not enough wood")
@export var stockpile_marker: Node3D # flat disc marking where logs must be pushed
@export var stockpile_sign: StockpileSign # wooden board at the disc's edge that says "STOCKPILE" and shows the count
@export var popup_scene: PackedScene # the floating "+1 Wood" (pickup_popup.tscn), shown where a log is collected
@export var cursor_sprite: Sprite3D # tile outline on the build cursor (Selector/Sprite): green = can build here, red = can't
@export var demolish_ring_scene: PackedScene # the circular timer over a building being taken apart (demolish_ring_3d.tscn)
@export_group("Stockpile stacking")
## Logs that reach the stockpile fly onto a neat woodpile inside the yellow area.
@export var stack_columns := 4 # logs side by side along x in one layer
@export var stack_rows := 2 # rows along z in one layer; further logs start a new layer on top
@export var stack_spacing := Vector3(1.5, 0.5, 0.7) # metres between logs (x), layers (y) and rows (z)
@export var stack_rotation_degrees := Vector3(0, 90, 0) # how a log lies on the pile: change this if yours points the wrong way
@export_group("")

var citizens = []

# id (String) -> {"cell": Vector3i, "structure_index": int, "position": Vector3, "rotation_y": float,
#                 "previous_item": int, "previous_orientation": int}
var placed_structures: Dictionary = {}
var _cell_ids: Dictionary = {} # Vector3i -> id, for every placed structure

var buildings: Dictionary = {} # id (String) -> BuildingInstance, for placed HOUSE/SHOP/WORKPLACE structures

var construction_sites: Dictionary = {} # id (String) -> ConstructionSite, for structures still being built
var _site_cells: Dictionary = {} # Vector3i -> site id
var construction_visuals: Dictionary = {} # id (String) -> {"bar": ProgressIndicator3D, "cell": Vector3i, "prev_item": int, "prev_orientation": int}

# MeshLibrary item ids, resolved once from the names (see _resolve_mesh_items)
var _item_ids: Array[int] = [] # structure index -> item id
var _hotbar_count := 0 # how many structures the hotbar lists (Gatherable objects register extra ones after these)
var _object_ids: Dictionary = {} # Node3D -> id, for free-standing registered objects (trees)
var _depleted_ids: Array[int] = [] # structure index -> item the cell turns into when it's chopped
var _ground_item: int = GridMap.INVALID_CELL_ITEM
var _construction_item: int = GridMap.INVALID_CELL_ITEM

const SFX_PLACE := "sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg"
const SFX_REMOVE := "sounds/removal-a.ogg, sounds/removal-b.ogg, sounds/removal-c.ogg, sounds/removal-d.ogg"

# Convex collision shape per resource type, built once from its mesh and shared by every prop
var _prop_shapes: Dictionary = {}

# Mass for a placeholder resource prop's RigidBody3D
const RESOURCE_PROP_MASS := 0.25
const RESOURCE_SPAWN_HEIGHT := 3.0 # props drop from this far above a cell's floor

const GHOST_BAR_HEIGHT := 3.0 # local Y offset above a construction cell's floor
const GATHER_BAR_HEIGHT := 3.0 # local Y offset above a gathered tile's floor
const PROGRESS_BAR_VISIBLE_DISTANCE := 8.0

var gather_visuals: Dictionary = {} # id (String) -> ProgressIndicator3D, for trees actively being chopped
var gather_progress: Dictionary = {} # id (String) -> 0.0-1.0 persisted chop progress
var demolish_progress: Dictionary = {} # id (String) -> 0.0-1.0 how far a structure/site has been taken apart
var demolish_visuals: Dictionary = {} # id (String) -> DemolishRing3D
var _demolish_touched: Dictionary = {} # id (String) -> msec when labour last went into it (progress fades once it stops)
var _stacked: Array = [] # the logs on the woodpile, index = slot (null = a gap left by wood that was used up)

var plane: Plane # Used for raycasting mouse

var interact_mode: bool = false  # Toggle between building and movement modes

const NO_ID := ""
const DEMOLISH_REACH := 2.0 # fallback: how far (flat) from a click a structure/site may be and still be found
const PICK_RADIUS := 2.0 # how far (flat) a mouse pick may land from a structure/site and still select it
const PICK_RAY_LENGTH := 1000.0
const GROUND_RAY_TOP := 200.0 # ground-height probes fall from here...
const GROUND_RAY_BOTTOM := -200.0 # ...to here

# UI -- the nodes themselves live in main.tscn (BuilderHUD); this script only fills in their text
var hotbar_page: int = 0  # which page of 10 structure slots the player is on
var _last_hud_text := ""
var _last_info_text := ""
var build_hint_timer: float = 0.0
const BUILD_HINT_DURATION := 3.0 # seconds a build hint stays visible

var _id_counter := 0
var _citizen_counter := 0
var _prop_counter := 0
var _planted_counter := 0

func _ready():

	add_to_group("builder")
	Globals.register_builder(self)

	map = DataMap.new()
	plane = Plane(Vector3.UP, pick_plane_y)

	if stockpile_at_player_spawn:
		stockpile_position = Globals.get_player_position()
		stockpile_position.y = 0.0 # flat point; only X/Z matter (see ResourceProp)

	_resolve_mesh_items()
	_fit_cursor()
	_hotbar_count = structures.size()
	_register_authored_cells()
	update_structure()

	# Start in movement mode (no build cursor)
	selector.visible = false

	# Deferred: spawning citizens is a one-time setup cost that would otherwise land in the same
	# frame as every other node's _ready(). Awaiting a frame spreads it onto frame 2.
	await get_tree().process_frame
	if Globals.hosting_world: # online, only the server simulates citizens (clients get puppets, see citizen.gd)
		spawn_citizens(5)

	# Free-standing choppable objects (trees) that were ready before the Builder registered themselves now
	for node in get_tree().get_nodes_in_group("gatherable"):
		if node is Gatherable and node.structure != null:
			register_gatherable(node, node.structure)

	# Ground probes (stockpile marker) need the GridMap's collision registered with the physics server
	await get_tree().physics_frame
	_place_stockpile_marker()

# --- GridMap cells ---------------------------------------------------------

## Distance on the ground plane (ignores height), used for every click check so a hit on a
## tree's canopy still counts as "at" its trunk.
static func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

# The build-layer cell under a world position
func world_to_cell(pos: Vector3) -> Vector3i:
	var cell := world.local_to_map(world.to_local(pos))
	cell.y = build_layer
	return cell

# World position of a cell's origin (cell centre in X/Z, its floor in Y when cell_center_y is off)
func cell_to_world(cell: Vector3i) -> Vector3:
	return world.to_global(world.map_to_local(cell))

# GridMap orientation index for a yaw. Only the four 90-degree turns exist, so snap to those.
func _orientation_for(rotation_y: float) -> int:
	var steps := posmod(roundi(rotation_y / (PI * 0.5)), 4)
	var b := Basis(Vector3.UP, steps * PI * 0.5)
	for i in 3:
		b[i] = Vector3(roundf(b[i].x), roundf(b[i].y), roundf(b[i].z))
	return world.get_orthogonal_index_from_basis(b)

func _yaw_for(orientation: int) -> float:
	var b := world.get_basis_with_orthogonal_index(orientation)
	return atan2(-b.x.z, b.x.x)

# Looks up every structure's MeshLibrary item by name, once. Missing names are reported with the
# names that DO exist, so a typo / stale library is obvious instead of silently placing nothing.
func _resolve_mesh_items() -> void:
	_item_ids.clear()
	_depleted_ids.clear()
	if world == null or world.mesh_library == null:
		push_error("Builder: `world` (the GridMap) or its MeshLibrary is not set -- nothing can be built.")
		return
	_ground_item = _find_item(ground_item_name)
	_construction_item = _find_item(construction_item_name, ground.mesh_library if ground != null else null)
	for structure in structures:
		_item_ids.append(_find_item(structure.item_name))
		_depleted_ids.append(_find_item(structure.depleted_item_name) if structure.depleted_item_name != "" else _ground_item)

func _find_item(item_name: String, lib: MeshLibrary = null) -> int:
	if item_name == "":
		return GridMap.INVALID_CELL_ITEM
	if lib == null:
		lib = world.mesh_library
	if lib == null:
		return GridMap.INVALID_CELL_ITEM
	var item := lib.find_item_by_name(item_name)
	if item == GridMap.INVALID_CELL_ITEM:
		var names: Array[String] = []
		for id in lib.get_item_list():
			names.append("'%s'" % lib.get_item_name(id))
		push_warning("Builder: the MeshLibrary has no item named '%s'. Its items are: %s" % [item_name, ", ".join(names)])
	return item

# Cells you painted into the GridMap by hand whose item matches a Structure (e.g. tree tiles)
# become real placed structures, so they can be gathered / assigned / demolished like built ones.
# If several structures share one item (e.g. two lodges on the hut tile) the first one wins.
func _register_authored_cells() -> void:
	var claimed: Dictionary = {}
	for i in structures.size():
		var item := _item_ids[i] if i < _item_ids.size() else GridMap.INVALID_CELL_ITEM
		if item == GridMap.INVALID_CELL_ITEM or claimed.has(item):
			continue
		claimed[item] = true
		for cell in world.get_used_cells_by_item(item):
			if not _cell_ids.has(cell):
				_register_structure(i, cell, _yaw_for(world.get_cell_item_orientation(cell)))

# --- Mouse picking / ground ------------------------------------------------

# Bodies a pick/ground ray should look straight through: characters and loose resource props.
func _pick_excludes() -> Array[RID]:
	var rids: Array[RID] = []
	for group in ["player", "citizen", "resource_prop"]:
		for n in get_tree().get_nodes_in_group(group):
			if n is CollisionObject3D:
				rids.append(n.get_rid())
	return rids

## Where the mouse points in the world, or null. A physics ray against the GridMap's collision;
## falls back to the horizontal plane at pick_plane_y when nothing is hit.
func pick_world_position(screen_pos: Vector2) -> Variant:
	if view_camera == null:
		return null
	var from := view_camera.project_ray_origin(screen_pos)
	var dir := view_camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * PICK_RAY_LENGTH, pick_collision_mask)
	query.exclude = _pick_excludes()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if debug_picking and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var from_player := "%.1f m" % hit.position.distance_to(Globals.player.global_position) if (not hit.is_empty() and Globals.player != null) else "-"
		print("[pick] hit=%s (%s from player) collider=%s registered=%d" % [hit.get("position", "nothing -> plane"), from_player, hit.get("collider"), placed_structures.size()])
	if not hit.is_empty():
		return hit.position
	return plane.intersects_ray(from, dir)

## The registered free-standing object (tree) under the mouse, or NO_ID. One physics ray against the
## ground AND every object's PickBody: the nearest hit wins, so a hill or a nearer tree correctly
## hides whatever is behind it (no screen buffer needed, the physics ray is the depth test).
## Any collider under a registered object counts, so the trunk or the PickBody both resolve to it.
func pick_object_at(screen_pos: Vector2) -> String:
	if view_camera == null:
		return NO_ID
	var from := view_camera.project_ray_origin(screen_pos)
	var dir := view_camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * PICK_RAY_LENGTH, pick_collision_mask | object_pick_layer)
	query.exclude = _pick_excludes()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return NO_ID
	var node := hit.collider as Node
	while node != null:
		if _object_ids.has(node):
			return _object_ids[node]
		node = node.get_parent()
	return NO_ID

## Ground surface height at (x, z) from a downward physics ray, or NAN if there is no ground
## collision there.
func _ground_height_or_nan(pos: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(pos.x, GROUND_RAY_TOP, pos.z), Vector3(pos.x, GROUND_RAY_BOTTOM, pos.z), ground_collision_mask)
	query.exclude = _pick_excludes()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position.y if not hit.is_empty() else NAN

# Moves the scene's StockpileMarker disc (a node in main.tscn) onto the stockpile point.
func _place_stockpile_marker() -> void:
	if stockpile_marker == null:
		return
	var ground_y := _ground_height_or_nan(stockpile_position)
	stockpile_marker.global_position = Vector3(stockpile_position.x, (0.0 if is_nan(ground_y) else ground_y) + 0.05, stockpile_position.z)
	# The wooden sign (stockpile_sign) is NOT moved from here: put it wherever you like in the editor.
	# The disc shows the collection area, so it follows stockpile_radius
	var disc := (stockpile_marker as MeshInstance3D).mesh as CylinderMesh
	if disc != null:
		disc.top_radius = stockpile_radius
		disc.bottom_radius = stockpile_radius
	print("Stockpile at (%.1f, %.1f), radius %.1f" % [stockpile_position.x, stockpile_position.z, stockpile_radius])

func _generate_id() -> String:
	_id_counter += 1
	return "s_%d_%d" % [Time.get_ticks_usec(), _id_counter]

func _process(delta):

	# Controls
	action_interact_mode() # Toggle between building and movement modes
	action_rotate() # Rotates selection 90 degrees
	action_structure_toggle() # Toggles between structures

	action_save() # Saving
	action_load() # Loading

	# Only show selector and process building in building mode. The cursor snaps to the cell
	# the mouse is over.
	if interact_mode and world != null:
		var picked = pick_world_position(Globals.aim_position())
		if picked != null:
			var world_position: Vector3 = picked
			var cell := world_to_cell(world_position)
			_update_cursor(cell)
			# Free-standing objects (trees) aren't grid-bound: the cursor follows the mouse exactly
			var target := world_position if (not structures.is_empty() and structures[index].scene != null) else cell_to_world(cell)
			selector.global_position = selector.global_position.lerp(target, min(delta * 40, 1.0))
			action_build(cell, world_position)

	_process_construction(delta)
	_decay_demolish(delta)
	_update_progress_bar_visibility()
	_update_hud()

	if build_hint_timer > 0.0:
		build_hint_timer -= delta
		if build_hint_timer <= 0.0:
			if build_hint_label != null:
				build_hint_label.visible = false

# --- Placing / removing structures (GridMap cells) ---------------------------

# Records a structure that already occupies `cell` in the GridMap and returns its new id.
func _register_structure(structure_index: int, cell: Vector3i, rotation_y: float, previous_item: int = GridMap.INVALID_CELL_ITEM, previous_orientation: int = 0) -> String:
	var structure := structures[structure_index]
	# Id from the cell: the server and every client build the same id for the same structure (multiplayer)
	var id := "s_%d_%d_%d" % [cell.x, cell.y, cell.z]

	placed_structures[id] = {
		"cell": cell,
		"structure_index": structure_index,
		"position": cell_to_world(cell),
		"rotation_y": rotation_y,
		"previous_item": previous_item,
		"previous_orientation": previous_orientation,
	}
	_cell_ids[cell] = id

	var is_housing := structure.type == Structure.Type.HOUSE or structure.type == Structure.Type.SHOP
	var is_workplace := structure.type == Structure.Type.WORKPLACE
	if is_housing or is_workplace:
		var instance := BuildingInstance.new()
		instance.id = id
		instance.structure_index = structure_index
		buildings[id] = instance

	return id

# Sets the structure's MeshLibrary item into `cell` and registers it. NO_ID if its item is missing.
func _place_structure(structure_index: int, cell: Vector3i, rotation_y: float, previous_item: int = GridMap.INVALID_CELL_ITEM, previous_orientation: int = 0) -> String:
	if structure_index < 0 or structure_index >= structures.size() or structure_index >= _item_ids.size():
		return NO_ID
	var item := _item_ids[structure_index]
	if item == GridMap.INVALID_CELL_ITEM:
		return NO_ID
	if previous_item == GridMap.INVALID_CELL_ITEM:
		previous_item = world.get_cell_item(cell)
		previous_orientation = world.get_cell_item_orientation(cell)
	world.set_cell_item(cell, item, _orientation_for(rotation_y))
	return _register_structure(structure_index, cell, rotation_y, previous_item, previous_orientation)

# --- Free-standing objects (trees): registered, not grid-bound ---------------

## Called by Gatherable nodes (and the start-up scan). Gives the object an id like any placed
## structure, so gathering, chop progress and log spawning work on it unchanged. Its Structure
## is appended to `structures` (after the hotbar entries) so existing lookups by index keep working.
func register_gatherable(node: Node3D, structure: Structure) -> String:
	if _object_ids.has(node):
		return _object_ids[node]
	var structure_index := structures.find(structure)
	if structure_index < 0:
		structures.append(structure)
		_item_ids.append(GridMap.INVALID_CELL_ITEM)
		_depleted_ids.append(GridMap.INVALID_CELL_ITEM)
		structure_index = structures.size() - 1

	# Id from the node's path, the same on the server and every client (multiplayer)
	var id := "o_" + str(node.get_path())
	placed_structures[id] = {
		"node": node,
		"structure_index": structure_index,
		"position": node.global_position,
		"rotation_y": node.global_rotation.y,
	}
	_object_ids[node] = id
	node.tree_exiting.connect(_on_object_exiting.bind(id, node))
	return id

# An object left the tree (chopped, or freed by something else): forget it
func _on_object_exiting(id: String, node: Node3D) -> void:
	_object_ids.erase(node)
	if placed_structures.has(id):
		clear_chop_progress(id)
		placed_structures.erase(id)

# Plants a free-standing object (tree) at a world position, under objects_root
func _plant_object(structure: Structure, pos: Vector3, node_name: String = "", yaw: float = -1.0) -> void:
	var node := structure.scene.instantiate() as Node3D
	if node == null:
		return
	if node_name != "":
		node.name = node_name # online: the same name on every copy, so the object gets the same id everywhere
	(objects_root if objects_root != null else self).add_child(node)
	node.global_position = pos
	node.rotation.y = yaw if yaw >= 0.0 else randf() * TAU
	# The node registered itself in _ready(), before it had been moved: refresh its recorded position
	if _object_ids.has(node):
		placed_structures[_object_ids[node]]["position"] = node.global_position

# Removes a placed structure: its cell reverts to what was there before (or the ground tile,
# or Structure.depleted_item_name), and any BuildingInstance tracking it is dropped.
func remove_structure_instance(id: String) -> void:
	clear_demolish(id)
	if not placed_structures.has(id):
		return
	var entry = placed_structures[id]
	if entry.has("node"):
		# free-standing object: just remove the node (_on_object_exiting cleans up the records)
		var node: Node3D = entry["node"]
		if is_instance_valid(node):
			node.queue_free()
		else:
			placed_structures.erase(id)
		return
	var structure_index: int = entry["structure_index"]
	var cell: Vector3i = entry["cell"]

	var revert_item := GridMap.INVALID_CELL_ITEM
	var revert_orientation := 0
	var has_depleted := structure_index >= 0 and structure_index < structures.size() and structures[structure_index].depleted_item_name != ""
	if has_depleted:
		revert_item = _depleted_ids[structure_index]
	elif entry["previous_item"] != GridMap.INVALID_CELL_ITEM:
		revert_item = entry["previous_item"]
		revert_orientation = entry["previous_orientation"]
	else:
		revert_item = _ground_item
	world.set_cell_item(cell, revert_item, revert_orientation)

	placed_structures.erase(id)
	_cell_ids.erase(cell)
	_vacate_building(id)
	buildings.erase(id)

func get_structure_index(id: String) -> int:
	if not placed_structures.has(id):
		return -1
	return placed_structures[id]["structure_index"]

func get_structure_position(id: String) -> Vector3:
	if not placed_structures.has(id):
		return Vector3.INF
	return placed_structures[id]["position"]

# The placed structure at world_pos: the one occupying its cell, else the nearest within max_dist
# (measured on the ground plane), else NO_ID. Used by demolish, click-to-assign and mouse picking.
func get_structure_at_point(world_pos: Vector3, max_dist: float) -> String:
	if world != null:
		var cell := world_to_cell(world_pos)
		if _cell_ids.has(cell):
			return _cell_ids[cell]
	var nearest_id := NO_ID
	var nearest_dist := max_dist * max_dist
	for id in placed_structures.keys():
		var p: Vector3 = placed_structures[id]["position"]
		var dist := Vector2(world_pos.x - p.x, world_pos.z - p.z).length_squared()
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id
	return nearest_id

# The construction site on world_pos's cell, else the nearest within max_dist, else NO_ID.
func _construction_site_near(pos: Vector3, max_dist: float) -> String:
	if world != null:
		var cell := world_to_cell(pos)
		if _site_cells.has(cell):
			return _site_cells[cell]
	for id in construction_sites.keys():
		if flat_distance(construction_sites[id].position, pos) <= max_dist:
			return id
	return NO_ID

# Build (place) a structure on a cell

func action_build(cell: Vector3i, world_position: Vector3):
	if Input.is_action_just_pressed("build"):

		if structures.is_empty():
			return # nothing selectable -- see update_structure()'s guard

		# Not unlocked yet (Structure.unlock_requirements vs. lifetime wood/etc gathered)
		if not is_unlocked(index):
			_flash_build_hint("Locked: " + _unlock_text(structures[index]))
			return

		# Free-standing objects (trees) are planted at the mouse point, anywhere
		if structures[index].scene != null:
			_build_or_request(index, cell, world_position)
			Audio.play(SFX_PLACE, -20)
			return

		if _cell_ids.has(cell):
			_flash_build_hint("Something is already built there. Demolish it first.")
			return
		if _site_cells.has(cell):
			_flash_build_hint("A site is already under construction there.")
			return
		if _object_in_cell(cell):
			_flash_build_hint("A tree is in the way.")
			return

		if index >= _item_ids.size() or _item_ids[index] == GridMap.INVALID_CELL_ITEM:
			_flash_build_hint("'%s' isn't in the MeshLibrary." % structures[index].item_name)
			return

		# Plants (trees) go straight into the ground; everything else is a construction
		# site that builders have to finish.
		if structures[index].gatherable:
			_build_or_request(index, cell, world_position)
			Audio.play(SFX_PLACE, -20)
			return

		_warn_if_insufficient_resources(structures[index])
		_build_or_request(index, cell, world_position)

		Audio.play(SFX_PLACE, -20)

# Flashes a heads-up if the stockpile can't currently cover the full build cost
func _warn_if_insufficient_resources(structure: Structure) -> void:
	var missing: Array[String] = []
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var available: int = map.stockpile.get(resource_type, 0)
		if available < needed:
			missing.append("%s (%d/%d)" % [String(resource_type).capitalize(), available, needed])
	if not missing.is_empty():
		_flash_build_hint("Not enough resources yet -- site will wait for: " + ", ".join(missing))

# --- Demolishing takes labour: hold Del and click-and-hold the structure (see Player._update_demolishing) ---

const DEMOLISH_RECOVERY := 0.25 # share of the job a building recovers per second once nobody is working on it
const DEMOLISH_RING_HEIGHT := 3.5 # metres above the structure's floor

# Can this id (a placed structure or a construction site) be taken apart? Trees are chopped, not demolished.
func can_demolish(id: String) -> bool:
	return construction_sites.has(id) or (id.begins_with("s_") and placed_structures.has(id))

func get_demolish_position(id: String) -> Vector3:
	if construction_sites.has(id):
		return construction_sites[id].position
	return get_structure_position(id)

# Seconds of labour the whole job takes (Structure.demolish_time)
func get_demolish_time(id: String) -> float:
	var structure_index := -1
	if construction_sites.has(id):
		structure_index = construction_sites[id].structure_index
	else:
		structure_index = get_structure_index(id)
	if structure_index < 0:
		return 4.0
	return maxf(structures[structure_index].demolish_time, 0.1)

## Puts `amount` (0..1 of the whole job) of labour into taking `id` apart. True once it has fallen down.
func add_demolish_progress(id: String, amount: float) -> bool:
	if not can_demolish(id):
		return false
	if Globals.online_client:
		Globals.world_sync.client_demolish(id, amount) # the server does the work
		return false
	var progress := clampf(demolish_progress.get(id, 0.0) + amount, 0.0, 1.0)
	demolish_progress[id] = progress
	_demolish_touched[id] = Time.get_ticks_msec()
	update_demolish_ring(id, progress)
	if Globals.hosting_world and Globals.world_sync != null:
		Globals.world_sync.server_demolish_progress(id, progress)
	if progress < 1.0:
		return false
	_finish_demolish(id)
	return true

# The circle has completed its turn: the structure (or site) goes
func _finish_demolish(id: String) -> void:
	if construction_sites.has(id):
		_cancel_construction(id)
		_net("site_cancel", [id])
	else:
		remove_structure_instance(id)
		_net("remove", [id])
	Audio.play(SFX_REMOVE, -20)

# Labour that stops lets the building recover
func _decay_demolish(delta: float) -> void:
	if Globals.online_client or demolish_progress.is_empty():
		return
	var now := Time.get_ticks_msec()
	for id in demolish_progress.keys():
		if now - int(_demolish_touched.get(id, now)) < 600:
			continue
		var progress: float = demolish_progress[id] - delta * DEMOLISH_RECOVERY
		if progress <= 0.0:
			clear_demolish(id)
			progress = 0.0
		else:
			demolish_progress[id] = progress
			update_demolish_ring(id, progress)
		if Globals.hosting_world and Globals.world_sync != null:
			Globals.world_sync.server_demolish_progress(id, progress)

func update_demolish_ring(id: String, progress: float) -> void:
	if progress <= 0.0:
		clear_demolish(id)
		return
	if not demolish_visuals.has(id):
		if demolish_ring_scene == null or not can_demolish(id):
			return
		var ring: DemolishRing3D = demolish_ring_scene.instantiate()
		add_child(ring)
		ring.global_position = get_demolish_position(id) + Vector3(0, DEMOLISH_RING_HEIGHT, 0)
		demolish_visuals[id] = ring
	demolish_visuals[id].set_progress(progress)

# Forgets the damage and removes the ring (also called when the structure is gone)
func clear_demolish(id: String) -> void:
	demolish_progress.erase(id)
	_demolish_touched.erase(id)
	if demolish_visuals.has(id):
		demolish_visuals[id].queue_free()
		demolish_visuals.erase(id)

# Client side of the server's "demolish_progress"
func apply_demolish_progress(id: String, progress: float) -> void:
	if progress <= 0.0:
		clear_demolish(id)
	elif can_demolish(id):
		demolish_progress[id] = progress
		update_demolish_ring(id, progress)

# --- Build cursor (Selector/Sprite): outlines the tile the structure will go on ---

func _fit_cursor() -> void:
	if cursor_sprite == null or cursor_sprite.texture == null or world == null:
		return
	# Cover one grid cell (a touch smaller so neighbouring outlines don't touch)
	cursor_sprite.pixel_size = world.cell_size.x * 0.96 / float(cursor_sprite.texture.get_width())

func _update_cursor(cell: Vector3i) -> void:
	if cursor_sprite == null or structures.is_empty():
		return
	# Trees are planted at the mouse point, not on a tile
	cursor_sprite.visible = structures[index].scene == null
	var can_build := is_unlocked(index) and not _cell_ids.has(cell) and not _site_cells.has(cell) and not _object_in_cell(cell) \
			and index < _item_ids.size() and _item_ids[index] != GridMap.INVALID_CELL_ITEM
	cursor_sprite.modulate = Color(0.55, 1.0, 0.55, 0.9) if can_build else Color(1.0, 0.4, 0.35, 0.9)

# --- Stockpile feedback: a log reaching the pile ---

# Everyone sees it when a log is collected: a floating "+1 Wood", the board bounces, a thunk
func on_prop_collected(prop: ResourceProp) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var resource_type: String = prop.get_meta("resource_type", "")
	var amount: int = prop.get_meta("amount", 1)
	if popup_scene != null:
		var popup: PickupPopup = popup_scene.instantiate()
		add_child(popup)
		popup.pop(prop.global_position + Vector3(0, 1.0, 0), "+%d %s" % [amount, resource_type.capitalize()])
	if stockpile_sign != null:
		stockpile_sign.bounce()
	Audio.play(SFX_PLACE, -12)

# Where the next collected log goes on the woodpile (server / offline). Fills one layer (columns x rows) at a time,
# then starts the next layer on top. A gap left by wood that was used up is refilled first.
func claim_stack_slot(prop: ResourceProp) -> Transform3D:
	var slot := _stacked.find(null)
	if slot == -1:
		slot = _stacked.size()
		_stacked.append(prop)
	else:
		_stacked[slot] = prop
	var columns := maxi(stack_columns, 1)
	var rows := maxi(stack_rows, 1)
	var per_layer := columns * rows
	var layer := floori(float(slot) / per_layer)
	var in_layer := slot % per_layer
	var row := floori(float(in_layer) / columns)
	var column := in_layer % columns
	var local := Vector3(
		(column - (columns - 1) * 0.5) * stack_spacing.x,
		0.25 + layer * stack_spacing.y,
		(row - (rows - 1) * 0.5) * stack_spacing.z)
	var base_y := stockpile_marker.global_position.y if stockpile_marker != null else stockpile_position.y
	var origin := Vector3(stockpile_position.x, base_y, stockpile_position.z) + local
	var lying := Basis.from_euler(Vector3(deg_to_rad(stack_rotation_degrees.x), deg_to_rad(stack_rotation_degrees.y), deg_to_rad(stack_rotation_degrees.z)))
	return Transform3D(lying, origin)

# The wood a building draws from the stockpile comes off the woodpile: those logs shrink away, newest first.
func _consume_stacked_logs(resource_type: String, amount: int) -> void:
	var remaining := amount
	var slot := _stacked.size() - 1
	while remaining > 0 and slot >= 0:
		var prop := _stacked[slot] as ResourceProp
		if prop != null and is_instance_valid(prop) and String(prop.get_meta("resource_type", "")) == resource_type:
			remaining -= int(prop.get_meta("amount", 1))
			_net("prop_consume", [String(prop.name)])
			prop.consume()
			_stacked[slot] = null
		slot -= 1
	while not _stacked.is_empty() and _stacked.back() == null:
		_stacked.pop_back()

# Client side of "prop_consume"
func consume_prop(prop_name: String) -> void:
	var prop := get_node_or_null(NodePath(prop_name)) as ResourceProp
	if prop != null:
		prop.consume()

# A free-standing tree (any placed scene object) on this tile blocks building there
func _object_in_cell(cell: Vector3i) -> bool:
	for node in _object_ids.keys():
		if is_instance_valid(node) and node is Node3D and world_to_cell(node.global_position) == cell:
			return true
	return false

# --- Multiplayer: the server does the building, clients ask (see world_sync.gd) -----------------------------------

# Tells every client what just happened (no-op unless we are the server). `event` names are handled in
# WorldSync._apply(); the server also keeps them in a log that late joiners are caught up with.
func _net(event: String, args: Array) -> void:
	if Globals.hosting_world and Globals.world_sync != null:
		Globals.world_sync.broadcast(event, args)

# The build cursor's click. Online it is only a request: the server decides, then tells everyone (including us).
func _build_or_request(structure_index: int, cell: Vector3i, world_position: Vector3) -> void:
	if Globals.online_client:
		Globals.world_sync.req_build(structure_index, cell, selector.rotation.y, world_position)
	else:
		perform_build(structure_index, cell, selector.rotation.y, world_position)

# The actual placing. Runs on the server (or offline). Checks everything again, because online the request
# came from a client.
func perform_build(structure_index: int, cell: Vector3i, rotation_y: float, world_position: Vector3) -> void:
	if structure_index < 0 or structure_index >= structures.size() or not is_unlocked(structure_index):
		return
	var structure := structures[structure_index]
	# Free-standing objects (trees) are planted at the point, anywhere
	if structure.scene != null:
		_planted_counter += 1
		var planted_name := "Planted_%d" % _planted_counter
		var yaw := randf() * TAU
		_plant_object(structure, world_position, planted_name, yaw)
		_net("plant", [structure_index, world_position, yaw, planted_name])
		return
	if _cell_ids.has(cell) or _site_cells.has(cell) or _object_in_cell(cell):
		return
	if structure_index >= _item_ids.size() or _item_ids[structure_index] == GridMap.INVALID_CELL_ITEM:
		return
	# Plants (trees) go straight into the ground; everything else is a construction site builders have to finish
	if structure.gatherable:
		_place_structure(structure_index, cell, rotation_y)
		_net("place", [structure_index, cell, rotation_y])
		return
	_start_construction(cell, rotation_y, structure_index)
	_net("site_start", [structure_index, cell, rotation_y])


# Client side of "site_state" (progress, and whether its resources are in, which sets the bar's colour)
func apply_site_state(id: String, progress: float, resourced: bool, committed: Dictionary = {}) -> void:
	if not construction_sites.has(id):
		return
	construction_sites[id].progress = progress
	construction_sites[id].resources_committed = committed
	if construction_visuals.has(id):
		var bar: ProgressIndicator3D = construction_visuals[id]["bar"]
		bar.set_progress(progress)
		bar.set_bar_color(Color(0.6, 0.6, 0.65) if resourced else Color(0.85, 0.35, 0.25))

func is_site_resourced(id: String) -> bool:
	if not construction_sites.has(id):
		return false
	var site: ConstructionSite = construction_sites[id]
	return _resources_fully_committed(site, structures[site.structure_index])

# Client side of "chop_progress"
func apply_chop_progress(id: String, progress: float) -> void:
	if not placed_structures.has(id):
		return
	gather_progress[id] = progress
	update_gather_progress(id, progress)

func mark_prop_collected(prop_name: String, feedback: bool = true) -> void:
	var prop := get_node_or_null(NodePath(prop_name)) as ResourceProp
	if prop != null:
		prop.collected = true
		if feedback:
			on_prop_collected(prop)

# Toggle between building mode and movement mode

func action_interact_mode():
	if InputMap.has_action("interact_mode") and Input.is_action_just_pressed("interact_mode"):
		interact_mode = !interact_mode
		selector.visible = interact_mode
		if Audio:
			Audio.play("sounds/toggle.ogg", -30)

# Rotates the 'cursor' 90 degrees

func action_rotate():
	if Input.is_action_just_pressed("rotate"):
		selector.rotate_y(deg_to_rad(90))

		Audio.play("sounds/rotate.ogg", -30)

# Toggle between structures to build

func action_structure_toggle():
	# Direct hotbar select: keys 1-9, 0 map to slots 0-9 of the current page
	var page_count = ceili(float(_hotbar_count) / 10.0)
	var previous_index := index
	for i in range(10):
		if Input.is_action_just_pressed("selection_%d" % i):
			var target = hotbar_page * 10 + i
			if target < _hotbar_count:
				index = target
				Audio.play("sounds/toggle.ogg", -30)

	# Page through the hotbar when there are more than 10 structures
	if Input.is_action_just_pressed("hotbar_page_next"):
		hotbar_page = wrap(hotbar_page + 1, 0, page_count)
		Audio.play("sounds/toggle.ogg", -30)

	if Input.is_action_just_pressed("hotbar_page_prev"):
		hotbar_page = wrap(hotbar_page - 1, 0, page_count)
		Audio.play("sounds/toggle.ogg", -30)

	# Only rebuild the preview when the selection actually changed
	if index != previous_index:
		update_structure()

# Update the structure visual in the 'cursor': just the selected item's MeshLibrary mesh,
# shown on the scene's Preview node (no scene is instantiated).

func update_structure():
	if structures.is_empty():
		push_warning("Builder: structures array is empty -- nothing to build/preview.")
		return
	index = clampi(index, 0, _hotbar_count - 1)

	if preview == null or world == null or world.mesh_library == null:
		return
	var item := _item_ids[index] if index < _item_ids.size() else GridMap.INVALID_CELL_ITEM
	if item == GridMap.INVALID_CELL_ITEM:
		preview.mesh = null
		return
	var lib := world.mesh_library
	preview.mesh = lib.get_item_mesh(item)
	var t := lib.get_item_mesh_transform(item)
	# GridMap draws items scaled by cell_scale; match that so the preview fits the cell
	preview.transform = Transform3D(t.basis * Basis.from_scale(Vector3.ONE * world.cell_scale), t.origin * world.cell_scale)

# --- HUD (stockpile counter, build selection, hints) ------------------------
# The labels are scene nodes (BuilderHUD in main.tscn); style and position them in the 2D editor.

# Cheap per-frame refresh: strings are only rebuilt into the labels when they actually change.
# Resources construction sites have already drawn from the stockpile (resource type -> amount)
func _reserved_resources() -> Dictionary:
	var total := {}
	for site in construction_sites.values():
		for key in site.resources_committed:
			total[key] = int(total.get(key, 0)) + int(site.resources_committed[key])
	return total

func _update_hud() -> void:
	if stockpile_label == null:
		return
	var parts: Array[String] = []
	var reserved := _reserved_resources()
	for key in map.stockpile.keys():
		var part := "%s: %d" % [String(key).capitalize(), map.stockpile[key]]
		# Wood a construction site has already drawn from the stockpile is not lost, it is waiting inside the site
		if reserved.get(key, 0) > 0:
			part += " (+%d in sites)" % reserved[key]
		parts.append(part)
	var text := "   ".join(parts)
	if text != _last_hud_text:
		_last_hud_text = text
		stockpile_label.text = text
		if stockpile_sign != null:
			stockpile_sign.set_counts(text.replace("   ", "\n"))

	build_info_label.visible = interact_mode and not structures.is_empty()
	if build_info_label.visible:
		var structure := structures[index]
		var info := "Building [%d]: %s" % [(index % 10 + 1) % 10, structure.get_display_name()]
		if not structure.build_cost.is_empty():
			var costs: Array[String] = []
			for key in structure.build_cost.keys():
				costs.append("%d %s" % [structure.build_cost[key], String(key)])
			info += "  (" + ", ".join(costs) + ")"
		elif structure.gatherable:
			info += "  (plant)"
		if not is_unlocked(index):
			info += "  -- LOCKED: " + _unlock_text(structure)
		if index < _item_ids.size() and _item_ids[index] == GridMap.INVALID_CELL_ITEM and structure.scene == null:
			info += "  -- MISSING MESH ITEM '%s'" % structure.item_name
		if info != _last_info_text:
			_last_info_text = info
			build_info_label.text = info

# --- Unlocks -------------------------------------------------------------------

func is_unlocked(structure_index: int) -> bool:
	if structure_index < 0 or structure_index >= structures.size():
		return false
	var requirements: Dictionary = structures[structure_index].unlock_requirements
	for key in requirements.keys():
		if map.lifetime_gathered.get(key, 0) < requirements[key]:
			return false
	return true

func _unlock_text(structure: Structure) -> String:
	var needs: Array[String] = []
	for key in structure.unlock_requirements.keys():
		var have: int = map.lifetime_gathered.get(key, 0)
		needs.append("%s %d/%d" % [String(key), have, structure.unlock_requirements[key]])
	return ", ".join(needs)

# --- Jobs & housing (called by PolicyEngine) -----------------------------------

func get_citizen_by_id(citizen_id: String) -> Node:
	for c in citizens:
		if is_instance_valid(c) and c.data != null and c.data.id == citizen_id:
			return c
	return null

# Takes a citizen off every workplace payroll and clears their job.
func release_job(citizen_id: String) -> void:
	for instance in buildings.values():
		instance.workers.erase(citizen_id)
	var c = get_citizen_by_id(citizen_id)
	if c != null:
		c.clear_job()

# Moves a citizen out of every house.
func release_housing(citizen_id: String) -> void:
	for instance in buildings.values():
		instance.residents.erase(citizen_id)

# A building was demolished: its workers lose their job (residents re-derive their housing
# status on their own, see Citizen._refresh_housing_status).
func _vacate_building(id: String) -> void:
	if not buildings.has(id):
		return
	var instance: BuildingInstance = buildings[id]
	for worker_id in instance.workers.duplicate():
		var c = get_citizen_by_id(worker_id)
		if c != null:
			c.clear_job()
	instance.workers.clear()
	instance.residents.clear()

func _flash_build_hint(text: String) -> void:
	if build_hint_label != null:
		build_hint_label.text = text
		build_hint_label.visible = true
		build_hint_timer = BUILD_HINT_DURATION

# --- Save / load -------------------------------------------------------------

func action_save():
	if Input.is_action_just_pressed("save") and not Globals.online_client:
		print("Saving map...")

		map.structures.clear()
		for id in placed_structures.keys():
			var entry = placed_structures[id]
			if entry.has("node"):
				continue # free-standing objects (trees) aren't saved yet
			var data_structure := DataStructure.new()
			data_structure.position = entry["position"]
			data_structure.rotation_y = entry["rotation_y"]
			data_structure.structure = entry["structure_index"]

			map.structures.append(data_structure)

		ResourceSaver.save(map, "user://map.res")

		print("Map saved.")

func action_load():
	if Input.is_action_just_pressed("load") and not Globals.online_client:
		print("Loading map...")

		_load_from(ResourceLoader.load("user://map.res"))

		print("Map loaded.")

func _load_from(loaded_map: DataMap) -> void:
	_clear_all_placed_structures()

	map = loaded_map
	if not map:
		map = DataMap.new()

	for data_structure in map.structures:
		_place_structure(data_structure.structure, world_to_cell(data_structure.position), data_structure.rotation_y)

func _clear_all_placed_structures() -> void:
	for id in placed_structures.keys().duplicate():
		if placed_structures[id].has("node"):
			continue # trees stay where they are
		remove_structure_instance(id)

func spawn_citizens(count: int):
	for i in count:
		var c = citizen_scene.instantiate()
		_citizen_counter += 1
		c.name = "Citizen_%d" % _citizen_counter # the MultiplayerSpawner replicates this exact name to clients
		add_child(c)
		# Spawn around player
		c.global_position = Globals.get_player_position() + Vector3(randi_range(-10, 10), 0, randi_range(-10, 10))
		citizens.append(c)

# --- Resource gathering ----------------------------------

# Finds the nearest gatherable structure (e.g. a tree) to a world position. `resource_type`
# (e.g. "wood") limits the search to that resource; empty = anything gatherable.
func get_nearest_gatherable(pos: Vector3, resource_type: String = "") -> String:
	var nearest_id := NO_ID
	var nearest_dist := INF

	for id in placed_structures.keys():
		var entry = placed_structures[id]
		var structure_index: int = entry["structure_index"]
		if structure_index < 0 or structure_index >= structures.size():
			continue
		if not structures[structure_index].gatherable:
			continue
		if resource_type != "" and structures[structure_index].resource_type != resource_type:
			continue

		var dist = pos.distance_squared_to(entry["position"])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id

	return nearest_id

# Removes a fully-gathered structure (per design: chopping is permanent,
# player must replant). Its cell turns back into ground.
func gather_resource_at(id: String) -> void:
	if not placed_structures.has(id):
		return
	var structure_index: int = placed_structures[id]["structure_index"]
	if structure_index < 0 or structure_index >= structures.size():
		return
	if not structures[structure_index].gatherable:
		return

	clear_chop_progress(id)
	remove_structure_instance(id)
	_net("remove", [id])

func deposit_resources(resources: Dictionary) -> void:
	if resources.is_empty():
		return
	for key in resources.keys():
		map.stockpile[key] = map.stockpile.get(key, 0) + resources[key]
		map.lifetime_gathered[key] = map.lifetime_gathered.get(key, 0) + resources[key]

# Pulls the mesh (and its transform inside the scene) out of the PackedScene assigned for a resource type
func _get_prop_visual(resource_type: String) -> Dictionary:
	if _prop_visuals.has(resource_type):
		return _prop_visuals[resource_type]
	var result := {}
	var scene: PackedScene = resource_prop_meshes.get(resource_type)
	if scene != null:
		var root := scene.instantiate()
		var mi: MeshInstance3D = root as MeshInstance3D
		if mi == null:
			var found := root.find_children("*", "MeshInstance3D", true, false)
			if not found.is_empty():
				mi = found[0]
		if mi != null and mi.mesh != null:
			var xform := mi.transform
			var p := mi.get_parent()
			while p is Node3D and p != root:
				xform = (p as Node3D).transform * xform
				p = p.get_parent()
			result = {"mesh": mi.mesh, "xform": xform}
		else:
			push_warning("Builder: resource_prop_meshes[%s] has no MeshInstance3D -- using the placeholder sphere." % resource_type)
		root.free()
	_prop_visuals[resource_type] = result
	return result

func spawn_resource_prop(world_pos: Vector3, resource_type: String, amount: int = 1) -> void:
	if resource_type == "" or amount <= 0:
		return
	_prop_counter += 1
	var pos := world_pos + Vector3(randf_range(-0.4, 0.4), RESOURCE_SPAWN_HEIGHT, randf_range(-0.4, 0.4))
	var rot := Vector3(randf_range(0, TAU), randf_range(0, TAU), randf_range(0, TAU))
	var prop_name := "Prop_%d" % _prop_counter
	_create_prop(prop_name, resource_type, amount, pos, rot, false)
	_net("prop_spawn", [prop_name, resource_type, amount, pos, rot])

# Builds one log / fruit. `puppet` = a client's copy of a prop the server simulates: it is moved by the server's
# updates and only reports shoves (see resource_prop.gd).
func _create_prop(prop_name: String, resource_type: String, amount: int, pos: Vector3, rot: Vector3, puppet: bool) -> void:
	if get_node_or_null(NodePath(prop_name)) != null:
		return # already there (a late joiner's catch-up can repeat an event)
	var prop := ResourceProp.new() # a RigidBody3D that already carries resource_prop.gd
	prop.name = prop_name
	prop.is_puppet = puppet
	prop.mass = RESOURCE_PROP_MASS

	var mesh_instance := MeshInstance3D.new()
	var collider := CollisionShape3D.new()
	var visual := _get_prop_visual(resource_type)
	var mesh: Mesh = visual.get("mesh")
	if mesh != null:
		mesh_instance.mesh = mesh
		mesh_instance.transform = visual["xform"]
		if not _prop_shapes.has(resource_type):
			_prop_shapes[resource_type] = mesh.create_convex_shape(true, true)
		collider.shape = _prop_shapes[resource_type]
		collider.transform = visual["xform"]
	else:
		var sphere := SphereMesh.new()
		sphere.radius = 0.15
		sphere.height = 0.3
		mesh_instance.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.25, 0.2) if resource_type == "food" else Color(0.7, 0.7, 0.7)
		mesh_instance.set_surface_override_material(0, mat)
		var box := BoxShape3D.new()
		box.size = Vector3(0.3, 0.3, 0.3)
		collider.shape = box
	prop.add_child(mesh_instance)
	prop.add_child(collider)

	prop.add_to_group("resource_prop")
	prop.set_meta("resource_type", resource_type)
	prop.set_meta("amount", amount)
	prop.set_meta("builder", self)

	add_child(prop)
	prop.global_position = pos
	prop.rotation = rot

# --- Construction pipeline ------------------------------------------
# A site shows the construction item in its cell until builders finish it, then the cell becomes
# the real structure's item.

func _start_construction(cell: Vector3i, rotation_y: float, structure_index: int) -> void:
	var site := ConstructionSite.new()
	site.id = "c_%d_%d_%d" % [cell.x, cell.y, cell.z] # from the cell, so clients agree with the server
	site.position = cell_to_world(cell)
	site.rotation_y = rotation_y
	site.structure_index = structure_index
	construction_sites[site.id] = site
	_site_cells[cell] = site.id

	var prev_item := GridMap.INVALID_CELL_ITEM
	var prev_orientation := 0
	var ground_cell := Vector3i(cell.x, cell.y - 1, cell.z) # the ground tile this structure will stand on
	if ground != null:
		prev_item = ground.get_cell_item(ground_cell)
		prev_orientation = ground.get_cell_item_orientation(ground_cell)
		if _construction_item != GridMap.INVALID_CELL_ITEM:
			ground.set_cell_item(ground_cell, _construction_item, _orientation_for(rotation_y))

	var bar: ProgressIndicator3D = progress_indicator_scene.instantiate()
	add_child(bar)
	bar.position = site.position + Vector3(0, GHOST_BAR_HEIGHT, 0)
	bar.bar_color = Color(0.6, 0.6, 0.65)
	bar.set_progress(0.0)

	construction_visuals[site.id] = {"bar": bar, "cell": cell, "ground_cell": ground_cell, "prev_item": prev_item, "prev_orientation": prev_orientation}

func _process_construction(delta: float) -> void:
	if Globals.online_client:
		return # the server runs construction; progress arrives as "site_state" (see world_sync.gd)
	if construction_sites.is_empty():
		return

	var completed_ids: Array[String] = []

	for id in construction_sites.keys():
		var site: ConstructionSite = construction_sites[id]
		var structure := structures[site.structure_index]

		_commit_resources(site, structure)

		var fully_committed := _resources_fully_committed(site, structure)
		if construction_visuals.has(id):
			var bar: ProgressIndicator3D = construction_visuals[id]["bar"]
			if fully_committed:
				bar.set_bar_color(Color(0.6, 0.6, 0.65)) # neutral grey-blue -- resourced
			else:
				bar.set_bar_color(Color(0.85, 0.35, 0.25)) # stalled -- missing resources

		if not fully_committed:
			continue # waiting on the stockpile -- builders stand by, no progress yet

		if site.assigned_builders.is_empty():
			continue # no labor assigned yet -- nothing progresses on its own

		var builders_in_range := _count_builders_in_range(site)
		if builders_in_range <= 0:
			continue # assigned, but nobody has physically arrived yet

		var labor := float(builders_in_range) * delta
		site.progress = clamp(site.progress + labor / max(structure.build_time, 0.01), 0.0, 1.0)

		if construction_visuals.has(id):
			construction_visuals[id]["bar"].set_progress(site.progress)

		if site.is_complete():
			completed_ids.append(id)

	for id in completed_ids:
		_complete_construction(id)

const BUILD_LABOR_REACH := 1.5 # how close a citizen builder must stand to contribute labor
const PLAYER_WORK_REACH := 2.0 # how far (flat) from the player a tree / construction site may be to gather or build it
const PLAYER_BUILDER_ID := "player_builder" # id the player registers under in ConstructionSite.assigned_builders (can't collide with 6-digit citizen ids)

func _count_builders_in_range(site: ConstructionSite) -> int:
	var count := 0
	for builder_id in site.assigned_builders:
		var node: Node3D = null
		if builder_id == PLAYER_BUILDER_ID:
			node = Globals.player
		elif builder_id.begins_with("player_") and Globals.network != null:
			# online: "player_<peer id>" is that client's avatar on the server
			node = Globals.network.net_players.get_node_or_null(builder_id.trim_prefix("player_")) as Node3D
		else:
			for c in citizens:
				if is_instance_valid(c) and c.data != null and c.data.id == builder_id:
					node = c
					break
		if node == null or not is_instance_valid(node):
			continue
		var reach := PLAYER_WORK_REACH if builder_id.begins_with("player_") else BUILD_LABOR_REACH
		if flat_distance(node.global_position, site.position) <= reach:
			count += 1
	return count

func _commit_resources(site: ConstructionSite, structure: Structure) -> void:
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var already: int = site.resources_committed.get(resource_type, 0)
		if already >= needed:
			continue

		var available: int = map.stockpile.get(resource_type, 0)
		var to_draw: int = min(needed - already, available)
		if to_draw <= 0:
			continue

		map.stockpile[resource_type] = available - to_draw
		site.resources_committed[resource_type] = already + to_draw
		_consume_stacked_logs(resource_type, to_draw)

func _resources_fully_committed(site: ConstructionSite, structure: Structure) -> bool:
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var committed: int = site.resources_committed.get(resource_type, 0)
		if committed < needed:
			return false
	return true

func _complete_construction(id: String) -> void:
	_net("site_complete", [id])
	var site: ConstructionSite = construction_sites[id]
	var visual: Dictionary = construction_visuals.get(id, {})
	var cell: Vector3i = visual.get("cell", world_to_cell(site.position))

	construction_sites.erase(id)
	_site_cells.erase(cell)
	_restore_ground(visual)
	_clear_construction_visual(id)
	_place_structure(site.structure_index, cell, site.rotation_y)

	Audio.play(SFX_PLACE, -20)

# Demolishing a site gives its ground tile back
func _cancel_construction(id: String) -> void:
	clear_demolish(id)
	if not construction_sites.has(id):
		return
	var visual: Dictionary = construction_visuals.get(id, {})
	if visual.has("cell"):
		_site_cells.erase(visual["cell"])
	_restore_ground(visual)
	construction_sites.erase(id)
	_clear_construction_visual(id)

# Puts the ground tile back to what it was before the construction tile replaced it
func _restore_ground(visual: Dictionary) -> void:
	if ground == null or not visual.has("ground_cell"):
		return
	ground.set_cell_item(visual["ground_cell"], visual["prev_item"], visual["prev_orientation"])

# Finds the nearest active construction site to a world position
func get_nearest_construction_site(pos: Vector3) -> String:
	var nearest_id := NO_ID
	var nearest_dist := INF

	for id in construction_sites.keys():
		var dist = pos.distance_squared_to(construction_sites[id].position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id

	return nearest_id

func assign_builder_to_site(citizen_id: String, site_id: String) -> bool:
	if Globals.online_client and citizen_id == PLAYER_BUILDER_ID:
		Globals.world_sync.req_assign_builder(site_id) # the server keeps the list of builders
		return construction_sites.has(site_id)
	if not construction_sites.has(site_id):
		return false
	release_builder(citizen_id)
	var site: ConstructionSite = construction_sites[site_id]
	if not citizen_id in site.assigned_builders:
		site.assigned_builders.append(citizen_id)
	return true

func release_builder(citizen_id: String) -> void:
	if Globals.online_client and citizen_id == PLAYER_BUILDER_ID:
		Globals.world_sync.req_release_builder()
		return
	for site in construction_sites.values():
		site.assigned_builders.erase(citizen_id)

# Called from citizen.gd's _exit_tree() when a citizen is freed: drops them from `citizens`, from
# any site's assigned_builders, from housing and from any workplace payroll.
func release_citizen(citizen_id: String) -> void:
	release_builder(citizen_id)
	release_housing(citizen_id)
	for instance in buildings.values():
		instance.workers.erase(citizen_id)
	for i in range(citizens.size() - 1, -1, -1):
		var c = citizens[i]
		if not is_instance_valid(c) or (c.data != null and c.data.id == citizen_id):
			citizens.remove_at(i)

# --- Construction & gather progress visuals --------------------------------

# Frees a site's progress bar (the cell itself is handled by the caller)
func _clear_construction_visual(id: String) -> void:
	if not construction_visuals.has(id):
		return
	construction_visuals[id]["bar"].queue_free()
	construction_visuals.erase(id)

func update_gather_progress(id: String, progress01: float) -> void:
	if not gather_visuals.has(id):
		var bar: ProgressIndicator3D = progress_indicator_scene.instantiate()
		add_child(bar)
		var pos = get_structure_position(id)
		# Trees differ in height: float the bar at the tree's own anchor (see Gatherable.progress_anchor)
		var node = placed_structures[id].get("node") if placed_structures.has(id) else null
		if node is Gatherable and is_instance_valid(node):
			bar.global_position = node.get_progress_position()
		else:
			bar.global_position = pos + Vector3(0, GATHER_BAR_HEIGHT, 0)
		bar.bar_color = Color(0.8, 0.4, 0.1) # matches citizen HungerBar orange
		gather_visuals[id] = bar
	gather_visuals[id].set_progress(progress01)

func clear_gather_progress(id: String) -> void:
	if not gather_visuals.has(id):
		return
	gather_visuals[id].queue_free()
	gather_visuals.erase(id)

# --- Chop progress (persisted) ---------------------------------------------

func add_chop_progress(id: String, amount: float) -> Dictionary:
	if Globals.online_client:
		# The server does the chopping: send it what we put in; the result (tree gone, energy bonus) comes back
		if placed_structures.has(id):
			Globals.world_sync.client_chop(id, amount)
		return {"completed": false, "energy_bonus": 0.0}
	if not placed_structures.has(id):
		return {"completed": false, "energy_bonus": 0.0}
	var structure_index: int = placed_structures[id]["structure_index"]
	if structure_index < 0 or structure_index >= structures.size():
		return {"completed": false, "energy_bonus": 0.0}
	var structure = structures[structure_index]
	if not structure.gatherable:
		return {"completed": false, "energy_bonus": 0.0}

	var previous_progress: float = gather_progress.get(id, 0.0)
	var progress = clamp(previous_progress + amount, 0.0, 1.0)
	gather_progress[id] = progress
	update_gather_progress(id, progress)
	if Globals.hosting_world and Globals.world_sync != null:
		Globals.world_sync.server_chop_progress(id, progress)

	_spawn_incremental_resource_props(id, structure, previous_progress, progress)

	if progress >= 1.0:
		var energy_bonus := 0.0
		if randf() < structure.food_chance:
			energy_bonus = structure.food_energy_bonus
		gather_resource_at(id)
		return {"completed": true, "energy_bonus": energy_bonus}
	return {"completed": false, "energy_bonus": 0.0}

func _spawn_incremental_resource_props(id: String, structure: Structure, prev_progress: float, new_progress: float) -> void:
	if structure.resource_type == "" or structure.resource_yield <= 0:
		return
	var world_pos = get_structure_position(id)
	var prev_units = floori(prev_progress * structure.resource_yield)
	var new_units = floori(new_progress * structure.resource_yield)
	for i in range(new_units - prev_units):
		spawn_resource_prop(world_pos, structure.resource_type, 1)

func clear_chop_progress(id: String) -> void:
	gather_progress.erase(id)
	clear_gather_progress(id)

# Distance-gates every active progress bar against the player each frame
func _update_progress_bar_visibility() -> void:
	if not Globals.player:
		return
	var player_pos = Globals.player.global_position

	for visual in construction_visuals.values():
		var bar: ProgressIndicator3D = visual["bar"]
		var in_range = bar.global_position.distance_to(player_pos) < PROGRESS_BAR_VISIBLE_DISTANCE
		bar.set_visible_in_range(in_range)

	for bar in gather_visuals.values():
		var in_range = bar.global_position.distance_to(player_pos) < PROGRESS_BAR_VISIBLE_DISTANCE
		bar.set_visible_in_range(in_range)
