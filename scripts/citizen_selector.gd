extends Node3D
class_name CitizenSelector

## Click a citizen to see their full stats in a panel and select them for assignment
## With a citizen selected, click another object to assign them there manually

@export var view_camera: Camera3D
@export var max_select_distance: float = 100.0
@export var panel_offset: Vector2 = Vector2(40, -60)  # offset from citizen's screen pos to panel's top-left
@export var click_assist_pixels: float = 40.0 # if the raycast misses, select the nearest citizen/player within this many screen pixels of the click instead -- citizens are small, constantly-moving targets

var selected_citizen: Node3D = null
var builder: Node = null

## UI + ring are real nodes in main.tscn (CitizenSelector/UI/Panel/..., CitizenSelector/Ring):
## restyle and move them in the 2D/3D editor. This script only fills in the text and numbers.
@export_group("Nodes")
@export var panel: PanelContainer
@export var name_label: Label
@export var id_label: Label
@export var stats_label: RichTextLabel
@export var bars_box: VBoxContainer ## one row per stat, each named after its stat ("Happiness", "Health", "Energy") with children Name / Bar / Value
@export var hostile_label: Label
@export var assign_hint_label: Label
@export var ring: MeshInstance3D
@export var outline_material: Material ## yellow overlay drawn on trees and loose logs while a citizen is selected (assignable targets)
const OUTLINE_REFRESH_INTERVAL := 0.15 # logs spawn, trees fall and the player walks (what is in reach changes) while a citizen is selected
var _outlined: Array[MeshInstance3D] = []
var _outline_timer := 0.0
var _hovered: Node3D = null # citizen under the mouse and within the player's reach: gets the outline as a "you can select me" hint
var _hover_meshes: Array[MeshInstance3D] = []

var _plate_hover: Node3D = null # citizen under the mouse at any distance: the only one (besides the selected) with a nameplate

