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

@export_category("Citizens")
@export var starting_citizens := 5

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
@export var stockpile_position := Vector3.ZERO
## Size of the stockpile in grid cells (2 = a 2x2 block). Those cells can't be built on, and a settled log counts
## once it is inside the block. The yellow marker (StockpileMarker in main.tscn) should be a flat box this big.
@export var stockpile_size_cells := 2

@export_group("HUD nodes")
@export var build_info_label: Label # what's selected while in build mode
@export var build_hint_label: Label # transient warnings (e.g. "not enough wood")
@export var stockpile_marker: Node3D # flat disc marking where logs must be pushed
@export var stockpile_sign: StockpileSign # wooden board at the disc's edge that says "STOCKPILE" and shows the count
@export var popup_scene: PackedScene # the floating "+1 Wood" (pickup_popup.tscn), shown where a log is collected
@export var cursor_sprite: Sprite3D # tile outline on the build cursor (Selector/Sprite): green = can build here, red = can't
@export var demolish_ring_scene: PackedScene # the circular timer over a building being taken apart (demolish_ring_3d.tscn)
@export_group("Stockpile stacking")
## A log pushed into the log stockpile tidies itself onto a neat triangular woodpile inside the yellow area.
@export var stack_columns := 4 # logs side by side along x in one layer
@export var stack_rows := 2 # rows along z in the bottom layer; each layer above has one row fewer (never fewer than 1)
@export var stack_spacing := Vector3(1.5, 0.6, 0.7) # metres between logs (x), layers (y) and rows (z)
@export var stack_rotation_degrees := Vector3(0, 90, 0) # how a log lies on the pile: change this if yours points the wrong way
@export_group("Food")
## The food stockpile: a second block of grid cells that holds only fruit. Like the log stockpile it can't be built on.
## Left at (0, 0, 0) it is placed a few cells beside the log stockpile. FoodStockpileMarker in main.tscn should be a flat box this big.
@export var food_stockpile_position := Vector3.ZERO
@export var food_stockpile_size_cells := 2
@export var food_stockpile_marker: Node3D
@export var food_stockpile_sign: StockpileSign # green "FOOD STORE" board at the food area's edge (food_stockpile_sign.tscn); bounces when fruit is stored
## Heavy resource types that are only pushed around (logs). Anything else (fruit) is small enough to grab with E and carry.
@export var stacked_resource_types: Array[String] = ["wood"]
## Resource types that tidy themselves onto a pile inside their stockpile (logs: triangular woodpile, fruit: pyramid).
## Nothing on a pile is frozen: it is all physics bodies, so taking or shoving one makes the ones above it tumble.
@export var piled_resource_types: Array[String] = ["wood", "food"]
## The fruit pyramid in the food stockpile: a square base of food_stack_base x food_stack_base fruit, and every layer above
## has one fruit fewer per side, nested in the gaps below (base 4 -> 16 + 9 + 4 + 1 = 30 fruit). Any more just lie there.
@export var food_stack_base := 4
@export var food_stack_spacing := 0.34 # metres between neighbouring fruit; each layer sits spacing * 0.82 higher
## Ready-made prop scene per resource type (RigidBody3D with resource_prop.gd), e.g. "food" -> scenes/fruit_prop.tscn.
## Mass, damping, physics material, collision layers, mesh and collider are all set in that scene, not here.
## A type with no entry falls back to resource_prop_meshes (logs) / a placeholder sphere.
@export var resource_prop_scenes: Dictionary[String, PackedScene] = {}
@export var food_stack_lift := 0.2 # how far above the food stockpile marker the bottom layer's fruit sit
## Energy one unit of food ("food" in the stockpile) restores when eaten.
@export var food_energy := 5.0
## Citizens and the player go and eat from the stockpile once their energy drops below this...
@export var hungry_below := 50.0
## ...and keep eating until their energy reaches this.
@export var eat_until := 85.0
## How far (flat metres) beyond the edge of the stockpile block someone may stand and still eat.
@export var eat_reach := 2.0
@export_group("")

var citizens = []

# id (String) -> {"cell": Vector3i, "structure_index": int, "position": Vector3, "rotation_y": float,
#                 "previous_item": int, "previous_orientation": int}
var placed_structures: Dictionary = {}
var _cell_ids: Dictionary = {} # Vector3i -> id, for every placed structure

var buildings: Dictionary = {} # id (String) -> BuildingInstance, for placed HOUSE/SHOP/WORKPLACE structures

var construction_sites: Dictionary = {} # id (String) -> ConstructionSite, for structures still being built
var _site_cells: Dictionary = {} # Vector3i -> site id
var _stockpile_cells: Dictionary = {} # Vector3i -> true, the cells the stockpile covers (never buildable)
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
const SMALL_PROP_LAYER := 32 # physics layer 6: fruit only (the player and citizens don't collide with it)
const RESOURCE_SPAWN_HEIGHT := 3.0 # props drop from this far above a cell's floor

const GHOST_BAR_HEIGHT := 3.0 # local Y offset above a construction cell's floor
const GATHER_BAR_HEIGHT := 3.0 # local Y offset above a gathered tile's floor
const PROGRESS_BAR_VISIBLE_DISTANCE := 16.0

var gather_visuals: Dictionary = {} # id (String) -> ProgressIndicator3D, for trees actively being chopped
var gather_progress: Dictionary = {} # id (String) -> 0.0-1.0 persisted chop progress
var demolish_progress: Dictionary = {} # id (String) -> 0.0-1.0 how far a structure/site has been taken apart
var demolish_visuals: Dictionary = {} # id (String) -> DemolishRing3D
var _demolish_touched: Dictionary = {} # id (String) -> msec when labour last went into it (progress fades once it stops)
var _count_timer := 0.0 # how long until the live stockpile counts are recomputed
var _piles: Dictionary = {} # resource type -> Array of the props holding a slot on that pile, index = slot (null = a gap)
var _rolled_yields := {} # tree id -> {"primary": int, "secondary": int}: what this particular tree drops (rolled once, server/offline only)

var plane: Plane # Used for raycasting mouse

