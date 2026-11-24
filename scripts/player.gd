extends Carrier

@export var view_node: Node3D
## Your own name floats above your head (set by Network once you have chosen one)
@export var nameplate: Nameplate
## The capsule you are drawn as; Network tints it with your player colour
@export var body_mesh: MeshInstance3D
## "[E] Grab" prompt box shown near small pick-up items (fruit); a PanelContainer in player.tscn (its Label child holds the text)
@export var grab_hint: Control
@export var grab_hint_label: Label
const GRAB_REACH := 6.0
const PROP_PICK_RADIUS := 0.5
var _held_props: Array = [] # ResourceProps carried overhead, oldest first (up to ResourceProp.MAX_CARRY)
var _held_prop_names: Array = [] # online client: names of the props the server let us pick up (some still optimistic)
var _prop_pick_shape: SphereShape3D

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
var _build_assigned := false # true while the crosshair / cursor is over the site being built (see _update_building_task)
var demolish_target_id: String = NO_ID # structure / site being taken apart (delete mode, click and hold it)

var spawn_point: Vector3

@export_category("Devmode")
@export var dev_mode := false
@export var DEV_SPEED := 10.0
@export var DEV_RUN_SPEED := 16.0
@export var DEV_ACCEL := 10.0 # how quickly dev-mode flight eases to the wanted speed (higher = snappier)

# Player physical movement
@export_category("Physics")
@export var JUMP_HEIGHT := 7.0
## Hold jump to keep accelerating upward (up to JUMP_HOLD_TIME seconds). Letting go just stops adding
## acceleration -- you keep the upward speed you have and gravity takes over, you are NOT stopped.
@export var JUMP_HOLD_ACCEL := 12.0
@export var JUMP_HOLD_TIME := 0.25
var _jumping := false # true while rising from a jump the player started (so the walking hop isn't boosted)
var _jump_held_for := 0.0
@export var BOUNCE_HEIGHT := 5.0
var bounce_active := false

@export var invuln_time: float = 0.5  # seconds of immunity after being hit
var invuln_timer: float = 0.0

# Knockback
var knockback: Vector3 = Vector3.ZERO
const KNOCKBACK_FRICTION = 6.0  # how fast knockback decays per second

func _ready():
	spawn_point = global_position
	add_to_group("player")
	_prop_pick_shape = SphereShape3D.new()
	_prop_pick_shape.radius = PROP_PICK_RADIUS
	if view_node == null:
		view_node = get_tree().get_first_node_in_group("view")
		if view_node == null:
			push_warning("Player: no view node found (expected a node in group \"view\").")
	Globals.register_player(self)
	_carrier_ready() # sets `builder` (see carrier.gd)