func _ready() -> void:
	add_to_group("citizen_selector")
	panel.visible = false
	ring.visible = false
	hostile_label.visible = false
	assign_hint_label.visible = false
	# Try to auto-find the camera if not assigned, so this works even if you
	# forget to wire it up in the Inspector.
	if view_camera == null:
		var view_node = get_tree().get_first_node_in_group("view")
		if view_node and view_node.has_node("Camera"):
			view_camera = view_node.get_node("Camera")
	
	builder = Globals.builder

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Building mode owns left-click for placement/demolition (the "build"
		# input action is also bound to it) -- don't also try to select/assign
		# citizens while placing structures.
		if builder != null and builder.interact_mode:
			return
		_try_select_at(Globals.aim_position())

func _try_select_at(screen_pos: Vector2) -> void:
	if view_camera == null:
		return
	
	var space_state = get_world_3d().direct_space_state
	var from = view_camera.project_ray_origin(screen_pos)
	var to = from + view_camera.project_ray_normal(screen_pos) * max_select_distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	var result = space_state.intersect_ray(query)
	
	# A citizen under the click: the nearest thing the ray hits wins, so a tree or log standing in front of a citizen
	# blocks the click, and a citizen beyond the player's work reach can't be picked at all.
	var picked := _citizen_under_mouse()
	if picked != null:
		if selected_citizen == picked:
			_deselect()
		else:
			_select(picked)
		get_viewport().set_input_as_handled()
		return
	
	
	# Not a citizen/player -- if we have a CITIZEN selected (not the player --
	# the player isn't assignable to anything), see if the click landed on a
	# building/tree/site cell. This is the manual assignment path (A.3).
	if selected_citizen and is_instance_valid(selected_citizen) and result and result.has("position"):
		# A loose log: put the citizen on hauling duty (they push it, and every other loose log, to the stockpile)
		if result.collider.is_in_group("resource_prop") and not result.collider.collected:
			var hauling := _execute(Action.new_assign_haul(), String(result.collider.name))
			_flash_assign_hint(hauling)
			_after_assign(hauling)
			get_viewport().set_input_as_handled()
			return
		if _try_assign_at_world_position(result.position):
			get_viewport().set_input_as_handled()
			return
	
	_deselect()

## Nearest citizen/player to a screen position within click_assist_pixels, or null.
## Citizens behind the camera are skipped (unproject_position is meaningless there).
func _find_nearest_on_screen(screen_pos: Vector2) -> Node3D:
	if view_camera == null:
		return null
	
	var candidates: Array = get_tree().get_nodes_in_group("citizen")
	
	var best: Node3D = null
	var best_dist := click_assist_pixels
	
	for c in candidates:
		if not is_instance_valid(c):
			continue
		var to_c = c.global_position - view_camera.global_position
		if view_camera.global_transform.basis.z.dot(to_c) > 0:
			continue # behind the camera
		var screen = view_camera.unproject_position(c.global_position)
		var dist = screen.distance_to(screen_pos)
		if dist < best_dist:
			best_dist = dist
			best = c
	
	return best

## Runs an assignment. Online the citizen lives on the server, so ask it to do this and show its answer when it
## arrives (WorldSync.assign_result); the ids are the same on every copy of the world.
func _execute(action: Action, target) -> bool:
	if not Globals.online_client:
		return PolicyEngine.execute(action, selected_citizen, target)
	var world_sync = Globals.world_sync
	if not world_sync.assign_result.is_connected(_on_assign_result):
		world_sync.assign_result.connect(_on_assign_result)
	var target_id: String = target.id if target is BuildingInstance else str(target)
	world_sync.req_assign(action.kind, selected_citizen.data.id, target_id)
	return true # optimistic; the server's real answer follows

func _on_assign_result(ok: bool, reason: String) -> void:
	_flash_assign_hint(ok, reason)
	if ok:
		_deselect() # online: the server accepted the task
	else:
		_refresh_panel()

## A task was handed out: the citizen is done being selected. A refusal keeps them selected (the panel shows why).
## Online the answer comes later (_on_assign_result), so it decides there.
func _after_assign(ok: bool) -> void:
	if not ok:
		_refresh_panel()
	elif not Globals.online_client:
		_deselect()

## Resolves a world-space hit position to a placed structure or construction site id
func _try_assign_at_world_position(world_pos: Vector3) -> bool:
	if builder == null:
		return false
	
	var assigned := false
	# Construction site: assign selected citizen as a builder
	var site_id = builder.get_nearest_construction_site(world_pos)
	if site_id != builder.NO_ID and Builder.flat_distance(builder.construction_sites[site_id].position, world_pos) <= Builder.PICK_RADIUS:
		assigned = _execute(Action.new_assign_build_task(), site_id)
		_flash_assign_hint(assigned)
		_after_assign(assigned)
		return true
	
	# Gatherable structure (tree): assign selected citizen to gather it
	var id = builder.get_structure_at_point(world_pos, Builder.PICK_RADIUS)
	if id != builder.NO_ID:
		var structure_index = builder.get_structure_index(id)
		if structure_index >= 0 and structure_index < builder.structures.size() and builder.structures[structure_index].gatherable:
			assigned = _execute(Action.new_assign_gather(), id)
			_flash_assign_hint(assigned)
			_after_assign(assigned)
			return true
	
	# Building (house/workplace): assign housing or job.
	if id == builder.NO_ID or not builder.buildings.has(id):
		return false
	
	var instance: BuildingInstance = builder.buildings[id]
	var structure: Structure = builder.structures[instance.structure_index]
	
	assigned = false
	if structure.type == Structure.Type.HOUSE or structure.type == Structure.Type.SHOP:
		assigned = _execute(Action.new_assign_housing(), instance)
	elif structure.type == Structure.Type.WORKPLACE:
		assigned = _execute(Action.new_assign_job(), instance)
	else:
		return false
	
	_flash_assign_hint(assigned)
	_after_assign(assigned)
	return true

## `reason` is why the Policy Engine refused (offline: read straight from it; online: sent back by the server)
func _flash_assign_hint(success: bool, reason: String = PolicyEngine.last_failure) -> void:
	assign_hint_label.visible = true
	if success:
		assign_hint_label.text = "Assigned!"
		assign_hint_label.modulate = Color(0.45, 0.9, 0.45)
	else:
		assign_hint_label.text = reason if reason != "" else "No free slot there."
		assign_hint_label.modulate = Color(1.0, 0.25, 0.25)

func _select(citizen: Node3D) -> void:
	_set_hover(null) # the outline goes away on click; from here on it marks assignable targets instead
	_hide_selected_plate()
	selected_citizen = citizen
	_set_plate(citizen, true) # the selected citizen keeps their nameplate even when the mouse moves away
	panel.visible = true
	ring.visible = true
	assign_hint_label.visible = false
	_refresh_panel()
	_refresh_outlines()

func _hide_selected_plate() -> void:
	if selected_citizen != null and is_instance_valid(selected_citizen) and selected_citizen != _plate_hover:
		_set_plate(selected_citizen, false)

func _deselect() -> void:
	_hide_selected_plate()
	selected_citizen = null
	panel.visible = false
	ring.visible = false
	_refresh_outlines()

## The citizen under the mouse: whatever the physics ray hits first. If that is a citizen it is picked; if it is a tree,
## log or building it blocks the click. The on-screen click assist (a moving citizen is easy to miss by a few pixels)
## only applies when the ray hit nothing, or hit something farther away than that citizen. Citizens outside the
## player's work reach (the same range as chopping a tree) can't be picked.
func _citizen_under_mouse(limit_reach := true) -> Node3D:
	if view_camera == null:
		return null
	var screen_pos := Globals.aim_position()
	var from := view_camera.project_ray_origin(screen_pos)
	var to := from + view_camera.project_ray_normal(screen_pos) * max_select_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_distance := INF
	if result:
		if result.collider and result.collider.is_in_group("citizen"):
			return result.collider if (not limit_reach or _in_work_reach(result.collider)) else null
		hit_distance = from.distance_to(result.position)
	var assist := _find_nearest_on_screen(screen_pos)
	if assist != null and assist.is_in_group("citizen") and from.distance_to(assist.global_position) < hit_distance \
			and (not limit_reach or _in_work_reach(assist)):
		return assist
	return null

func _in_work_reach(citizen: Node3D) -> bool:
	var player := Globals.player
	return player == null or Builder.flat_distance(citizen.global_position, player.global_position) <= Builder.PLAYER_WORK_REACH

## A citizen's floating nameplate (name and bars) shows only while the mouse is on them (any distance), or while they
## are selected -- 100 citizens in one spot would otherwise pile up into an unreadable mess. Other players' nameplates
## are never touched.
func _update_nameplates() -> void:
	var under_mouse := _citizen_under_mouse(false)
	if under_mouse == _plate_hover:
		return
	if _plate_hover != null and is_instance_valid(_plate_hover) and _plate_hover != selected_citizen:
		_set_plate(_plate_hover, false)
	_plate_hover = under_mouse
	if _plate_hover != null:
		_set_plate(_plate_hover, true)

func _set_plate(citizen: Node3D, shown: bool) -> void:
	var plate := citizen.get("nameplate") as Nameplate
	if plate != null and citizen != Globals.player:
		plate.set_shown(shown)

## Yellow outline on the hovered citizen, only while they are within the player's work reach
func _update_hover() -> void:
	var target: Node3D = null
	var player := Globals.player
	if player != null and (builder == null or not builder.interact_mode):
		var candidate := _citizen_under_mouse()
		if candidate != null and candidate != selected_citizen \
				and Builder.flat_distance(candidate.global_position, player.global_position) <= Builder.PLAYER_WORK_REACH:
			target = candidate
	_set_hover(target)

func _set_hover(target: Node3D) -> void:
	if target == _hovered:
		return
	for mesh in _hover_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_hover_meshes.clear()
	_hovered = target
	if target == null or outline_material == null:
		return
	for node in target.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		mesh.material_overlay = outline_material
		_hover_meshes.append(mesh)

func _process(delta: float) -> void:
	_update_hover()
	_update_nameplates()
	_outline_timer -= delta
	if _outline_timer <= 0.0 and selected_citizen != null:
		_outline_timer = OUTLINE_REFRESH_INTERVAL
		_refresh_outlines()
	if selected_citizen and is_instance_valid(selected_citizen):
		_refresh_panel()
		_update_ring_position()
		_update_panel_position()
	elif selected_citizen:
		# Citizen was freed (e.g. removed from the world) while selected
		_deselect()

## Yellow outline on everything the selected citizen can be sent to (trees, loose logs). Cleared on deselect.
func _refresh_outlines() -> void:
	var wanted: Array[MeshInstance3D] = []
	var player := Globals.player
	var active: bool = outline_material != null and player != null and selected_citizen != null \
			and is_instance_valid(selected_citizen)
	if active:
		var targets: Array = get_tree().get_nodes_in_group("gatherable")
		for prop in get_tree().get_nodes_in_group("resource_prop"):
			if not prop.collected:
				targets.append(prop)
		for target in targets:
			if Builder.flat_distance(target.global_position, player.global_position) > Builder.PLAYER_WORK_REACH:
				continue # out of the player's reach, so not offered
			for node in target.find_children("*", "MeshInstance3D", true, false):
				wanted.append(node as MeshInstance3D)
	for mesh in _outlined:
		if is_instance_valid(mesh) and not wanted.has(mesh):
			mesh.material_overlay = null
	for mesh in wanted:
		if mesh.material_overlay != outline_material:
			mesh.material_overlay = outline_material
	_outlined = wanted

func _update_ring_position() -> void:
	# Flat ring sitting just above the ground at the citizen's feet
	ring.global_position = selected_citizen.global_position + Vector3(0, 0.05, 0)

func _update_panel_position() -> void:
	if view_camera == null:
		return
	
	var screen_pos = view_camera.unproject_position(selected_citizen.global_position)
	
	# Don't show the panel if the citizen is behind the camera
	var cam_to_citizen = selected_citizen.global_position - view_camera.global_position
	if view_camera.global_transform.basis.z.dot(cam_to_citizen) > 0:
		panel.visible = false
		return
	panel.visible = true
	
	var target_pos = screen_pos + panel_offset
	
	# Clamp so the panel stays fully on-screen even if the citizen wanders near a viewport edge
	var panel_size = panel.size if panel.size.length_squared() > 1.0 else panel.custom_minimum_size
	var viewport_size = get_viewport().get_visible_rect().size
	target_pos.x = clamp(target_pos.x, 0, viewport_size.x - panel_size.x)
	target_pos.y = clamp(target_pos.y, 0, viewport_size.y - panel_size.y)
	
	panel.position = target_pos

func _refresh_panel() -> void:
	if selected_citizen == null or not is_instance_valid(selected_citizen):
		return
	
	var d = selected_citizen.data
	if d == null:
		return
	
	name_label.text = d.citizen_name if d.citizen_name != "" else "Unnamed citizen"
	id_label.text = "Citizen ID: " + d.id if d.id != "" else "No ID"
	
	var job_text = d.job if d.job != "" else "Unemployed"

	stats_label.clear()
	stats_label.append_text("[b]Age:[/b] %d\n" % d.age)
	stats_label.append_text("[b]Job:[/b] %s" % job_text)

	_begin_bars()
	_set_bar("Happiness", d.happiness, 100.0) # health and hunger/energy are on the citizen's nameplate now
	_end_bars()

	hostile_label.visible = selected_citizen.has_method("get") and "is_chasing_player" in selected_citizen and selected_citizen.is_chasing_player
	hostile_label.text = "Hostile -- chasing player!"

# Stat bars are real ProgressBar controls, not text (the game font has no block-character glyphs,
# and a web export has no system font to fall back on). Each row is a node under `bars_box`,
# named after its stat, with children Name / Bar / Value -- see main.tscn.
var _bars_used: Array[String] = []

func _begin_bars() -> void:
	_bars_used.clear()

func _end_bars() -> void:
	for row in bars_box.get_children():
		row.visible = _bars_used.has(row.name)

func _set_bar(stat: String, value: float, max_value: float) -> void:
	var row := bars_box.get_node_or_null(NodePath(stat))
	if row == null:
		push_warning("CitizenSelector: no row named '%s' under bars_box -- add one in main.tscn." % stat)
		return
	_bars_used.append(stat)
	var bar: ProgressBar = row.get_node("Bar")
	bar.max_value = maxf(max_value, 1.0)
	bar.value = clampf(value, 0.0, bar.max_value)
	var pct := int(round(bar.value / bar.max_value * 100.0))
	row.get_node("Value").text = "%d%%" % pct
	var fill := bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill != null:
		fill.bg_color = Color(0.37, 0.83, 0.37) if pct > 60 else (Color(0.88, 0.78, 0.29) if pct > 30 else Color(0.88, 0.37, 0.37))
