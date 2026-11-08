extends Carrier

@export var view_node: Node3D
## Your own name floats above your head (set by Network once you have chosen one)
@export var nameplate: Nameplate
## The capsule you are drawn as; Network tints it with your player colour
@export var body_mesh: MeshInstance3D
## "[E] Grab" prompt shown near small pick-up items (fruit); a Label in player.tscn
@export var grab_hint: Label
const GRAB_REACH := 1.8
const TAKE_LOG_HOLD := 0.8 # seconds E must be held on a woodpile log to take it
var _take_hold_start := -1 # msec when the current hold began (-1 = not holding)
var _pile_hover: ResourceProp # the woodpile log under the crosshair, outlined
var _pile_hover_meshes: Array[MeshInstance3D] = []
var _outline_material: Material # borrowed from the CitizenSelector so both outlines look the same
var _held_props: Array = [] # ResourceProps carried overhead, oldest first (up to ResourceProp.MAX_CARRY)
var _held_prop_names: Array = [] # online client: names of the props the server let us pick up (some still optimistic)

func set_body_color(color: Color) -> void:
	var base := body_mesh.get_active_material(0)
	if base is BaseMaterial3D:
		var tinted: BaseMaterial3D = base.duplicate()
		tinted.albedo_color = color
		body_mesh.material_override = tinted

const NO_ID := Builder.NO_ID

# Gathering / building (click-and-hold). A non-empty target id means the task is active.
var gather_target_id: String = NO_ID
var build_target_id: String = NO_ID
var demolish_target_id: String = NO_ID # structure / site being taken apart (hold Del + click and hold it)

var spawn_point: Vector3

@export_category("Devmode")
@export var dev_mode := false
@export var DEV_SPEED := 10.0
@export var DEV_RUN_SPEED := 16.0
@export var DEV_ACCEL := 10.0 # how quickly dev-mode flight eases to the wanted speed (higher = snappier)

# Player physical movement
@export_category("Physics")
@export var SPEED := 4.0
@export var RUN_SPEED := 6.0
@export var SWIM_SPEED := 0.5
@export var JUMP_HEIGHT := 7.0
## Hold jump to keep accelerating upward (up to JUMP_HOLD_TIME seconds). Letting go just stops adding
## acceleration -- you keep the upward speed you have and gravity takes over, you are NOT stopped.
@export var JUMP_HOLD_ACCEL := 12.0
@export var JUMP_HOLD_TIME := 0.25
var _jumping := false # true while rising from a jump the player started (so the walking hop isn't boosted)
var _jump_held_for := 0.0
@export var FRICTION := 0.8
@export var BOUNCE_HEIGHT := 5.0
var bounce_active := false

@export_category("Mechanics")
@export var hunger_dmg := 0.01

# Player physiological settings. health / max_health / fall damage / dying live in Carrier (shared with
# citizens). Assign to energy directly -- the setter clamps and emits energy_changed.
@export_category("Physiology")
@export var max_energy: float = 100.0
@export var heal_rate := 0.1
@export var heal_energy := 0.05

## Below this much health & energy the player starts to slow down (and jump / swim weaker), reaching a standstill at 0.
## Stacks multiplicatively with the low-energy slowdown, so being low on both is much worse than either.
@export var slow_below_health := 50.0
@export var slow_below_energy := 50.0

@export_range(0.0, 100.0) var energy: float = 100.0:
	set(value):
		var clamped := clampf(value, 0.0, 100.0)
		if clamped == energy:
			return
		energy = clamped
		energy_changed.emit(energy, 100.0)
@export var invuln_time: float = 0.5  # seconds of immunity after being hit
var invuln_timer: float = 0.0
@export var metabolism: float = 0.01
@export var move_energy := 0.1

# Knockback
var knockback: Vector3 = Vector3.ZERO
const KNOCKBACK_FRICTION = 6.0  # how fast knockback decays per second

signal energy_changed(current: float, max: float)

func _ready():
	spawn_point = global_position
	add_to_group("player")
	if view_node == null:
		view_node = get_tree().get_first_node_in_group("view")
		if view_node == null:
			push_warning("Player: no view node found (expected a node in group \"view\").")
	Globals.register_player(self)
	_carrier_ready() # sets `builder` (see carrier.gd)