func _physics_process(delta: float) -> void:
	if Globals.is_gameplay_input_blocked():
		cancel_gameplay_input()
		velocity = Vector3.ZERO
		return

	_update_grab()
	if is_resting:
		_set_grab_hint("You passed out from exhaustion..." if collapsed else "Sleeping... move or jump to wake up") # (a sleeping player is not carrying anything the hint could be about)
	
	if not dev_mode:
		_apply_gravity(delta) # see carrier.gd -- gradual sink in water, normal gravity on land
	
	# Cached: is_in_fluid() samples the water height. Dev mode is a free-fly cam, so water doesn't touch it.
	var in_fluid := is_in_fluid() and not dev_mode
	
	# Passing out is innate (not a policy): at collapse_below energy you drop where you stand and stay out cold until energy is
	# back above collapse_wake. Out in the open recharges at half rate, beside a shelter at full rate (see below).
	if collapsed and (energy >= collapse_wake or dev_mode):
		collapsed = false
		is_resting = false
	elif not collapsed and not dev_mode and not in_fluid and energy <= collapse_below:
		collapsed = true
		is_resting = true
		_stop_work()
	
	# (gravity / sinking is applied at the top by _apply_gravity())
	
	# VITALS (hunger and energy: see carrier.gd)
	
	# Injury, hunger AND tiredness slow movement and weaken jumps. The three multipliers stack, so being hurt, starving and
	# worn out together slow the player far more than any one alone.
	var vitality_mult := _vitality_mult()
	
	# Jump (solid ground only -- swimming is handled by the swim_up/swim_down axis below)
	var just_jumped := false
	if energy > 0.0 and not collapsed:
		if Input.is_action_just_pressed("player_jump") and not in_fluid and (is_on_floor() or bounce_active):
			velocity.y = JUMP_HEIGHT * vitality_mult * 0.5 * (2 - int(_holding_log()))
			energy -= jump_energy
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
	var input_dir := Vector2.ZERO if collapsed else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var up_down := 0.0 if collapsed else Input.get_axis("descend", "ascend")
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
	var wanted := Vector3(direction.x, 0.0, direction.z) * speed * (vitality_mult if dev_mode else _carry_speed_mult()) # (a log in your arms slows you down)

	if dev_mode:
		# Free-fly: ease straight toward the wanted 3D velocity
		velocity = velocity.lerp(direction * speed, 1.0 - exp(-DEV_ACCEL * delta))
	else:
		# Send to carrier.gd to incorporate horizontal physics
		steer_horizontal(wanted, delta)
		
		if wanted.length() > 0.0:
			_spend_travel_energy(delta, in_fluid) # walking tires you out, swimming more so
	
	# Asleep (toggled with SLEEP_KEY, see _toggle_sleep): moving, jumping, swimming, working or dev flight wakes you, and so does
	# a full recharge. Sleeping beside a shelter recharges energy faster than out in the open (Carrier.sleeping_in_shelter).
	if is_resting and not collapsed and (input_dir != Vector2.ZERO or Input.is_action_just_pressed("player_jump") or in_fluid or dev_mode or is_working() or energy >= max_energy):
		is_resting = false
	if is_resting:
		sleeping_in_shelter = builder != null and builder.is_near_shelter(global_position)
	is_active = input_dir != Vector2.ZERO or in_fluid or is_working() # awake and doing nothing recharges energy slowly (Carrier.idle_recharge)
	_tick_vitals(delta) # hunger burns, healing costs hunger, starving / exhaustion hurt, resting recharges energy (carrier.gd)
	
	if in_fluid:
		# Scaled by vertical/horizontal drag so top swim speed is unchanged now that vertical drag is weaker.
		# Letting go of swim up/down just stops adding acceleration: you coast and slow down gradually.
		velocity.y += direction.y * SWIM_SPEED * (2 - int(dev_mode)) * vitality_mult * (fluid_vertical_damp / fluid_damp)
	
	# Small bounce animation while walking (skipped on the frame a jump already set velocity.y)
	if is_on_floor() and not dev_mode:
		if input_dir != Vector2.ZERO and not just_jumped:
			if not in_fluid or up_down >= 0.0:
				var temp_vel = BOUNCE_HEIGHT * vitality_mult
				if temp_vel >= 2.0:
					velocity.y += temp_vel
					bounce_active = true
	
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
	
	_update_eating(delta)

# --- Eating ---
# Standing at the stockpile while hungry (hunger below Builder.hungry_below) eats its food one bite at a time, until
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
	var hungry:bool = hunger < (builder.eat_until if _is_eating else builder.hungry_below)
	if not hungry or not builder.has_food() or not builder.is_at_food_store(global_position):
		_is_eating = false
		return
	_is_eating = true
	_eat_bite_timer = EAT_BITE_INTERVAL
	hunger += builder.take_food()

# Called by attackers (e.g. angry citizens). Ignored while invulnerable.
func take_damage(amount: float, source_position: Vector3 = global_position, knockback_force: float = 4.0) -> void:
	if invuln_timer > 0.0:
		return
	invuln_timer = invuln_time
	if not collapsed:
		is_resting = false # being hit wakes you up (unless you are out cold from exhaustion)
	
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
	hunger = max_hunger
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
	var carry_forward := Vector3.FORWARD.rotated(Vector3.UP, view_node.rotation.y) if view_node != null else Vector3.FORWARD # carried in front of the player (the way the camera looks)
	for i in _held_props.size():
		(_held_props[i] as ResourceProp).carry_to(global_position + ResourceProp.carry_offset(i, carry_forward), carry_forward)
	_eat_held_fruit()
	if Input.is_action_just_pressed("drop") and not _held_props.is_empty():
		var top := _held_props.pop_back() as ResourceProp
		top.release(Vector3(velocity.x, 0.0, velocity.z))
	var full := _held_props.size() >= ResourceProp.MAX_CARRY or _holding_log() # no room for fruit (a log fills your arms)
	_update_pick_hover(false, full) # outlines the prop / bush under the cursor; a left click grabs it (_try_click_grab)
	var drop_hint := ("   [Q] Drop" + ("   [F] Eat" if _holding_food() else "")) if not _held_props.is_empty() else ""
	if _hover_prop != null:
		if _hover_prop.is_log():
			_set_grab_hint("Click to grab log%s" % drop_hint)
		else:
			_set_grab_hint("Click to grab (%d/%d)%s" % [_held_props.size(), ResourceProp.MAX_CARRY, drop_hint])
	elif _hover_bush != null:
		_set_grab_hint("Click to pick fruit (%d/%d)%s" % [_held_props.size(), ResourceProp.MAX_CARRY, drop_hint])
	elif not _held_props.is_empty():
		if _holding_log():
			_set_grab_hint("Carrying a log - [Q] Drop")
		elif full:
			_set_grab_hint("Hands full (%d/%d) - [Q] Drop" % [_held_props.size(), ResourceProp.MAX_CARRY])
		else:
			_set_grab_hint("[Q] Drop (%d/%d)" % [_held_props.size(), ResourceProp.MAX_CARRY])
	else:
		_set_grab_hint("")