# Modes: normal movement mode <-> INTERACT mode (Tab: the cursor is out). Inside interact mode you are BUILDING by default;
# Backspace switches to DELETE mode (click-and-hold a building to take it apart, nothing is placed) and B goes back to
# building. Tab leaves interact mode from either.
var interact_mode: bool = false  # true = interact mode (cursor out: building, or deleting when delete_mode is on)
var delete_mode: bool = false # only while interact_mode: clicking a building takes it apart (see Player._try_start_work)

const DELETE_MODE_HINT := "DELETE MODE - click and hold a building to take it apart\n[B] back to building    [Tab] leave interact mode"
const NO_ID := ""
const DEMOLISH_REACH := 2.0 # fallback: how far (flat) from a click a structure/site may be and still be found
const BUILD_RANGE_CELLS := 5 # how many grid cells from the player a structure may be placed
const PICK_RADIUS := 5.0 # how far (flat) a mouse pick may land from a structure/site and still select it
const PICK_RAY_LENGTH := 500.0 # must reach well past the camera's furthest zoom, or clicks on anything far from the camera miss
const GROUND_RAY_TOP := 200.0 # ground-height probes fall from here...
const GROUND_RAY_BOTTOM := -200.0 # ...to here

# UI -- the nodes themselves live in main.tscn (BuilderHUD); this script only fills in their text
var hotbar_page: int = 0  # which page of 10 structure slots the player is on
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
	_snap_stockpile_to_grid()

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
	await get_tree().physics_frame # the ground probes in spawn_citizens need the GridMap collision registered
	if Globals.hosting_world: # online, only the server simulates citizens (clients get puppets, see citizen.gd)
		spawn_citizens(starting_citizens)

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

# The build cursor never leaves BUILD_RANGE_CELLS of the player: a pick further out (the mouse over the horizon, a far
# hill, the ocean) is pulled back along the line to the player, onto the ground at the edge of the range.
func _clamp_to_build_range(point: Vector3) -> Vector3:
	if Globals.player == null or world == null:
		return point
	var reach := BUILD_RANGE_CELLS * world.cell_size.x
	var player_pos: Vector3 = Globals.player.global_position
	var offset := Vector3(point.x - player_pos.x, 0.0, point.z - player_pos.z)
	if offset.length() <= reach:
		return point
	offset = offset.normalized() * reach
	var clamped := Vector3(player_pos.x + offset.x, point.y, player_pos.z + offset.z)
	var ground_y := _ground_height_or_nan(clamped)
	if not is_nan(ground_y):
		clamped.y = ground_y
	return clamped

## The registered free-standing object (tree) under the mouse, or NO_ID. One physics ray against the
## ground AND every object's PickBody: the nearest hit wins, so a hill or a nearer tree correctly
## hides whatever is behind it (no screen buffer needed, the physics ray is the depth test).
## Any collider under a registered object counts, so the trunk or the PickBody both resolve to it.
func pick_object_at(screen_pos: Vector2) -> String:
	if view_camera == null:
		return NO_ID
	var from := view_camera.project_ray_origin(screen_pos)
	var dir := view_camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * PICK_RAY_LENGTH, pick_collision_mask | object_pick_layer | ground_collision_mask)
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
	for pair in [[stockpile_marker, stockpile_position], [food_stockpile_marker, food_stockpile_position]]:
		var marker := pair[0] as Node3D
		var point: Vector3 = pair[1]
		if marker == null:
			continue
		var ground_y := _ground_height_or_nan(point)
		marker.global_position = Vector3(point.x, (0.0 if is_nan(ground_y) else ground_y) + 0.05, point.z)
	print("Log stockpile at (%.1f, %.1f), %dx%d cells; food stockpile at (%.1f, %.1f), %dx%d cells" % [stockpile_position.x, stockpile_position.z, stockpile_size_cells, stockpile_size_cells, food_stockpile_position.x, food_stockpile_position.z, food_stockpile_size_cells, food_stockpile_size_cells])

# Both stockpiles (logs, food) are square blocks of grid cells: snap each centre to its block and remember which cells
# they cover (never buildable)
func _snap_stockpile_to_grid() -> void:
	_stockpile_cells.clear()
	if world == null:
		return
	if food_stockpile_position == Vector3.ZERO:
		food_stockpile_position = stockpile_position + Vector3(world.cell_size.x * (maxi(stockpile_size_cells, 1) + 2), 0.0, 0.0)
	stockpile_position = _snap_block(stockpile_position, stockpile_size_cells)
	food_stockpile_position = _snap_block(food_stockpile_position, food_stockpile_size_cells)

func _snap_block(point: Vector3, size_cells: int) -> Vector3:
	var n := maxi(size_cells, 1)
	# Centre the block ON the assigned point (not grow it down-right from the cell under it): the cell containing
	# (point - half the block's extent beyond one cell) is the block's first cell.
	var origin := world_to_cell(point - Vector3((n - 1) * 0.5 * world.cell_size.x, 0.0, (n - 1) * 0.5 * world.cell_size.z))
	for dx in n:
		for dz in n:
			_stockpile_cells[Vector3i(origin.x + dx, origin.y, origin.z + dz)] = true
	var centre := cell_to_world(origin)
	return Vector3(centre.x + (n - 1) * 0.5 * world.cell_size.x, 0.0, centre.z + (n - 1) * 0.5 * world.cell_size.z)

# True if a world position is over the log stockpile block (wood is counted live from the logs lying in it)
func is_in_stockpile(pos: Vector3) -> bool:
	return _in_block(pos, stockpile_position, stockpile_size_cells)

# True if a world position is over the food stockpile block (food = the fruit lying in it)
func is_in_food_stockpile(pos: Vector3) -> bool:
	return _in_block(pos, food_stockpile_position, food_stockpile_size_cells)

func _in_block(pos: Vector3, centre: Vector3, size_cells: int) -> bool:
	if world == null:
		return false
	var half := maxi(size_cells, 1) * world.cell_size.x * 0.5
	return absf(pos.x - centre.x) <= half and absf(pos.z - centre.z) <= half

func _generate_id() -> String:
	_id_counter += 1
	return "s_%d_%d" % [Time.get_ticks_usec(), _id_counter]