func _physics_process(delta: float) -> void:
	_update_grab()
	
	if not dev_mode:
		_apply_gravity(delta) # see carrier.gd -- gradual sink in water, normal gravity on land
	
	# Cached: is_in_fluid() samples the water height. Dev mode is a free-fly cam, so water doesn't touch it.
	var in_fluid := is_in_fluid() and not dev_mode
	
	# (gravity / sinking is applied at the top by _apply_gravity())
	
	# ENERGY MECHANICS
	
	# Tiredness AND injury slow movement and weaken jumps. The two multipliers stack, so low health and
	# low energy together slow the player far more than either alone.
	var energy_mult := clampf(smoothstep(0.0, 1.0, energy / maxf(slow_below_energy, 0.001)), 0.2, 1.0)
	var health_mult := clampf(smoothstep(0.0, 1.0, health / maxf(slow_below_health, 0.001)), 0.2, 1.0)
	var vitality_mult := energy_mult * health_mult
	
	# Jump (solid ground only -- swimming is handled by the swim_up/swim_down axis below)
	var just_jumped := false
	if energy > 0.0:
		if Input.is_action_just_pressed("player_jump") and not in_fluid and (is_on_floor() or bounce_active):
			velocity.y = JUMP_HEIGHT * vitality_mult
			energy -= JUMP_HEIGHT * 0.01
			bounce_active = false
			just_jumped = true
			_jumping = true
			_jump_held_for = 0.0
	
	# Hold jump to keep accelerating upward; release just stops the extra acceleration (no cut)
	if _jumping:
		if velocity.y <= 0.0 or in_fluid or dev_mode:
			_jumping = false
		elif Input.is_action_pressed("player_jump") and _jump_held_for < JUMP_HOLD_TIME:
			velocity.y += JUMP_HOLD_ACCEL * vitality_mult * delta
			_jump_held_for += delta
		else:
			_jumping = false
	
	# Movement input, rotated to follow the camera
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var up_down := Input.get_axis("descend", "ascend")
	var move_vec := Vector3(input_dir.x, up_down if in_fluid or dev_mode else 0.0, input_dir.y)
	var direction := move_vec.rotated(Vector3.UP, view_node.rotation.y if view_node else 0.0).normalized()
	
	# Run & walk speed for player/dev mode
	var speed: float
	if Input.is_action_pressed("run"):
		speed = DEV_RUN_SPEED if dev_mode else RUN_SPEED
	else:
		speed = DEV_SPEED if dev_mode else SPEED
	
	# Horizontal movement steers toward the wanted velocity (see Carrier.steer_horizontal) instead of
	# piling onto velocity, so outside impacts can be steered against and decay normally.
	var wanted := Vector3(direction.x, 0.0, direction.z) * speed * (vitality_mult if dev_mode else 1.0)

	if dev_mode:
		# Free-fly: ease straight toward the wanted 3D velocity. (The old `velocity *= FRICTION` every physics
		# tick fought the steering and left dev mode crawling.)
		velocity = velocity.lerp(direction * speed, 1.0 - exp(-DEV_ACCEL * delta))
	else:
		# Send to carrier.gd to incorporate horizontal physics
		steer_horizontal(wanted, delta)
	
	if in_fluid:
		# Scaled by vertical/horizontal drag so top swim speed is unchanged now that vertical drag is weaker.
		# Letting go of swim up/down just stops adding acceleration: you coast and slow down gradually.
		velocity.y += direction.y * SWIM_SPEED * (2 - int(dev_mode)) * vitality_mult * (fluid_vertical_damp / fluid_damp)
		# Subtract energy when movement is done by player
		energy -= move_energy * delta
	
	# Small bounce animation while walking (skipped on the frame a jump already set velocity.y)
	if is_on_floor() and not dev_mode:
		if input_dir != Vector2.ZERO and not just_jumped:
			if not in_fluid or up_down >= 0.0:
				var temp_vel = BOUNCE_HEIGHT * vitality_mult
				if temp_vel >= 2.0:
					velocity.y += temp_vel
					bounce_active = true
	
	# Start eating away at health once at critical levels
	if energy < 0.1:
		health -= hunger_dmg * delta
	
	# Knockback from attackers, decaying over time
	if knockback.length() > 0.01:
		velocity += knockback
		knockback = knockback.move_toward(Vector3.ZERO, KNOCKBACK_FRICTION * delta)
	
	if invuln_timer > 0.0:
		invuln_timer -= delta
	
	_check_out_of_world() # falling out of the world kills, see carrier.gd
	
	_update_gathering(delta)
	_update_building_task(delta)
	_update_demolishing(delta)
	
	_before_slide() # records pre-slide velocity for the push logic, see carrier.gd
	
	# Fall damage needs the speed before move_and_slide() zeroes it on landing
	var fall_speed := -velocity.y
	var was_in_fluid := in_fluid
	move_and_slide()
	if not dev_mode:
		_apply_fall_damage(fall_speed, was_in_fluid) # see carrier.gd -- same rule for citizens
	
	_push_colliding_bodies() # move any moveable objects on player collision
	
	# Heal player if not at max health
	if health < 100.0 and energy > 30.0:
		health += heal_rate * delta
		energy -= heal_energy * delta
	
	energy -= metabolism * delta
	_update_eating(delta)