# Holding fruit: hold F to eat it right out of your hands, one bite per EAT_BITE_INTERVAL (offline / host only, like eating at the store)
const EAT_HELD_KEY := KEY_F
var _eat_held_timer := 0.0

func _eat_held_fruit() -> void:
	if not Input.is_key_pressed(EAT_HELD_KEY) or Globals.online_client or dev_mode or hunger >= 100.0:
		_eat_held_timer = 0.0
		return
	_eat_held_timer -= get_physics_process_delta_time()
	if _eat_held_timer > 0.0:
		return
	for i in range(_held_props.size() - 1, -1, -1):
		var held_prop := _held_props[i] as ResourceProp
		if is_instance_valid(held_prop) and String(held_prop.get_meta("resource_type", "")) == "food":
			_eat_held_timer = EAT_BITE_INTERVAL
			_held_props.remove_at(i)
			hunger += builder.eat_held_prop(held_prop)
			return

func _holding_food() -> bool:
	for held_prop in _held_props:
		if is_instance_valid(held_prop) and String(held_prop.get_meta("resource_type", "")) == "food":
			return true
	return false

func _holding_log() -> bool:
	for held_prop in _carried_props(Globals.online_client):
		if is_instance_valid(held_prop) and (held_prop as ResourceProp).is_log():
			return true
	return false

## What is in the arms: the ResourceProps themselves offline / on the host, or (online client) the ones the server let us pick up, looked up by name
func _carried_props(is_client: bool) -> Array:
	if not is_client:
		return _held_props
	var props: Array = []
	for prop_name in _held_prop_names:
		var prop = builder.get_node_or_null(NodePath(String(prop_name))) if builder != null else null
		if prop != null:
			props.append(prop)
	return props

# A log in the arms slows the player (see Carrier._carry_speed_mult)
func _carry_speed_mult() -> float:
	return ResourceProp.carry_speed_mult(_carried_props(Globals.online_client))

const PROP_PICK_RAY_LENGTH := 60.0
var _hover_prop: ResourceProp = null # the grabbable prop under the cursor (null: none)
var _hover_bush: Gatherable = null # the bush under the cursor whose fruit can be picked (null: none)
var _hover_target: Node3D = null
var _hover_meshes: Array[MeshInstance3D] = []

## Click-to-grab only works in the plain play mode: not while building / demolishing, and not while a citizen is selected
## (that click assigns the citizen a task, see CitizenSelector)
func _can_pick_by_click() -> bool:
	if builder == null or dev_mode or is_dead:
		return false
	if builder.build_mode:
		return false
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	return selector == null or selector.selected_citizen == null

## The prop under the cursor (or the crosshair) that can be picked up and that the hands have room for: fruit, and logs (a log
## needs free arms, see ResourceProp.has_room_for). Must be within GRAB_REACH of the player. A nearer object under the cursor
## hides what is behind it (a swept sphere). Logs lying on the stockpile count only once settled on it.
## On a client every prop is a puppet of the server's, which has the final say (can_be_grabbed) anyway.
func _grabbable_prop_at(screen_pos: Vector2, is_client: bool) -> ResourceProp:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var from := camera.project_ray_origin(screen_pos)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _prop_pick_shape
	query.transform = Transform3D(Basis.IDENTITY, from)
	query.motion = camera.project_ray_normal(screen_pos) * PROP_PICK_RAY_LENGTH
	query.exclude = [get_rid()] # the camera looks past the player's own body
	query.collide_with_bodies = true
	var space := get_world_3d().direct_space_state
	var motion := space.cast_motion(query)
	if motion.size() < 2 or motion[0] >= 1.0:
		return null
	query.transform.origin += query.motion * motion[1]
	var hit := space.get_rest_info(query)
	if hit.is_empty():
		return null
	var prop := instance_from_id(int(hit.get("collider_id", 0))) as ResourceProp
	if prop == null or prop.collected:
		return null
	if not prop.can_be_grabbed():
		return null
	if not is_client and (prop.held or prop.is_puppet):
		return null
	if is_client and _held_prop_names.has(String(prop.name)):
		return null # already on our stack
	if not ResourceProp.has_room_for(_carried_props(is_client), prop):
		return null
	if prop.is_log() and prop.in_pile and not prop.has_arrived():
		return null # still flying onto the pile
	if global_position.distance_to(prop.global_position) > GRAB_REACH:
		return null
	return prop