func _process(delta):

	# Controls
	action_interact_mode() # Tab: toggle interact mode (the build cursor)
	action_delete_mode() # Backspace: delete mode (from interact mode)
	action_rotate() # Rotates selection 90 degrees
	action_structure_toggle() # Toggles between structures

	# Only show selector and process building in building mode (interact mode, not deleting). The cursor snaps to the cell
	# the mouse is over.
	if interact_mode and not delete_mode and world != null:
		var picked = pick_world_position(Globals.aim_position())
		if picked != null:
			var world_position: Vector3 = _clamp_to_build_range(picked)
			var cell := world_to_cell(world_position)
			_update_cursor(cell)
			# Free-standing objects (trees) aren't grid-bound: the cursor follows the mouse exactly
			var target := world_position if (not structures.is_empty() and structures[index].scene != null) else cell_to_world(cell)
			selector.global_position = selector.global_position.lerp(target, min(delta * 40, 1.0))
			action_build(cell, world_position)

	_process_construction(delta)
	_decay_demolish(delta)
	_update_progress_bar_visibility()
	_refresh_live_counts(delta)
	_update_hud()

	if delete_mode and build_hint_label != null:
		_flash_build_hint(DELETE_MODE_HINT) # stays up for as long as delete mode lasts
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
func _plant_object(structure: Structure, pos: Vector3, node_name: String = "", yaw: float = -1.0) -> Node3D:
	var node := structure.scene.instantiate() as Node3D
	if node == null:
		return null
	node.set_meta("planted", true) # planted in-game, not hand-placed in the scene: saved by its scene + position (SaveManager)
	if node_name != "":
		node.name = node_name # online: the same name on every copy, so the object gets the same id everywhere
	(objects_root if objects_root != null else self).add_child(node)
	node.global_position = pos
	node.rotation.y = yaw if yaw >= 0.0 else randf() * TAU
	# The node registered itself in _ready(), before it had been moved: refresh its recorded position
	if _object_ids.has(node):
		placed_structures[_object_ids[node]]["position"] = node.global_position
	return node

# What an object leaves behind when it is used up (Gatherable.depleted_scene: a tree's stump), in the same spot
func _leave_depleted_model(node: Node3D) -> void:
	var gatherable := node as Gatherable
	if gatherable == null or gatherable.depleted_scene == null or not node.is_inside_tree():
		return
	var leftover := gatherable.depleted_scene.instantiate() as Node3D
	if leftover == null:
		return
	var parent := node.get_parent()
	parent.add_child(leftover)
	leftover.global_transform = node.global_transform

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
			if not node.has_meta("planted") and node.get_parent() == objects_root and not felled_objects.has(String(node.name)):
				felled_objects.append(String(node.name)) # a hand-placed tree went down: remembered for the save file
			_leave_depleted_model(node)
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

# How close (flat) the player / a citizen must be to gather this object: the same distance its interact_hint
# marker appears at (Gatherable.hint_distance), so "hint showing" and "can chop" always agree.
func get_gather_reach(id: String) -> float:
	if placed_structures.has(id):
		var node = placed_structures[id].get("node")
		if node is Gatherable and is_instance_valid(node):
			return node.hint_distance
	return PLAYER_WORK_REACH

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

		# Too far from the player (BUILD_RANGE_CELLS grid cells)
		if not _within_build_range(world_position):
			_flash_build_hint("Too far away. Build within %d tiles of yourself." % BUILD_RANGE_CELLS)
			return

		# Free-standing objects (trees) are planted at the mouse point, anywhere
		if structures[index].scene != null:
			_build_or_request(index, cell, world_position)
			Audio.play(SFX_PLACE, -20)
			return

		if _cell_ids.has(cell):
			_flash_build_hint("Something is already built there. Demolish it first.")
			return
		if _stockpile_cells.has(cell):
			_flash_build_hint("That's the stockpile.")
			return
		if not _is_land_cell(cell):
			_flash_build_hint("You can only build on land.")
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
	var can_build := is_unlocked(index) and not _cell_ids.has(cell) and not _site_cells.has(cell) and not _stockpile_cells.has(cell) and not _object_in_cell(cell) and _is_land_cell(cell) and _within_build_range(cell_to_world(cell)) \
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

# Where the next prop that reaches a pile goes (server / offline). Wood fills one layer at a time on a triangular woodpile:
# the bottom layer has stack_rows rows and each layer above has one row fewer (never fewer than 1), so with 2 rows the
# top layer's single row nests in the groove between the two below. Fruit fills a square pyramid (see _food_slot_transform).
# A slot left empty (its prop was taken, used up or knocked off) is refilled first. Returns the slot's Transform3D, or null
# when that pile is full (the prop then just lies where it is).
func claim_stack_slot(prop: ResourceProp) -> Variant:
	var resource_type := String(prop.get_meta("resource_type", ""))
	var pile: Array = _piles.get(resource_type, [])
	_prune_pile(pile)
	var slot := pile.find(null)
	var is_new_slot := slot == -1
	if is_new_slot:
		slot = pile.size()
	var slot_transform: Variant = _slot_transform(resource_type, slot)
	if slot_transform == null:
		_piles[resource_type] = pile
		return null
	if is_new_slot:
		pile.append(prop)
	else:
		pile[slot] = prop
	_piles[resource_type] = pile
	return slot_transform