# --- Eating ---
# Standing at the stockpile while hungry (energy below Builder.hungry_below) eats its food one bite at a time, until
# Builder.eat_until. Only offline / on the host for now: an online client's stockpile is a copy of the server's, so
# eating there needs a request to the server (like req_build).
const EAT_BITE_INTERVAL := 0.8
var _eat_bite_timer := 0.0
var _is_eating := false

func _update_eating(delta: float) -> void:
	if builder == null or Globals.online_client or dev_mode:
		return
	_eat_bite_timer -= delta
	if _eat_bite_timer > 0.0:
		return
	var hungry:bool = energy < (builder.eat_until if _is_eating else builder.hungry_below)
	if not hungry or not builder.has_food() or not builder.is_at_food_store(global_position):
		_is_eating = false
		return
	_is_eating = true
	_eat_bite_timer = EAT_BITE_INTERVAL
	energy += builder.take_food()

# Called by attackers (e.g. angry citizens). Ignored while invulnerable.
func take_damage(amount: float, source_position: Vector3 = global_position, knockback_force: float = 4.0) -> void:
	if invuln_timer > 0.0:
		return
	invuln_timer = invuln_time
	
	# Push the player directly away from whatever hit them
	var push_dir := global_position - source_position
	push_dir = push_dir.normalized() if push_dir.length() > 0.01 else Vector3.FORWARD
	knockback = push_dir * knockback_force
	health -= amount # may trigger _on_death() via the setter

# Unlike citizens (who stay dead, see Carrier._on_death), the player respawns.
func _on_death() -> void:
	# Placeholder -- hook up a game-over screen later (`died` is already emitted by Carrier._die())
	position = spawn_point
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	health = max_health
	energy = max_energy
	is_dead = false
	
## Small items (fruit) can't be shoved around reliably, so E picks one up and stacks it overhead; keep pressing E to
## carry up to ResourceProp.MAX_CARRY at once, and Q drops the top one. Fruit counts once it lies in the food stockpile. Offline / on the host the props are simulated here and
## moved directly; an online client asks the server instead (WorldSync.req_prop_grab) and sees the props follow it.
func _update_grab() -> void:
	if builder == null:
		_set_grab_hint("")
		return
	if Globals.online_client:
		_update_grab_online()
		return
	for i in range(_held_props.size() - 1, -1, -1):
		var held_prop := _held_props[i] as ResourceProp
		if not is_instance_valid(held_prop) or held_prop.collected:
			_held_props.remove_at(i) # collected / gone: the stack closes up
	for i in _held_props.size():
		(_held_props[i] as ResourceProp).global_position = global_position + ResourceProp.carry_offset(i)
	var aimed := _aimed_pile_log()
	_set_pile_outline(aimed)
	if Input.is_action_just_pressed("drop") and not _held_props.is_empty():
		var top := _held_props.pop_back() as ResourceProp
		top.release(Vector3(velocity.x, 0.0, velocity.z))
	if aimed != null:
		_update_log_theft(aimed) # looking at a log on the woodpile: E is for taking it
		return
	_take_hold_start = -1
	var full := _held_props.size() >= ResourceProp.MAX_CARRY
	var nearest: ResourceProp = null if full else _nearest_grabbable(false)
	var drop_hint := "   [Q] Drop" if not _held_props.is_empty() else ""
	if nearest != null:
		_set_grab_hint("[E] Grab (%d/%d)%s" % [_held_props.size(), ResourceProp.MAX_CARRY, drop_hint])
		if Input.is_action_just_pressed("grab"):
			nearest.grab()
			_held_props.append(nearest)
	elif not _held_props.is_empty():
		if full:
			_set_grab_hint("Hands full (%d/%d) - [Q] Drop" % [_held_props.size(), ResourceProp.MAX_CARRY])
		else:
			_set_grab_hint("[Q] Drop (%d/%d)" % [_held_props.size(), ResourceProp.MAX_CARRY])
	else:
		_set_grab_hint("")