## Finds what the cursor is over (a grabbable prop, else a bush with fruit within reach) and outlines it
func _update_pick_hover(is_client: bool, full: bool) -> void:
	_hover_prop = null
	_hover_bush = null
	if _can_pick_by_click():
		var screen_pos := Globals.aim_position()
		_hover_prop = _grabbable_prop_at(screen_pos, is_client)
		if _hover_prop == null and not full and not is_client:
			_hover_bush = builder.pick_bush_at(screen_pos, global_position, GRAB_REACH)
	var target: Node3D = _hover_prop
	if target == null:
		target = _hover_bush
	_set_hover_outline(target)

func _set_hover_outline(target: Node3D) -> void:
	if target == _hover_target:
		return
	for mesh in _hover_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_hover_meshes.clear()
	_hover_target = target
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	var outline: Material = selector.outline_material if selector != null else null # the same yellow outline the selector uses
	if target == null or outline == null:
		return
	for node in target.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		mesh.material_overlay = outline
		_hover_meshes.append(mesh)

## A left click on the outlined prop / bush grabs it (what E used to do). Returns true if the click was used.
func _try_click_grab(screen_pos: Vector2) -> bool:
	if not _can_pick_by_click():
		return false
	var is_client := Globals.online_client
	var prop := _grabbable_prop_at(screen_pos, is_client)
	if prop != null:
		if is_client:
			var sync = Globals.world_sync
			if sync == null:
				return false
			sync.req_prop_grab(String(prop.name), true)
			_held_prop_names.append(String(prop.name)) # optimistic; _on_grab_result removes it if the server said no
		else:
			prop.grab()
			_held_props.append(prop)
		_set_hover_outline(null)
		return true
	if is_client or _held_props.size() >= ResourceProp.MAX_CARRY or _holding_log():
		return false
	var bush: Gatherable = builder.pick_bush_at(screen_pos, global_position, GRAB_REACH)
	if bush == null:
		return false
	var fruit: ResourceProp = builder.pick_bush_fruit(bush)
	if fruit == null:
		return false
	fruit.grab()
	_held_props.append(fruit)
	return true

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
	var full := _held_prop_names.size() >= ResourceProp.MAX_CARRY or _holding_log()
	_update_pick_hover(true, full)
	if Input.is_action_just_pressed("drop") and not _held_prop_names.is_empty():
		sync.req_prop_grab(String(_held_prop_names.pop_back()), false)
	var drop_hint := "   [Q] Drop" if not _held_prop_names.is_empty() else ""
	if _hover_prop != null:
		if _hover_prop.is_log():
			_set_grab_hint("Click to grab log%s" % drop_hint)
		else:
			_set_grab_hint("Click to grab (%d/%d)%s" % [_held_prop_names.size(), ResourceProp.MAX_CARRY, drop_hint])
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
	if grab_hint == null or grab_hint_label == null:
		return
	grab_hint.visible = text != ""
	grab_hint_label.text = text

func _unhandled_key_input(event: InputEvent) -> void:
	if Globals.is_gameplay_input_blocked():
		return
	if event.keycode == KEY_F8 and not (event is InputEventKey and event.pressed and not event.echo):
		dev_mode = not dev_mode
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == SLEEP_KEY:
		_toggle_sleep()

## Lie down / get up. Sleeping recharges energy much faster than standing around (and fastest beside a shelter), but only works
## while you are standing on the ground and not already fully rested.
const SLEEP_KEY := KEY_X # (Z is zone mode, C is descend)
func _toggle_sleep() -> void:
	if collapsed:
		return # out cold: you wake when you are rested enough
	if is_resting:
		is_resting = false
		return
	if dev_mode or is_dead or is_in_fluid() or not is_on_floor() or energy >= max_energy:
		return
	_stop_work() # put down the axe
	is_resting = true