# Where slot `slot` of the pile for this resource type is (null = the pile has no such slot, it is full)
func _slot_transform(resource_type: String, slot: int) -> Variant:
	if resource_type == "food":
		return _food_slot_transform(slot)
	var columns := maxi(stack_columns, 1)
	var base_rows := maxi(stack_rows, 1)
	# One "triangle" = base_rows rows in the bottom layer, one fewer in each layer above, down to a single row.
	var unit_size := 0
	for r in range(base_rows, 0, -1):
		unit_size += columns * r
	@warning_ignore("integer_division")
	var unit := slot / unit_size
	var in_unit := slot % unit_size
	# Finished triangles are followed by a NEW one beside it (along z first, then along x), each built up from its own
	# bottom layer. When the block has no room for another triangle the pile is full.
	var block := maxi(stockpile_size_cells, 1) * (world.cell_size.x if world != null else 2.0)
	var units_z := maxi(floori(block / (base_rows * stack_spacing.z)), 1)
	var units_x := maxi(floori(block / (columns * stack_spacing.x)), 1)
	if unit >= units_z * units_x:
		return null
	var layer := 0
	var in_layer := in_unit
	var rows := base_rows
	while in_layer >= columns * rows:
		in_layer -= columns * rows
		layer += 1
		rows = maxi(base_rows - layer, 1)
	var row := floori(float(in_layer) / columns)
	var column := in_layer % columns
	var local := Vector3(
		(column - (columns - 1) * 0.5) * stack_spacing.x + (floori(float(unit) / units_z) - (units_x - 1) * 0.5) * columns * stack_spacing.x,
		0.25 + layer * stack_spacing.y,
		(row - (rows - 1) * 0.5) * stack_spacing.z + (unit % units_z - (units_z - 1) * 0.5) * base_rows * stack_spacing.z)
	var base_y := stockpile_marker.global_position.y if stockpile_marker != null else stockpile_position.y
	var origin := Vector3(stockpile_position.x, base_y, stockpile_position.z) + local
	var lying := Basis.from_euler(Vector3(deg_to_rad(stack_rotation_degrees.x), deg_to_rad(stack_rotation_degrees.y), deg_to_rad(stack_rotation_degrees.z)))
	return Transform3D(lying, origin)

# The fruit pyramid: a food_stack_base x food_stack_base square of fruit, then one fewer per side on every layer above,
# each fruit resting in the gap between four below it (so it is centred and sits spacing * 0.82 higher).
func _food_slot_transform(slot: int) -> Variant:
	var base := maxi(food_stack_base, 1)
	var unit_size := 0
	for s in range(base, 0, -1):
		unit_size += s * s
	# A finished pyramid is followed by another one beside it, until the block has no room for more.
	var unit := floori(float(slot) / unit_size)
	var footprint := base * food_stack_spacing
	var block := maxi(food_stockpile_size_cells, 1) * (world.cell_size.x if world != null else 2.0)
	var per_side := maxi(floori(block / footprint), 1)
	if unit >= per_side * per_side:
		return null # every pyramid in the block is complete
	var side := base
	var layer := 0
	var in_layer := slot % unit_size
	while side > 0 and in_layer >= side * side:
		in_layer -= side * side
		layer += 1
		side -= 1
	var row := floori(float(in_layer) / side)
	var column := in_layer % side
	var local := Vector3(
		(column - (side - 1) * 0.5) * food_stack_spacing + (unit % per_side - (per_side - 1) * 0.5) * footprint,
		food_stack_lift + layer * food_stack_spacing * 0.82,
		(row - (side - 1) * 0.5) * food_stack_spacing + (floori(float(unit) / per_side) - (per_side - 1) * 0.5) * footprint)
	var base_y := food_stockpile_marker.global_position.y if food_stockpile_marker != null else food_stockpile_position.y
	return Transform3D(Basis.IDENTITY, Vector3(food_stockpile_position.x, base_y, food_stockpile_position.z) + local)

# Forgets slots whose prop is gone, was used up, or stopped being a pile member, so they can be filled again
func _prune_pile(pile: Array) -> void:
	for i in pile.size():
		var prop = pile[i]
		if prop == null:
			continue
		if not is_instance_valid(prop) or prop.collected or not prop.in_pile or is_pile_displaced(prop):
			pile[i] = null
	while not pile.is_empty() and pile.back() == null:
		pile.pop_back()

# True if a prop that holds a slot has been knocked well away from it (a pile that tumbled). Props still flying to their
# slot are not displaced.
func is_pile_displaced(prop: ResourceProp) -> bool:
	if not prop.in_pile or not prop.has_arrived():
		return false
	var resource_type := String(prop.get_meta("resource_type", ""))
	var slot := (_piles.get(resource_type, []) as Array).find(prop)
	if slot == -1:
		return true # holds no slot after all
	var slot_transform: Variant = _slot_transform(resource_type, slot)
	if slot_transform == null:
		return true
	var tolerance := 0.45 * (food_stack_spacing if resource_type == "food" else minf(stack_spacing.y, stack_spacing.z))
	return prop.global_position.distance_to((slot_transform as Transform3D).origin) > tolerance

# Frees a prop's slot on its pile (it was used up, grabbed or knocked off)
func release_stack_slot(prop: ResourceProp) -> void:
	var pile: Array = _piles.get(String(prop.get_meta("resource_type", "")), [])
	var slot := pile.find(prop)
	if slot != -1:
		pile[slot] = null
	while not pile.is_empty() and pile.back() == null:
		pile.pop_back()

func is_piled_type(resource_type: String) -> bool:
	return piled_resource_types.has(resource_type)

# True if a world position is over the stockpile block this resource type piles up in
func is_in_pile_block(resource_type: String, pos: Vector3) -> bool:
	return is_in_food_stockpile(pos) if resource_type == "food" else is_in_stockpile(pos)

# --- Live stockpile contents ---------------------------------------------------
# There is no stored counter. Wood is the logs lying settled in the log stockpile right now, food is the fruit lying
# settled in the food stockpile. map.stockpile is only a short-lived copy of that, refreshed a few times a second.

func _stock_props(resource_type: String) -> Array[ResourceProp]:
	var in_food := resource_type == "food"
	var found: Array[ResourceProp] = []
	for node in get_tree().get_nodes_in_group("resource_prop"):
		var prop := node as ResourceProp
		if prop == null or not prop.is_settled():
			continue
		if String(prop.get_meta("resource_type", "")) != resource_type:
			continue
		var pos := prop.global_position
		if (is_in_food_stockpile(pos) if in_food else is_in_stockpile(pos)):
			found.append(prop)
	return found

func _refresh_live_counts(delta: float) -> void:
	_count_timer -= delta
	if _count_timer > 0.0:
		return
	_count_timer = 0.25
	if not Globals.online_client: # a client's copy comes from the server
		for resource_type in ["wood", "food"]:
			var total := 0
			for prop in _stock_props(resource_type):
				total += int(prop.get_meta("amount", 1))
			map.stockpile[resource_type] = total
	_update_count_signs()

