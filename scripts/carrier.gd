extends CharacterBody3D
class_name Carrier

## Shared base for anything that can gather resources -- Player and Citizen
## both extend this instead of duplicating gathering-pipeline glue.
##
## Carriers handle the CHARACTER side of pushing: taking impacts (receive_push), steering their own
## horizontal movement, and shoving rigid bodies they walk into. The rigid-body impact solver lives
## in PhysicsPush (physics_push.gd).
##
## Impacts are one-time velocity changes. They are added to `velocity` once, and after that the
## character's own steering decides how fast it slides to a stop. Pushing against an impact cancels
## it quickly, and letting go lets it coast to a stop on friction.

## Mass in kg. Impacts are collisions between two masses, so the lighter side changes speed more.
@export var mass := 50.0
## Max force (N) this carrier can exert shoving a rigid body. Acceleration of the pushed body is
## push_force / its mass (F = m*a).
@export var push_force := 300.0

## Health, falling and dying are shared by everyone who extends Carrier (Player and Citizen), so they
## obey the same rules. What differs is only what dying DOES: see _on_death().
signal health_changed(current: float, max: float)
signal died

@export_category("Mechanics")
## Landing (or splashing down) faster than this (m/s) hurts. Damage = excess speed, halved in water.
@export var fall_dmg_threshold := 14.0
## Falling below this world height kills the carrier (it fell out of the world).
@export var kill_height := -100.0

@export_category("Physiology")
@export var max_health: float = 100.0
## Assign to health directly -- the setter clamps, emits health_changed and handles death.
@export_range(0.0, 100.0) var health: float = 100.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		if health <= 0.0:
			_die()

## True from the moment health hits 0 until (for the player only) the respawn.
var is_dead := false

## Upward swim acceleration (m/s^2) used by _swim_toward_surface() to tread water. Must beat the
## sink pull (sink_accel * fluid_vertical_damp / fluid_damp) for carriers to be able to float.
@export var swim_accel := 10.0

const MAX_IMPACT_SPEED := 15.0 # cap on a single impact's velocity change (m/s)
# Horizontal steering: how fast velocity moves toward the wanted velocity (m/s^2).
const GROUND_STEER_ACCEL := 60.0 # with input (incl. pushing back against an impact). Higher = snappier turns
const AIR_STEER_ACCEL := 25.0 # airborne steering. The player hops while walking, so most frames are airborne
const WATER_STEER_ACCEL := 60.0 # must beat fluid drag (fluid_damp * speed) or swimming stalls
const COYOTE_TIME := 0.25 # seconds after leaving the ground that still count as grounded for steering
var _since_grounded := 0.0
# Coasting when there is no input: friction on the ground, none in the air.
const GROUND_FRICTION := 10.0
const AIR_FRICTION := 10.0 # was 0.0: the player is airborne most of the time (walking hops), so no air friction = endless sliding
# A contact is a deck (something holding us up) when its normal faces upward (y > this) AND the
# contact point is below our centre. Tilted decks have shallow normals, so this uses the contact
# height as well, instead of the normal alone.
const DECK_NORMAL_Y := 0.3
const CEILING_NORMAL_Y := -0.7 # contacts facing down this hard are ceilings, never shoves

# Velocity at the start of this frame's move_and_slide(). The slide strips the part of velocity that
# points into whatever we hit, so the pre-slide value is what the push logic needs to read.
var pre_slide_velocity := Vector3.ZERO

# Resolved lazily: the Player sits BEFORE the Builder in main.tscn, so Globals.builder is still
# null during the Player's own _ready(). Reading it later picks it up.
var builder: Node = null:
	get:
		if builder == null:
			builder = Globals.builder
		return builder

## Sinking no buoyancy
## pulled down GRADUALLY rather than dropping like on land: a constant downward pull (sink_accel)
## fighting drag (fluid_damp), which eases in to a terminal sink speed of sink_accel / fluid_damp
## m/s. "In the water" = the water probe (centre of our collision shape) is below
## FluidArea3D.get_height(), i.e. roughly half submerged. See _apply_gravity().
@export var fluid_damp := 4.0