## The log on the woodpile the player is looking at (the same mouse / crosshair ray the citizen selector uses), if it is
## within work reach. Only offline / on the host: the server owns the pile.
func _aimed_pile_log() -> ResourceProp:
	if Globals.online_client:
		return null
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var screen_pos := Globals.aim_position()
	var from := camera.project_ray_origin(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen_pos) * 60.0)
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var prop := hit.get("collider") as ResourceProp
	if prop == null or not prop.in_pile or prop.collected:
		return null
	if Builder.flat_distance(prop.global_position, global_position) > Builder.PLAYER_WORK_REACH:
		return null
	return prop

## Hold E on an aimed log to take it off the pile: it pops out loose towards the player.
func _update_log_theft(prop: ResourceProp) -> void:
	if not Input.is_action_pressed("grab"):
		_take_hold_start = -1
		_set_grab_hint("[Hold E] Take log")
		return
	var now := Time.get_ticks_msec()
	if _take_hold_start < 0:
		_take_hold_start = now
	var t := float(now - _take_hold_start) / (TAKE_LOG_HOLD * 1000.0)
	if t >= 1.0:
		_take_hold_start = -1
		builder.take_log_from_pile(prop, global_position)
		_set_pile_outline(null)
	else:
		_set_grab_hint("Taking log... %d%%" % int(t * 100.0))

func _set_pile_outline(target: ResourceProp) -> void:
	if target == _pile_hover:
		return
	for mesh in _pile_hover_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_pile_hover_meshes.clear()
	_pile_hover = target
	if _outline_material == null:
		var selector := get_tree().root.find_child("CitizenSelector", true, false) # same yellow overlay it uses
		if selector != null:
			_outline_material = selector.get("outline_material")
	if target == null or _outline_material == null:
		return
	for node in target.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		mesh.material_overlay = _outline_material
		_pile_hover_meshes.append(mesh)

## The closest small prop within GRAB_REACH that can be picked up (logs are big enough to push, so they are skipped).
## On a client every prop is a puppet of the server's, which has the final say (can_be_grabbed) anyway.
func _nearest_grabbable(is_client: bool) -> ResourceProp:
	var nearest: ResourceProp = null
	var best := GRAB_REACH * GRAB_REACH
	for node in get_tree().get_nodes_in_group("resource_prop"):
		var prop := node as ResourceProp
		if prop == null or prop.collected:
			continue
		if not is_client and (prop.held or prop.is_puppet):
			continue
		if is_client and _held_prop_names.has(String(prop.name)):
			continue # already on our stack
		if builder.is_stacked_type(String(prop.get_meta("resource_type", ""))):
			continue
		var d := global_position.distance_squared_to(prop.global_position)
		if d < best:
			best = d
			nearest = prop
	return nearest