# The boards at the two stockpiles show the counts (on every client, from its copy of map.stockpile)
func _update_count_signs() -> void:
	if stockpile_sign != null:
		stockpile_sign.set_counts("Wood: %d" % int(map.stockpile.get("wood", 0)))
	if food_stockpile_sign != null:
		food_stockpile_sign.set_counts("Food: %d" % int(map.stockpile.get("food", 0)))

# The wood a building draws comes off the log stockpile: real logs, the topmost first, shrink away.
func _consume_stacked_logs(resource_type: String, amount: int) -> void:
	var props := _stock_props(resource_type)
	props.sort_custom(func(a: ResourceProp, b: ResourceProp) -> bool: return a.global_position.y > b.global_position.y)
	var remaining := amount
	for prop in props:
		if remaining <= 0:
			break
		remaining -= int(prop.get_meta("amount", 1))
		release_stack_slot(prop)
		_net("prop_consume", [String(prop.name)])
		prop.consume()

# Client side of "prop_consume"
func consume_prop(prop_name: String) -> void:
	var prop := get_node_or_null(NodePath(prop_name)) as ResourceProp
	if prop != null:
		prop.consume()

# --- Food ---------------------------------------------------------------------
# Fruit is gathered like wood (props from a fruit tree, carried or shoved onto the food stockpile, where it tidies itself
# into a pyramid). Citizens and the player then eat from the fruit lying there (see citizen.gd
# _update_eating and player.gd _update_eating).

func is_stacked_type(resource_type: String) -> bool:
	return stacked_resource_types.has(resource_type)

# A collected prop that does not go on the woodpile (fruit): it shrinks away into the stockpile, on every client too
func absorb_prop(prop: ResourceProp) -> void:
	if food_stockpile_sign != null and DisplayServer.get_name() != "headless":
		food_stockpile_sign.bounce()
	_net("prop_consume", [String(prop.name)])
	prop.consume()

# Eating a fruit straight out of someone's hands (player.gd): it is used up on the spot, on every client too
func eat_held_prop(prop: ResourceProp) -> float:
	_net("prop_consume", [String(prop.name)])
	prop.consume()
	return food_energy

func has_food() -> bool:
	return int(map.stockpile.get("food", 0)) > 0

# True if a world position is close enough to the food stockpile block to eat from it (height ignored)
func is_at_food_store(pos: Vector3) -> bool:
	var half := maxi(food_stockpile_size_cells, 1) * (world.cell_size.x if world != null else 1.0) * 0.5
	return Vector2(pos.x - food_stockpile_position.x, pos.z - food_stockpile_position.z).length() <= half + eat_reach

# Eats one real fruit lying in the food stockpile and returns the energy it restores (0.0 = nothing to eat). The
# server / an offline game only: a client's count is a copy of the server's.
func take_food() -> float:
	if Globals.online_client or not has_food():
		return 0.0
	var fruit := _stock_props("food")
	if fruit.is_empty():
		return 0.0
	fruit.sort_custom(func(a: ResourceProp, b: ResourceProp) -> bool: return a.global_position.y > b.global_position.y)
	var prop := fruit[0] # the topmost one, so the pyramid doesn't cave in underneath it
	map.stockpile["food"] = maxi(int(map.stockpile.get("food", 0)) - int(prop.get_meta("amount", 1)), 0)
	_net("prop_consume", [String(prop.name)])
	prop.consume()
	if popup_scene != null and DisplayServer.get_name() != "headless":
		var popup: PickupPopup = popup_scene.instantiate()
		add_child(popup)
		var base_y := food_stockpile_marker.global_position.y if food_stockpile_marker != null else food_stockpile_position.y
		popup.pop(Vector3(food_stockpile_position.x, base_y + 1.5, food_stockpile_position.z), "-1 Food")
	return food_energy

# Land = the ground map has a tile under the build cell (empty cells are open sea)
func _is_land_cell(cell: Vector3i) -> bool:
	if ground == null:
		return true
	return ground.get_cell_item(Vector3i(cell.x, cell.y - 1, cell.z)) != GridMap.INVALID_CELL_ITEM

# Within BUILD_RANGE_CELLS grid cells (flat) of the player
func _within_build_range(world_position: Vector3) -> bool:
	if Globals.player == null or world == null:
		return true
	return flat_distance(Globals.player.global_position, world_position) <= BUILD_RANGE_CELLS * world.cell_size.x

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
	if _cell_ids.has(cell) or _site_cells.has(cell) or _stockpile_cells.has(cell) or _object_in_cell(cell) or not _is_land_cell(cell):
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
		bar.set_status_text(_site_status_text(construction_sites[id]))

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

# Toggle interact mode (Tab). Leaving it also leaves delete mode.

func action_interact_mode():
	if InputMap.has_action("interact_mode") and Input.is_action_just_pressed("interact_mode"):
		interact_mode = !interact_mode
		_set_delete_mode(false)
		selector.visible = interact_mode
		if Audio:
			Audio.play("sounds/toggle.ogg", -30)

# Backspace, while in interact mode, switches from building to delete mode. B (below) switches back.

func action_delete_mode():
	if interact_mode and not delete_mode and InputMap.has_action("demolish") and Input.is_action_just_pressed("demolish"):
		_set_delete_mode(true)
		if Audio:
			Audio.play("sounds/toggle.ogg", -30)

func _unhandled_key_input(event: InputEvent) -> void:
	if delete_mode and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_B:
		_set_delete_mode(false)
		if Audio:
			Audio.play("sounds/toggle.ogg", -30)
		get_viewport().set_input_as_handled()

func _set_delete_mode(on: bool) -> void:
	if delete_mode == on:
		return
	delete_mode = on
	if selector != null:
		selector.visible = interact_mode and not delete_mode # no placement ghost while deleting
	if not on:
		build_hint_timer = 0.0
		if build_hint_label != null:
			build_hint_label.visible = false

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
	# (No stockpile counters any more: wood and food are whatever is physically lying in the two stockpiles.)
	if build_info_label == null:
		return
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