## Drag on VERTICAL velocity in water. Much lower than fluid_damp so that letting go of swim up/down
## doesn't stop you dead -- you keep coasting and slow gradually. (Terminal sink speed and terminal
## swim speed are unchanged: both are rescaled by fluid_vertical_damp / fluid_damp.)
@export var fluid_vertical_damp := 2.0

## Downward acceleration while in water (m/s^2). Terminal sink speed = sink_accel / fluid_damp
## (3.0 / 4.0 = 0.75 m/s). Raise for a faster sink, lower for a slower one.
@export var sink_accel := 6.0

## How far BELOW the visible water surface the body centre must be before it counts as in the
## water. 0.0 = centre at the surface, i.e. half the body can stay above water. Raise it to make
## carriers wade deeper before sinking.
@export var wade_depth := 0.0

## The FluidArea3D we're currently inside (null on land). Set by fluid_area_enter/exit.
var fluid_area: FluidArea3D = null
var _water_probe: CollisionShape3D = null

# Runs once when health reaches 0 (or we fall out of the world). Overridden by subclasses.
func _die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_on_death()

# What dying does. Default: gone for good (citizens). Player overrides this to respawn.
func _on_death() -> void:
	queue_free()

# Call once per physics frame. Falling out of the world is death.
func _check_out_of_world() -> void:
	if global_position.y < kill_height:
		_die()

# Call right AFTER move_and_slide() with the downward speed captured right BEFORE it (the slide zeroes
# velocity.y on landing) and whether we were in the water. Landing in water hurts half as much.
func _apply_fall_damage(fall_speed: float, was_in_fluid: bool) -> void:
	if (is_on_floor() or was_in_fluid) and fall_speed > fall_dmg_threshold:
		health -= (fall_speed - fall_dmg_threshold) * (1.0 if was_in_fluid else 2.0)

# Treading water: rises while the body centre is below the surface, easing off near it, so a carrier
# with no swim input floats half-submerged instead of sinking to the bottom. Call after _apply_gravity().
func _swim_toward_surface(delta: float) -> void:
	if not is_in_fluid():
		return
	var p := water_probe_position()
	var depth := fluid_area.get_surface_height(p) - p.y
	velocity.y += swim_accel * clampf(depth, 0.0, 1.0) * delta

# One-time impact: a rigid body (or another carrier) hit us with this velocity change.
func receive_push(dv: Vector3) -> void:
	velocity += dv.limit_length(MAX_IMPACT_SPEED)

# Moves horizontal velocity toward `wanted` (x/z only). Accelerates toward it with input, and
# coasts with friction when there is none. Call once per physics frame, before _before_slide().
func steer_horizontal(wanted: Vector3, delta: float) -> void:
	if is_on_floor():
		_since_grounded = 0.0
	else:
		_since_grounded += delta
	var has_input := wanted.length_squared() > 0.0001
	var rate: float
	if is_in_fluid():
		# Fluid drag (fluid_damp) shaves a fraction off velocity every frame, so a fixed accel tops out at
		# accel / fluid_damp m/s -- which capped swimming speed and made running pointless. Add the drag the
		# wanted speed will cost, so we can actually reach it (walk and run differ again).
		rate = (WATER_STEER_ACCEL + fluid_damp * wanted.length()) if has_input else 0.0 # no input: fluid drag does the slowing
	elif _since_grounded < COYOTE_TIME:
		rate = GROUND_STEER_ACCEL if has_input else GROUND_FRICTION
	else:
		rate = AIR_STEER_ACCEL if has_input else AIR_FRICTION
	var h := Vector3(velocity.x, 0.0, velocity.z).move_toward(Vector3(wanted.x, 0.0, wanted.z), rate * delta)
	velocity.x = h.x
	velocity.z = h.z

# True if `body` is holding us up (we're standing on its deck), from our last move_and_slide().
func is_standing_on(body: Node) -> bool:
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_collider() == body and _is_deck_contact(c):
			return true
	return false

func _is_deck_contact(c: KinematicCollision3D) -> bool:
	return c.get_normal().y > DECK_NORMAL_Y and c.get_position().y < water_probe_position().y

# Call right BEFORE move_and_slide().
func _before_slide() -> void:
	pre_slide_velocity = velocity

