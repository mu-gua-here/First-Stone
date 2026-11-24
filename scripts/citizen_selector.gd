extends Node3D
class_name CitizenSelector

## Click a citizen to select them for assignment: a slim card docks bottom-left (it never follows the citizen or covers
## the view), and the details key (default I) toggles a semi-transparent in-depth panel on the right. Neither pauses the game.
## With a citizen selected, click the ground to send them to that world position

@export var view_camera: Camera3D
@export var max_select_distance: float = 100.0
@export var details_key: Key = KEY_I ## toggles the in-depth panel while a citizen is selected
@export var click_assist_pixels: float = 40.0 # if the raycast misses, select the nearest citizen/player within this many screen pixels of the click instead -- citizens are small, constantly-moving targets

var selected_citizen: Node3D = null
var builder: Node = null

## UI + ring are real nodes in main.tscn (CitizenSelector/UI/Panel/..., CitizenSelector/Ring):
## restyle and move them in the 2D/3D editor. This script only fills in the text and numbers.
@export_group("Nodes")
@export var panel: PanelContainer
@export var name_label: Label
@export var stats_label: RichTextLabel
@export var bars_box: VBoxContainer ## card bars: one row per stat, each named after its stat ("Happiness") with children Name / Bar / Value
@export_subgroup("Details")
@export var details_panel: PanelContainer ## the in-depth panel (right side), toggled with details_key
@export var details_name_label: Label
@export var details_stats_label: RichTextLabel
@export var details_bars: VBoxContainer ## same row layout as bars_box: Health, Hunger, Energy, Happiness, Approval
@export_subgroup("")
@export var hostile_label: Label
@export var assign_hint_label: Label
@export var ring: MeshInstance3D
@export var outline_material: Material ## yellow overlay drawn on a citizen under the mouse (within the player's reach) as a "you can select me" hint
var _hovered: Node3D = null # citizen under the mouse and within the player's reach: gets the outline as a "you can select me" hint
var _hover_meshes: Array[MeshInstance3D] = []

var _plate_hover: Node3D = null # citizen under the mouse at any distance: the only one (besides the selected) with a nameplate
var _details_open := false # the player's choice; the panel only shows while a citizen is selected, and stays open when selecting someone else