# --- Save / load support -------------------------------------------------------
# The saving and loading itself lives in SaveManager (scripts/save_manager.gd, a node in main.tscn); these are the
# Builder-side pieces it needs. Everything is saved by NAME (item_name, node name), never by index.

var felled_objects: Array[String] = [] # names of hand-placed trees chopped down this game, so a load can fell them again

func clear_placed_structures() -> void:
	_clear_all_placed_structures()

func _clear_all_placed_structures() -> void:
	for id in placed_structures.keys().duplicate():
		if placed_structures[id].has("node"):
			continue # trees stay where they are
		remove_structure_instance(id)

## The index in `structures` of the building whose MeshLibrary item has this name (-1 if this build no longer has it)
func structure_index_for_name(item_name: String) -> int:
	if item_name == "":
		return -1
	for i in structures.size():
		if structures[i].scene == null and structures[i].item_name == item_name:
			return i
	return -1

func restore_structure(structure_index: int, pos: Vector3, rotation_y: float) -> void:
	_place_structure(structure_index, world_to_cell(pos), rotation_y)

## Re-creates a half-built site with the labour and resources already put into it
func restore_site(structure_index: int, pos: Vector3, rotation_y: float, progress: float, committed: Dictionary) -> void:
	var cell := world_to_cell(pos)
	_start_construction(cell, rotation_y, structure_index)
	var id := "c_%d_%d_%d" % [cell.x, cell.y, cell.z]
	apply_site_state(id, progress, is_site_resourced(id), committed)

## A log / fruit lying where the save says (dropped a hair above the ground; it tidies onto its pile by itself)
func restore_prop(resource_type: String, amount: int, pos: Vector3, rot: Vector3) -> void:
	if resource_type == "":
		return
	_prop_counter += 1
	var prop_name := "Prop_%d" % _prop_counter
	var at := pos + Vector3.UP * 0.05
	_create_prop(prop_name, resource_type, amount, at, rot, false)
	_net("prop_spawn", [prop_name, resource_type, amount, at, rot])

## A tree planted in-game, found again by the scene it was made from
func restore_planted(scene_path: String, pos: Vector3, yaw: float) -> Node3D:
	for structure in structures:
		if structure.scene != null and structure.scene.resource_path == scene_path:
			return _plant_object(structure, pos, "", fposmod(yaw, TAU))
	return null

func restore_citizen(info: Dictionary) -> void:
	var c = citizen_scene.instantiate()
	_citizen_counter += 1
	c.name = "Citizen_%d" % _citizen_counter
	var d := CitizenData.new()
	d.id = String(info.get("id", d.id))
	d.citizen_name = String(info.get("name", d.citizen_name))
	d.age = int(info.get("age", d.age))
	d.energy = float(info.get("energy", d.energy))
	d.job = String(info.get("job", ""))
	d.job_task = int(info.get("job_task", Structure.JobTask.NONE))
	d.workplace_id = String(info.get("workplace_id", ""))
	d.job_satisfaction = float(info.get("job_satisfaction", d.job_satisfaction))
	d.happiness = float(info.get("happiness", d.happiness))
	d.housing_satisfaction = float(info.get("housing_satisfaction", d.housing_satisfaction))
	d.approval = float(info.get("approval", d.approval))
	c.data = d # before add_child: Citizen._ready only makes its own data when there is none
	add_child(c)
	c.global_position = info.get("position", Vector3.ZERO)
	c.health = float(info.get("health", c.health))
	c.energy = float(info.get("body_energy", c.energy))
	citizens.append(c)

func spawn_citizens(count: int):
	for i in count:
		var c = citizen_scene.instantiate()
		_citizen_counter += 1
		c.name = "Citizen_%d" % _citizen_counter # the MultiplayerSpawner replicates this exact name to clients
		add_child(c)
		# Spawn on land, within CITIZEN_SPAWN_RADIUS of where the player spawned
		c.global_position = _citizen_spawn_position()
		citizens.append(c)

const CITIZEN_SPAWN_RADIUS := 20.0 # metres around the player's spawn point
const CITIZEN_SPAWN_TRIES := 40

## A random spot on land within CITIZEN_SPAWN_RADIUS of the player's spawn point (the spawn point itself if none is found).
func _citizen_spawn_position() -> Vector3:
	var origin: Vector3 = Globals.player.get("spawn_point") if Globals.player != null else Globals.get_player_position()
	for i in CITIZEN_SPAWN_TRIES:
		var offset := Vector2.from_angle(randf() * TAU) * sqrt(randf()) * CITIZEN_SPAWN_RADIUS
		var pos := origin + Vector3(offset.x, 0.0, offset.y)
		var ground_y := _ground_height_or_nan(pos)
		if is_nan(ground_y):
			continue # nothing to stand on (open sea)
		if ground != null:
			# a point just under the surface must sit inside a ground tile, otherwise it is not land
			var under := ground.local_to_map(ground.to_local(Vector3(pos.x, ground_y - 0.1, pos.z)))
			if ground.get_cell_item(under) == GridMap.INVALID_CELL_ITEM:
				continue
		return Vector3(pos.x, ground_y + 1.1, pos.z)
	return origin

# --- Resource gathering ----------------------------------

# Finds the nearest gatherable structure (e.g. a tree) to a world position. `resource_type`
# (e.g. "wood") limits the search to that resource; empty = anything gatherable.
# `exclude` maps tree id -> time (s, Time.get_ticks_msec()/1000) until which to skip it (trees a citizen couldn't path to)
func get_nearest_gatherable(pos: Vector3, resource_type: String = "", exclude: Dictionary = {}) -> String:
	var nearest_id := NO_ID
	var nearest_dist := INF
	var now := Time.get_ticks_msec() / 1000.0

	for id in placed_structures.keys():
		if exclude.get(id, 0.0) > now:
			continue
		var entry = placed_structures[id]
		var structure_index: int = entry["structure_index"]
		if structure_index < 0 or structure_index >= structures.size():
			continue
		if not structures[structure_index].gatherable:
			continue
		if resource_type != "" and structures[structure_index].resource_type != resource_type:
			continue
		var candidate = entry.get("node")
		if candidate is Gatherable and is_instance_valid(candidate) and candidate.is_depleted():
			continue # a bare bush has nothing left
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
			# A collider authored in the scene (e.g. the cylinder in log.tscn) wins over a hull computed from the mesh
			var shapes := root.find_children("*", "CollisionShape3D", true, false)
			if not shapes.is_empty() and (shapes[0] as CollisionShape3D).shape != null:
				var cs := shapes[0] as CollisionShape3D
				var shape_xform := cs.transform
				var sp := cs.get_parent()
				while sp is Node3D and sp != root:
					shape_xform = (sp as Node3D).transform * shape_xform
					sp = sp.get_parent()
				result["shape"] = cs.shape
				result["shape_xform"] = shape_xform
		else:
			push_warning("Builder: resource_prop_meshes[%s] has no MeshInstance3D -- using the placeholder sphere." % resource_type)
		root.free()
	_prop_visuals[resource_type] = result
	return result