func _unhandled_input(event: InputEvent) -> void:
	if Globals.is_gameplay_input_blocked() or collapsed:
		return
	# Click-AND-HOLD to gather a resource OR help build a construction site --
	# same gesture, branches on what's under the cursor (see _try_start_work).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _try_click_grab(Globals.aim_position()):
				get_viewport().set_input_as_handled()
				return
			_try_start_work(Globals.aim_position())
		else:
			_stop_work()

func _try_start_work(screen_pos: Vector2) -> void:
	if builder == null or (builder.build_mode and not builder.delete_mode):
		return # building mode: left click places things
	# A citizen is selected -- this click is for assigning them (see CitizenSelector)
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	if selector and selector.selected_citizen != null:
		return
	
	# A construction site is picked by its on-screen region (the crosshair / cursor over the site, see
	# Builder.pick_site_in_screen) rather than by where a physics ray lands on the ground.
	if not builder.delete_mode:
		var site_id: String = builder.pick_site_in_screen(screen_pos, global_position, Builder.PLAYER_WORK_REACH)
		if site_id != NO_ID:
			build_target_id = site_id
			_build_assigned = true
			builder.assign_builder_to_site(Builder.PLAYER_BUILDER_ID, site_id)
			get_viewport().set_input_as_handled()
			return
	
	var hit := _raycast_target_in_reach(screen_pos)
	if hit.id == NO_ID:
		return
	
	# In delete mode (B for build mode, then Command+B) clicking a built structure (or a site) takes it apart. It takes
	# labour: see _update_demolishing and Builder.add_demolish_progress. Clicking anything else in delete mode does nothing.
	if builder.delete_mode:
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

func cancel_gameplay_input() -> void:
	_stop_work()

# True while a click-and-hold gather/build/demolish is active (the camera drag in view.gd checks this)
func is_working() -> bool:
	return gather_target_id != NO_ID or build_target_id != NO_ID or demolish_target_id != NO_ID

func _stop_gathering() -> void:
	gather_target_id = NO_ID

func _stop_building_task() -> void:
	if build_target_id != NO_ID and builder != null:
		builder.release_builder(Builder.PLAYER_BUILDER_ID)
	build_target_id = NO_ID
	_build_assigned = false

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
	if _distance_to(builder.get_structure_position(gather_target_id)) > builder.get_gather_reach(gather_target_id):
		_stop_gathering()
		return
	
	var structure: Structure = builder.structures[structure_index]
	energy -= structure.energy_required * delta
	
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / structure.gather_time)
	if result.get("completed", false):
		hunger += result.get("hunger_bonus", 0.0)
		_stop_gathering()

# Called every physics frame while the mouse button is held on a structure in demolish mode. The ring over
# the building (Builder.update_demolish_ring) fills as labour goes in; the structure only goes once it is full.
func _update_demolishing(delta: float) -> void:
	if demolish_target_id == NO_ID:
		return
	if builder == null or not builder.can_demolish(demolish_target_id) or not builder.delete_mode:
		demolish_target_id = NO_ID # gone already, or delete mode was left
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
	
	# Progress only counts while the crosshair (or the cursor, when unlocked) is over the site's on-screen region. Looking away
	# pauses the work without ending the click-and-hold: look back at the site and it carries on.
	var over_site: bool = builder.screen_point_over_site(build_target_id, Globals.aim_position())
	if over_site != _build_assigned:
		_build_assigned = over_site
		if over_site:
			builder.assign_builder_to_site(Builder.PLAYER_BUILDER_ID, build_target_id)
		else:
			builder.release_builder(Builder.PLAYER_BUILDER_ID)
	if not over_site:
		return # no labour, so no energy cost either
	energy -= builder.structures[site.structure_index].build_energy_required * delta

func _flat_distance_to(pos: Vector3) -> float:
	return global_position.distance_to(Vector3(pos.x, global_position.y, pos.z))

# True 3D distance (height counts): a gatherable's reach is a sphere around it, same as its interact_hint.
func _distance_to(pos: Vector3) -> float:
	return global_position.distance_to(pos)

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
		if _distance_to(builder.get_structure_position(object_id)) <= builder.get_gather_reach(object_id):
			return {"id": object_id, "is_site": false}
		return none
	
	var picked = builder.pick_world_position(screen_pos)
	if picked == null:
		return none
	var world_position: Vector3 = picked
	
	# The ray can end on something far away, prevent out of range outputs
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