func _ready() -> void:
	add_to_group("citizen_selector")
	panel.visible = false
	details_panel.visible = false
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
	if Globals.is_gameplay_input_blocked():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == details_key and selected_citizen != null:
		_details_open = not _details_open
		details_panel.visible = _details_open
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Building mode owns left-click for placement/demolition (the "build"
		# input action is also bound to it) -- don't also try to select/assign
		# citizens while placing structures.
		if builder != null and builder.build_mode:
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
	
	
	# Not a citizen -- with a CITIZEN selected (the player isn't commandable), a click on the world sends them to that spot.
	if selected_citizen and is_instance_valid(selected_citizen) and result and result.has("position"):
		var ok := _execute_go_to(result.position)
		_flash_assign_hint(ok)
		_after_assign(ok)
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

## Orders the selected citizen to walk to a world position. Online the citizen lives on the server, so ask it to do this and
## show its answer when it arrives (WorldSync.assign_result).
func _execute_go_to(world_pos: Vector3) -> bool:
	if not Globals.online_client:
		return PolicyEngine.execute(Action.new_go_to_position(), selected_citizen, world_pos)
	var world_sync = Globals.world_sync
	if not world_sync.assign_result.is_connected(_on_assign_result):
		world_sync.assign_result.connect(_on_assign_result)
	world_sync.req_go_to(selected_citizen.data.id, world_pos)
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
	details_panel.visible = _details_open
	ring.visible = true
	assign_hint_label.visible = false
	_refresh_panel()

func _hide_selected_plate() -> void:
	if selected_citizen != null and is_instance_valid(selected_citizen) and selected_citizen != _plate_hover:
		_set_plate(selected_citizen, false)

func _deselect() -> void:
	_hide_selected_plate()
	selected_citizen = null
	panel.visible = false
	details_panel.visible = false
	ring.visible = false

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
	if player != null and (builder == null or not builder.build_mode):
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

func _process(_delta: float) -> void:
	_update_hover()
	_update_nameplates()
	if selected_citizen and is_instance_valid(selected_citizen):
		_refresh_panel()
		_update_ring_position()
	elif selected_citizen:
		# Citizen was freed (e.g. removed from the world) while selected
		_deselect()

func _update_ring_position() -> void:
	# Flat ring sitting just above the ground at the citizen's feet
	ring.global_position = selected_citizen.global_position + Vector3(0, 0.05, 0)

func _refresh_panel() -> void:
	if selected_citizen == null or not is_instance_valid(selected_citizen):
		return
	
	var d = selected_citizen.data
	if d == null:
		return
	
	var citizen_name: String = d.citizen_name if d.citizen_name != "" else "Unnamed citizen"
	var job_text: String = d.job if d.job != "" else "Unemployed"
	var doing := _activity(selected_citizen)
	
	# Slim docked card: just what you need while assigning (health / hunger / energy are on the nameplate)
	name_label.text = citizen_name
	stats_label.clear()
	stats_label.append_text("[b]Job:[/b] %s\n[b]Doing:[/b] %s" % [job_text, doing])
	_set_bar(bars_box, "Happiness", d.happiness, 100.0)
	
	hostile_label.visible = "is_chasing_player" in selected_citizen and selected_citizen.is_chasing_player
	hostile_label.text = "Hostile -- chasing player!"
	
	# In-depth panel (only costs anything while it is open)
	if not details_panel.visible:
		return
	details_name_label.text = citizen_name
	details_stats_label.clear()
	details_stats_label.append_text("[b]Citizen ID:[/b] %s\n[b]Age:[/b] %d\n[b]Job:[/b] %s\n[b]Doing:[/b] %s\n[b]Job satisfaction:[/b] %d%%\n[b]Housing satisfaction:[/b] %d%%" \
			% [d.id if d.id != "" else "-", d.age, job_text, doing, int(d.job_satisfaction), int(d.housing_satisfaction)])
	var puppet: bool = selected_citizen.get("is_puppet") == true # online citizens carry their stats in net_* fields
	_set_bar(details_bars, "Health", selected_citizen.net_health if puppet else selected_citizen.health, 100.0)
	_set_bar(details_bars, "Hunger", selected_citizen.net_hunger if puppet else selected_citizen.hunger, 100.0)
	_set_bar(details_bars, "Energy", selected_citizen.net_energy if puppet else selected_citizen.energy, 100.0)
	_set_bar(details_bars, "Happiness", d.happiness, 100.0)
	_set_bar(details_bars, "Approval", d.approval, 100.0)

## What the citizen is doing right now, for the card and the details panel (online copies don't have these flags)
func _activity(c: Node3D) -> String:
	if c.get("is_puppet") == true:
		return "-"
	if c.get("is_chasing_player") == true:
		return "Chasing the player"
	if c.get("is_resting") == true:
		return "Resting"
	if c.get("is_building") == true:
		return "Building"
	if c.get("is_gathering") == true:
		return "Gathering"
	if c.get("is_pushing") == true:
		return "Hauling"
	return "Idle"

# Stat bars are real ProgressBar controls, not text (the game font has no block-character glyphs,
# and a web export has no system font to fall back on). Each row is a node under `box`,
# named after its stat, with children Name / Bar / Value -- see main.tscn.
func _set_bar(box: Control, stat: String, value: float, max_value: float) -> void:
	var row := box.get_node_or_null(NodePath(stat))
	if row == null:
		push_warning("CitizenSelector: no row named '%s' under %s -- add one in main.tscn." % [stat, box.name])
		return
	var bar: ProgressBar = row.get_node("Bar")
	bar.max_value = maxf(max_value, 1.0)
	bar.value = clampf(value, 0.0, bar.max_value)
	var pct := int(round(bar.value / bar.max_value * 100.0))
	row.get_node("Value").text = "%d%%" % pct
	var fill := bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill != null:
		if not bar.has_meta("own_fill"): # rows may share one stylebox resource; give each bar its own so colours don't bleed across bars
			fill = fill.duplicate()
			bar.add_theme_stylebox_override("fill", fill)
			bar.set_meta("own_fill", true)
		fill.bg_color = Color(0.37, 0.83, 0.37) if pct > 60 else (Color(0.88, 0.78, 0.29) if pct > 30 else Color(0.88, 0.37, 0.37))