# Picks one fruit off a bush: it lets go from where it hung and is returned as a loose prop (null if the bush is bare),
# ready for the picker to grab -- the player with E, a citizen's fruit run.
func pick_bush_fruit(bush: Gatherable) -> ResourceProp:
	if bush == null or not is_instance_valid(bush) or bush.structure == null:
		return null
	var spot := bush.take_fruit()
	if spot == Vector3.INF:
		return null
	spawn_resource_prop(spot, bush.structure.secondary_resource_type, 1, true)
	return get_node_or_null(NodePath("Prop_%d" % _prop_counter)) as ResourceProp

# The nearest bush with fruit on it within `max_dist` (a 3D sphere, height counts) of a position, or null
func nearest_pickable_bush(pos: Vector3, max_dist: float) -> Gatherable:
	var best: Gatherable = null
	var best_d := max_dist * max_dist
	for node in get_tree().get_nodes_in_group("gatherable"):
		var bush := node as Gatherable
		if bush == null or not bush.pick_fruit_only or bush.is_depleted():
			continue
		var d := pos.distance_squared_to(bush.global_position)
		if d < best_d:
			best_d = d
			best = bush
	return best

func spawn_resource_prop(world_pos: Vector3, resource_type: String, amount: int = 1, exact := false) -> void:
	if resource_type == "" or amount <= 0:
		return
	_prop_counter += 1
	# exact: appear precisely at world_pos (a fruit letting go of its branch) instead of scattered around it just above the ground
	var pos := world_pos if exact else world_pos + Vector3(randf_range(-0.4, 0.4), RESOURCE_SPAWN_HEIGHT, randf_range(-0.4, 0.4))
	if not exact and stacked_resource_types.has(resource_type):
		# Logs now collide with the trunk they came from: start them in a ring just outside it, not inside it
		var angle := randf() * TAU
		var ring := randf_range(0.9, 1.4)
		pos = world_pos + Vector3(cos(angle) * ring, RESOURCE_SPAWN_HEIGHT, sin(angle) * ring)
	var rot := Vector3(randf_range(0, TAU), randf_range(0, TAU), randf_range(0, TAU))
	var prop_name := "Prop_%d" % _prop_counter
	_create_prop(prop_name, resource_type, amount, pos, rot, false)
	_net("prop_spawn", [prop_name, resource_type, amount, pos, rot])

# Builds one log / fruit. `puppet` = a client's copy of a prop the server simulates: it is moved by the server's
# updates and only reports shoves (see resource_prop.gd).
func _create_prop(prop_name: String, resource_type: String, amount: int, pos: Vector3, rot: Vector3, puppet: bool) -> void:
	if get_node_or_null(NodePath(prop_name)) != null:
		return # already there (a late joiner's catch-up can repeat an event)
	var scene: PackedScene = resource_prop_scenes.get(resource_type)
	if scene != null:
		var scene_prop := scene.instantiate() as ResourceProp
		if scene_prop != null:
			_finish_prop(scene_prop, prop_name, resource_type, amount, pos, rot, puppet)
			return
		push_warning("Builder: resource_prop_scenes[%s] is not a RigidBody3D with resource_prop.gd -- using the fallback." % resource_type)
	var prop := ResourceProp.new() # a RigidBody3D that already carries resource_prop.gd
	prop.mass = RESOURCE_PROP_MASS
	if not stacked_resource_types.has(resource_type):
		# Fallback for a small type with no scene: collides with the ground / logs and other small props, never with people
		prop.collision_layer = SMALL_PROP_LAYER
		prop.collision_mask = 1 | SMALL_PROP_LAYER
	else:
		# Logs also collide with trees and stumps (layer 2, their trunks), so they stop against them instead of sliding
		# through -- and can't get wedged inside a cluster of trunks.
		prop.collision_mask = 1 | 2

	var mesh_instance := MeshInstance3D.new()
	var collider := CollisionShape3D.new()
	var visual := _get_prop_visual(resource_type)
	var mesh: Mesh = visual.get("mesh")
	if mesh != null:
		mesh_instance.mesh = mesh
		mesh_instance.transform = visual["xform"]
		if visual.has("shape"):
			collider.shape = visual["shape"]
			collider.transform = visual["shape_xform"]
		else:
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
		var ball := SphereShape3D.new() # fits the sphere mesh above
		ball.radius = 0.15
		collider.shape = ball
	prop.add_child(mesh_instance)
	prop.add_child(collider)
	_finish_prop(prop, prop_name, resource_type, amount, pos, rot, puppet)

# Names, tags and places a freshly built prop (from a scene or from code) and drops it into the world
func _finish_prop(prop: ResourceProp, prop_name: String, resource_type: String, amount: int, pos: Vector3, rot: Vector3, puppet: bool) -> void:
	prop.name = prop_name
	prop.is_puppet = puppet # must be set before it enters the tree
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
			bar.set_status_text(_site_status_text(site))

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

const BUILD_LABOR_REACH := 2.0 # how close a citizen builder must stand to contribute labor
const PLAYER_WORK_REACH := 8.0 # how far (flat) from the player a tree / construction site may be to gather or build it
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