func _update_grab_online() -> void:
	var sync = Globals.world_sync
	if sync == null:
		_set_grab_hint("")
		return
	if not sync.grab_result.is_connected(_on_grab_result):
		sync.grab_result.connect(_on_grab_result)
	for i in range(_held_prop_names.size() - 1, -1, -1):
		var held := builder.get_node_or_null(NodePath(String(_held_prop_names[i]))) as ResourceProp
		if held == null or held.collected:
			_held_prop_names.remove_at(i) # it was collected (or is gone)
	var full := _held_prop_names.size() >= ResourceProp.MAX_CARRY
	var nearest: ResourceProp = null if full else _nearest_grabbable(true)
	if Input.is_action_just_pressed("drop") and not _held_prop_names.is_empty():
		sync.req_prop_grab(String(_held_prop_names.pop_back()), false)
	var drop_hint := "   [Q] Drop" if not _held_prop_names.is_empty() else ""
	if nearest != null:
		_set_grab_hint("[E] Grab (%d/%d)%s" % [_held_prop_names.size(), ResourceProp.MAX_CARRY, drop_hint])
		if Input.is_action_just_pressed("grab"):
			sync.req_prop_grab(String(nearest.name), true)
			_held_prop_names.append(String(nearest.name)) # optimistic; _on_grab_result removes it if the server said no
	elif not _held_prop_names.is_empty():
		if full:
			_set_grab_hint("Hands full (%d/%d) - [Q] Drop" % [_held_prop_names.size(), ResourceProp.MAX_CARRY])
		else:
			_set_grab_hint("[Q] Drop (%d/%d)" % [_held_prop_names.size(), ResourceProp.MAX_CARRY])
	else:
		_set_grab_hint("")

func _on_grab_result(prop_name: String, ok: bool) -> void:
	if not ok:
		_held_prop_names.erase(prop_name)

func _set_grab_hint(text: String) -> void:
	if grab_hint == null:
		return
	grab_hint.visible = text != ""
	grab_hint.text = text

func _unhandled_key_input(event: InputEvent) -> void:
	if event.keycode == KEY_F8 and not (event is InputEventKey and event.pressed and not event.echo):
		dev_mode = not dev_mode

func _unhandled_input(event: InputEvent) -> void:
	# Click-AND-HOLD to gather a resource OR help build a construction site --
	# same gesture, branches on what's under the cursor (see _try_start_work).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_work(Globals.aim_position())
		else:
			_stop_work()

func _try_start_work(screen_pos: Vector2) -> void:
	if builder == null or builder.interact_mode:
		return
	# A citizen is selected -- this click is for assigning them (see CitizenSelector)
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	if selector and selector.selected_citizen != null:
		return
	
	var hit := _raycast_target_in_reach(screen_pos)
	if hit.id == NO_ID:
		return
	
	# Holding Del while clicking a built structure (or a site) = take it apart. It takes labour: see
	# _update_demolishing and Builder.add_demolish_progress. Del held on anything else does nothing.
	if Input.is_action_pressed("demolish"):
		if builder.can_demolish(hit.id):
			demolish_target_id = hit.id
			get_viewport().set_input_as_handled()
		return
	
	# Construction site takes priority over gathering at the same spot.
	if hit.is_site:
		build_target_id = hit.id
		builder.assign_builder_to_site(Builder.PLAYER_BUILDER_ID, hit.id)
		get_viewport().set_input_as_handled()
		return
	
	var si: int = builder.get_structure_index(hit.id)
	if si >= 0 and builder.structures[si].gatherable:
		gather_target_id = hit.id
		get_viewport().set_input_as_handled()

func _stop_work() -> void:
	_stop_gathering()
	_stop_building_task()
	demolish_target_id = NO_ID

# True while a click-and-hold gather/build/demolish is active (the camera drag in view.gd checks this)
func is_working() -> bool:
	return gather_target_id != NO_ID or build_target_id != NO_ID or demolish_target_id != NO_ID

func _stop_gathering() -> void:
	gather_target_id = NO_ID

func _stop_building_task() -> void:
	if build_target_id != NO_ID and builder != null:
		builder.release_builder(Builder.PLAYER_BUILDER_ID)
	build_target_id = NO_ID