# Call this from _ready() in the subclass (after add_to_group etc.) instead
# of duplicating the setup.
func _carrier_ready() -> void:
	builder = Globals.builder
	# Trees live on their own physics layer (Builder.TREE_COLLISION_LAYER),
	# separate from the terrain's normal layer, so the static navmesh bake
	# never has to see them (see Builder._spawn_tree_obstacle()). That means
	# we have to explicitly opt in to colliding with that layer here, or
	# standing trees would stop physically blocking movement entirely.
	set_collision_mask_value(2, true)
	set_collision_mask_value(3, true) # world: the Base / Structures GridMaps sit on layer 3

	for owner_id in get_shape_owners():
		var collision = shape_owner_get_owner(owner_id)
		if collision is CollisionShape3D:
			_water_probe = collision
			break

# Call once per physics frame INSTEAD of applying get_gravity() yourself. On land this is plain
# gravity (skipped while on the floor). In water it is the gradual sink: constant pull down plus
# drag on the whole velocity, so you ease toward the bottom and horizontal motion is slowed.

func _apply_gravity(delta: float) -> void:
	if is_in_fluid():
		# Horizontal: full fluid drag. Vertical: weaker drag, with the sink pull scaled so the terminal
		# sink speed (sink_accel / fluid_damp) stays the same.
		velocity.y -= sink_accel * (fluid_vertical_damp / fluid_damp) * delta
		velocity.y -= velocity.y * fluid_vertical_damp * delta
		velocity.x -= velocity.x * fluid_damp * delta
		velocity.z -= velocity.z * fluid_damp * delta
		return
	if not is_on_floor():
		velocity += get_gravity() * delta

# Where we test "am I in the water": the centre of our collision shape (falls back to our origin).
func water_probe_position() -> Vector3:
	return _water_probe.global_position if _water_probe != null else global_position

func is_in_fluid() -> bool:
	if fluid_area == null:
		return false
	var p := water_probe_position()
	return p.y <= fluid_area.get_surface_height(p) - wade_depth

# Called by FluidArea3D.body_enter/body_exit via duck typing.
func fluid_area_enter(area: FluidArea3D) -> void:
	fluid_area = area

func fluid_area_exit(area: FluidArea3D) -> void:
	if fluid_area == area:
		fluid_area = null

# Pushes rigid bodies and other carriers we walked into. Reads this frame's actual collisions, so
# call it AFTER move_and_slide(). Each push is relative to the other body's velocity, so once we
# are moving along with it there is no further push.
func _push_colliding_bodies() -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider = collision.get_collider()

		# Only push RigidBody3Ds or CharacterBody3Ds, other objects are unpushable
		if not (collider is RigidBody3D or collider is CharacterBody3D):
			continue

		var normal := collision.get_normal()
		# Deck contacts (we're standing on it) and ceilings are never shoves
		if _is_deck_contact(collision) or normal.y < CEILING_NORMAL_Y:
			continue

		var push_dir := -normal
		push_dir.y = 0.0
		if push_dir.length() < 0.01:
			continue
		push_dir = push_dir.normalized()

		var other_velocity := Vector3.ZERO
		if collider is RigidBody3D:
			other_velocity = PhysicsPush.point_velocity(collider, collision.get_position())
		elif collider is CharacterBody3D:
			other_velocity = collider.velocity
		var incoming_speed: float = (pre_slide_velocity - other_velocity).dot(push_dir)
		if incoming_speed <= 0.0:
			continue

		# F = m*a: we can only exert push_force newtons, so the impulse this frame is capped at
		# push_force * dt. The pushed body's speed change is impulse / its mass.
		var other_mass: float = PhysicsPush.mass_of(collider)
		var total_mass: float = mass + other_mass
		if collider is RigidBody3D:
			var reduced_mass: float = mass * other_mass / total_mass
			var impulse: float = minf(incoming_speed * reduced_mass, push_force * get_physics_process_delta_time())
			var rel_position: Vector3 = collision.get_position() - collider.global_position
			if collider.has_method("net_push"):
				collider.net_push(push_dir * impulse, rel_position) # online: the prop lives on the server
			else:
				collider.apply_impulse(push_dir * impulse, rel_position)
			velocity -= push_dir * impulse / mass # equal and opposite
		elif collider is CharacterBody3D and collider.has_method("receive_push"):
			collider.receive_push(push_dir * incoming_speed * mass / total_mass)
			velocity -= push_dir * incoming_speed * other_mass / total_mass