# Text over a site's bar while it still lacks materials, e.g. "2/5 logs" (committed / needed); "" once fully supplied
func _site_status_text(site: ConstructionSite) -> String:
	var structure := structures[site.structure_index]
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var committed: int = site.resources_committed.get(resource_type, 0)
		if committed < needed:
			var label := "logs" if String(resource_type) == "wood" else String(resource_type)
			return "%d/%d %s" % [committed, needed, label]
	return ""

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

## Height (m) above a construction site's floor that counts as part of the site when working out its on-screen region,
## so aiming at the upper part of a half-built hut still counts.
@export var site_pick_height := 8.0
## Extra pixels around a site's on-screen region in which the crosshair / cursor still counts as over it.
@export var site_pick_padding_px := 24.0

## The on-screen region (viewport pixels) covered by a construction site: the bounding rectangle of its cell, from the floor
## up to site_pick_height, projected through the camera. An empty Rect2 if the site is behind the camera.
func site_screen_rect(site_id: String) -> Rect2:
	if view_camera == null or world == null or not construction_sites.has(site_id):
		return Rect2()
	var centre: Vector3 = construction_sites[site_id].position
	var half := world.cell_size.x * 0.5
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var any := false
	for dx in [-half, half]:
		for dz in [-half, half]:
			for h in [0.0, site_pick_height]:
				var p := centre + Vector3(dx, h, dz)
				if view_camera.is_position_behind(p):
					continue
				var s := view_camera.unproject_position(p)
				min_p = min_p.min(s)
				max_p = max_p.max(s)
				any = true
	if not any:
		return Rect2()
	return Rect2(min_p, max_p - min_p).grow(site_pick_padding_px)

## True while a screen point (the crosshair, or the mouse cursor) is over a construction site's on-screen region
func screen_point_over_site(site_id: String, screen_pos: Vector2) -> bool:
	var rect := site_screen_rect(site_id)
	return rect.has_area() and rect.has_point(screen_pos)

## The construction site whose on-screen region contains screen_pos and whose cell is within `reach` (flat) of `from_pos`;
## the nearest to the camera if several overlap. NO_ID if none. Replaces a physics ray + ground-point match for sites.
func pick_site_in_screen(screen_pos: Vector2, from_pos: Vector3, reach: float) -> String:
	if view_camera == null:
		return NO_ID
	var best := NO_ID
	var best_dist := INF
	for id in construction_sites.keys():
		var site_pos: Vector3 = construction_sites[id].position
		if flat_distance(site_pos, from_pos) > reach:
			continue
		if not screen_point_over_site(id, screen_pos):
			continue
		var d := view_camera.global_position.distance_to(site_pos)
		if d < best_dist:
			best_dist = d
			best = id
	return best

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
		bar.bar_color = Color(1.0, 0.8, 0.3, 1.0)
		gather_visuals[id] = bar
	gather_visuals[id].set_progress(progress01)
	# A tree with fruit hanging on it lets go of one per share of progress (see Gatherable.fruit_container)
	var fruit_tree = placed_structures[id].get("node") if placed_structures.has(id) else null
	if fruit_tree is Gatherable and is_instance_valid(fruit_tree):
		fruit_tree.update_fruit_visibility(progress01)

func clear_gather_progress(id: String) -> void:
	if not gather_visuals.has(id):
		return
	gather_visuals[id].queue_free()
	gather_visuals.erase(id)

# --- Chop progress (persisted) ---------------------------------------------

func add_chop_progress(id: String, amount: float, picking := false) -> Dictionary:
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

	# A bush isn't chopped by citizens: each full gather_time of work (picking = true) picks ONE fruit, no progress bar, and the
	# bush stays. The player (picking = false) chops it down like a tree.
	var bush = placed_structures[id].get("node")
	if picking and bush is Gatherable and is_instance_valid(bush) and bush.pick_fruit_only:
		var picked: float = gather_progress.get(id, 0.0) + amount
		if picked < 1.0:
			gather_progress[id] = picked
			return {"completed": false, "energy_bonus": 0.0}
		gather_progress.erase(id)
		pick_bush_fruit(bush)
		return {"completed": true, "energy_bonus": 0.0}

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

# What one tree drops, rolled the first time it is chopped and kept until it is gone (a fruit tree: 1-2 logs and a few fruit)
func _get_rolled_yields(id: String, structure: Structure) -> Dictionary:
	if not _rolled_yields.has(id):
		_rolled_yields[id] = {"primary": structure.roll_yield(), "secondary": structure.roll_secondary_yield()}
	return _rolled_yields[id]

func _spawn_incremental_resource_props(id: String, structure: Structure, prev_progress: float, new_progress: float) -> void:
	var world_pos = get_structure_position(id)
	# Fruit hanging on the tree drops from where it hung instead of new fruit appearing below it
	var tree = placed_structures[id].get("node") if placed_structures.has(id) else null
	var hanging := 0
	if tree is Gatherable and is_instance_valid(tree):
		hanging = tree.get_fruit_count()
	if hanging > 0 and structure.secondary_resource_type != "":
		for i in range(floori(prev_progress * hanging), floori(new_progress * hanging)):
			if tree.is_fruit_picked(i):
				continue # already picked by hand
			spawn_resource_prop(tree.get_fruit_position(i), structure.secondary_resource_type, 1, true)
		_spawn_units_between(world_pos, structure.resource_type, _get_rolled_yields(id, structure)["primary"], prev_progress, new_progress)
		return
	var yields := _get_rolled_yields(id, structure)
	_spawn_units_between(world_pos, structure.resource_type, yields["primary"], prev_progress, new_progress)
	_spawn_units_between(world_pos, structure.secondary_resource_type, yields["secondary"], prev_progress, new_progress)

# One prop per whole unit of `total` that the chop progress passes on its way from prev to new
func _spawn_units_between(world_pos: Vector3, resource_type: String, total: int, prev_progress: float, new_progress: float) -> void:
	if resource_type == "" or total <= 0:
		return
	var prev_units := floori(prev_progress * total)
	var new_units := floori(new_progress * total)
	for i in range(new_units - prev_units):
		spawn_resource_prop(world_pos, resource_type, 1)

func clear_chop_progress(id: String) -> void:
	gather_progress.erase(id)
	_rolled_yields.erase(id)
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