# Called every physics frame while the mouse button is held.
func _update_gathering(delta: float) -> void:
	if gather_target_id == NO_ID:
		return
	if builder == null:
		_stop_gathering()
		return
	
	# Tree already destroyed (by us or someone else) -- stop.
	var structure_index: int = builder.get_structure_index(gather_target_id)
	if structure_index < 0 or not builder.structures[structure_index].gatherable:
		_stop_gathering()
		return
	
	# Wandered out of reach while holding -- stop rather than gathering at a distance.
	if _flat_distance_to(builder.get_structure_position(gather_target_id)) > builder.get_gather_reach(gather_target_id):
		_stop_gathering()
		return
	
	var structure: Structure = builder.structures[structure_index]
	energy -= structure.energy_required * delta
	
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / structure.gather_time)
	if result.get("completed", false):
		energy += result.get("energy_bonus", 0.0)
		_stop_gathering()

# Called every physics frame while the mouse button is held on a structure and Del is held too. The ring over
# the building (Builder.update_demolish_ring) fills as labour goes in; the structure only goes once it is full.
func _update_demolishing(delta: float) -> void:
	if demolish_target_id == NO_ID:
		return
	if builder == null or not builder.can_demolish(demolish_target_id) or not Input.is_action_pressed("demolish"):
		demolish_target_id = NO_ID # gone already, or Del was let go
		return
	if _flat_distance_to(builder.get_demolish_position(demolish_target_id)) > Builder.PLAYER_WORK_REACH:
		demolish_target_id = NO_ID # wandered off
		return
	energy -= delta # same energy cost as any other labour
	if builder.add_demolish_progress(demolish_target_id, delta / builder.get_demolish_time(demolish_target_id)):
		demolish_target_id = NO_ID

# Progress itself accrues in Builder._process_construction() purely because
# PLAYER_BUILDER_ID is in assigned_builders -- this only validates the hold is
# still legitimate and pays the energy cost.
func _update_building_task(delta: float) -> void:
	if build_target_id == NO_ID:
		return
	if builder == null or not builder.construction_sites.has(build_target_id):
		_stop_building_task() # site finished or demolished mid-hold
		return
	
	var site = builder.construction_sites[build_target_id]
	if _flat_distance_to(site.position) > Builder.PLAYER_WORK_REACH:
		_stop_building_task()
		return
	
	energy -= builder.structures[site.structure_index].build_energy_required * delta

func _flat_distance_to(pos: Vector3) -> float:
	return global_position.distance_to(Vector3(pos.x, global_position.y, pos.z))

# Picks the construction site / placed structure under the cursor (a real physics pick, see
# Builder.pick_world_position) and checks it is within the player's reach.
# {id: String, is_site: bool}; id == NO_ID if nothing qualifies.
func _raycast_target_in_reach(screen_pos: Vector2) -> Dictionary:
	var none := {"id": NO_ID, "is_site": false}
	if builder == null:
		return none
	
	# A tree is picked by its whole shape (Builder.pick_object_at), not by where the ray lands on the ground.
	# Whatever the nearest hit is wins: a tree in front hides a site behind it, and an out-of-reach tree
	# is a miss rather than letting the click fall through to something behind it.
	var object_id: String = builder.pick_object_at(screen_pos)
	if object_id != NO_ID:
		if _flat_distance_to(builder.get_structure_position(object_id)) <= builder.get_gather_reach(object_id):
			return {"id": object_id, "is_site": false}
		return none
	
	var picked = builder.pick_world_position(screen_pos)
	if picked == null:
		return none
	var world_position: Vector3 = picked
	
	# The ray can end on something far away (e.g. the world boundary 500 m out): nothing there is in
	# reach, so don't even look for targets near that point.
	if _flat_distance_to(world_position) > Builder.PLAYER_WORK_REACH + Builder.PICK_RADIUS:
		return none
	
	var site_id: String = builder.get_nearest_construction_site(world_position)
	if site_id != NO_ID and Builder.flat_distance(builder.construction_sites[site_id].position, world_position) <= Builder.PICK_RADIUS:
		if _flat_distance_to(builder.construction_sites[site_id].position) <= Builder.PLAYER_WORK_REACH:
			return {"id": site_id, "is_site": true}
	
	var structure_id: String = builder.get_structure_at_point(world_position, Builder.PICK_RADIUS)
	if structure_id != NO_ID and _flat_distance_to(builder.get_structure_position(structure_id)) <= Builder.PLAYER_WORK_REACH:
		return {"id": structure_id, "is_site": false}
	
	return none
