extends RigidBody3D
class_name ResourceProp

## A single physical unit of a gathered resource (one log, one fruit, etc).
## Builder.spawn_resource_prop() creates these one at a time as a gatherable
## structure (tree, bush) reaches fractional chop/pick progress -- see
## Builder.add_chop_progress() / _spawn_incremental_resource_props()
##
## Multiplayer: the SERVER simulates every prop. A client's copy is a puppet (is_puppet): frozen as a kinematic
## body, glided toward the transform the server sends (see WorldSync), and when somebody shoves it, the shove is
## reported to the server (net_push) instead of being applied here.

# A prop can only be collected once it's actually settled -- otherwise a log that's still falling or mid-flight
# from a push, but happens to pass over the stockpile's X/Z, gets counted while still airborne.
# (The collection area is the stockpile block, see Builder.is_in_stockpile.)
# Raised from 0.4: props had to be almost motionless before a stockpile accepted them. Anything slower than this (m/s) that
# is inside the stockpile block counts and tidies onto the pile.
const SETTLE_SPEED_THRESHOLD := 3.0
const PUPPET_SMOOTHING := 15.0
const PILE_CHECK_INTERVAL := 0.25 # how often a loose prop checks whether it should tidy onto its pile

# Hard speed caps. A lag spike (very common on the web build) makes the physics step resolve penetration in one go and can fire a
# prop off at absurd speed; clamping it in _integrate_forces keeps it from ever leaving the island that way.
const MAX_LINEAR_SPEED := 12.0 # m/s: a log dropped from RESOURCE_SPAWN_HEIGHT lands at ~7.7, a hard shove stays well below this
const MAX_ANGULAR_SPEED := 12.0 # rad/s

const CARRY_HEIGHT := 1.0 # the first carried item is held at arm level: this far above its carrier's origin (player.gd, citizen.gd, world_sync.gd)
const CARRY_FORWARD := 0.65 # ...and this far in front of the carrier
const CARRY_SPACING := 0.22 # each further carried item sits this much higher, forming a small stack in front of them
const MAX_CARRY := 10 # most small items one player can carry at a time
const GRAB_ANIM_TIME := 0.25 # seconds a grabbed item takes to hop from where it lay into the carrier's hands
const GRAB_ANIM_ARC := 0.25 # how high (m) it arcs on the way
const GRAB_ANIM_POP := 0.3 # extra scale at the peak of the hop (0.3 = 30% bigger)

## Where the index-th carried item (0 = first grabbed) is held, relative to its carrier's position: at arm level, in front of
## them (`forward` = the way they face; flattened, so only its direction on the ground matters)
static func carry_offset(index: int, forward: Vector3 = Vector3.FORWARD) -> Vector3:
	var flat := Vector3(forward.x, 0.0, forward.z)
	flat = flat.normalized() if flat.length() > 0.001 else Vector3.FORWARD
	return flat * CARRY_FORWARD + Vector3.UP * (CARRY_HEIGHT + index * CARRY_SPACING)

var collected: bool = false # set once the prop was used up (consume()): it no longer counts or moves
## True while this prop holds a slot on its stockpile's pile: first flying to it, then (once _arrived) lying on it frozen in
## place: solid, but not simulated. Taking one out leaves the ones above where they are (Builder takes the topmost first).
var in_pile := false
var _arrived := false # reached its slot and is now lying there frozen
var _tween: Tween
var _pile_layer := 1
var _pile_mask := 1
var _pile_check := 0.0
var held: bool = false # carried in front of someone (press E, see player.gd / citizen.gd) -- frozen and non-colliding, not simulated
var _grab_from := Vector3.ZERO
var _grab_start_ms := -100000 # when grab() ran; the hop into the hands plays for GRAB_ANIM_TIME after it
var _held_layer := 1
var _held_mask := 1
var is_puppet := false # set by Builder before the prop enters the tree
var _target_position := Vector3.ZERO
var _target_quaternion := Quaternion.IDENTITY
var _has_target := false

func _ready() -> void:
	if is_puppet:
		# Moved by the server's updates, not by physics. Kinematic, so players still can't walk through it.
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		return
	# Needed so get_colliding_bodies() works -- lets us shove Carriers (see PhysicsPush.solve_rigid_contacts()).
	contact_monitor = true
	max_contacts_reported = 8

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if freeze:
		return # puppets, carried and piled props are not simulated
	if state.linear_velocity.length_squared() > MAX_LINEAR_SPEED * MAX_LINEAR_SPEED:
		state.linear_velocity = state.linear_velocity.limit_length(MAX_LINEAR_SPEED)
	if state.angular_velocity.length_squared() > MAX_ANGULAR_SPEED * MAX_ANGULAR_SPEED:
		state.angular_velocity = state.angular_velocity.limit_length(MAX_ANGULAR_SPEED)

func _physics_process(delta: float) -> void:
	if is_puppet:
		if _has_target:
			var t := 1.0 - exp(-PUPPET_SMOOTHING * delta)
			global_position = global_position.lerp(_target_position, t)
			quaternion = quaternion.slerp(_target_quaternion, t)
		return
	if held or collected:
		return
	if in_pile:
		return # flying to its slot, or lying frozen on it: nothing to simulate
	PhysicsPush.solve_rigid_contacts(self) # loose props are shoved around like any physics body
	var owning_builder = get_meta("builder", null)
	if owning_builder == null:
		return
	var resource_type := String(get_meta("resource_type", ""))
	if not owning_builder.is_piled_type(resource_type):
		return
	_pile_check -= delta
	if _pile_check > 0.0:
		return
	_pile_check = PILE_CHECK_INTERVAL
	if owning_builder.is_in_pile_block(resource_type, global_position) and is_settled():
		_stack_on_pile(owning_builder)

## True once this prop is lying still (not carried, not shrinking away): Builder counts a stockpile's contents from
## the settled props inside it, so a log that is flying around or knocked out of the block simply stops counting.
func is_settled() -> bool:
	return not held and not collected and not is_puppet and (_arrived or sleeping or linear_velocity.length() < SETTLE_SPEED_THRESHOLD)

# A prop pushed into its stockpile tidies itself onto the pile (Builder.claim_stack_slot): it flies to its slot without
# colliding (so it can't knock the others about) and, once there, stays frozen as a solid, static block. A full pile
# (the fruit pyramid has a fixed size) leaves it lying where it is.
func _stack_on_pile(owning_builder) -> void:
	var slot = owning_builder.claim_stack_slot(self)
	if slot == null:
		return
	in_pile = true
	_arrived = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	_pile_layer = collision_layer
	_pile_mask = collision_mask
	collision_layer = 0
	collision_mask = 0
	_tween = create_tween()
	_tween.tween_property(self, "global_transform", slot, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_land_on_pile)

## True once this prop has reached its slot on the pile and is lying there frozen
func has_arrived() -> bool:
	return _arrived

func _land_on_pile() -> void:
	if collected or held:
		return
	collision_layer = _pile_layer
	collision_mask = _pile_mask
	# Stays frozen: a piled prop is a solid static block, with no simulation and no contact reporting (see _leave_pile)
	contact_monitor = false
	_arrived = true

# Gives up this prop's slot on the pile (grabbed, used up). A prop still flying to its slot gets its collision back.
func _leave_pile() -> void:
	if not in_pile:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not _arrived:
		collision_layer = _pile_layer
		collision_mask = _pile_mask
	contact_monitor = true # a prop that left the pile is a physics body again (see PhysicsPush.solve_rigid_contacts)
	var owning_builder = get_meta("builder", null)
	if owning_builder != null:
		owning_builder.release_stack_slot(self)
	in_pile = false
	_arrived = false

## Small items (fruit) are picked up with E instead of shoved around: the player carries it in front of them,
## and drops it again with Q (or just leaves it lying in the food stockpile, which counts it as usual).
## Logs are shoved instead, except the ones lying on the stockpile: those can be taken off it (stealing from the pile).
## Only the simulating copy (offline / host) can be grabbed; a client asks the server (WorldSync.req_prop_grab).
func can_be_grabbed() -> bool:
	if collected or held or is_puppet:
		return false
	if in_pile:
		return _arrived # still flying onto the pile: no; lying on it: yes, whatever it is
	var owning_builder = get_meta("builder", null)
	return owning_builder == null or not owning_builder.is_stacked_type(String(get_meta("resource_type", "")))

## Moves a held item to its spot in its carrier's hands. Right after grab() it hops there along a small arc with a pop of scale
## (same TRANS_BACK ease-out as the flight onto a stockpile pile); afterwards it just sits at `target`.
func carry_to(target: Vector3) -> void:
	var t := clampf(float(Time.get_ticks_msec() - _grab_start_ms) / 1000.0 / GRAB_ANIM_TIME, 0.0, 1.0)
	if t >= 1.0:
		global_position = target
		if not scale.is_equal_approx(Vector3.ONE):
			scale = Vector3.ONE
		return
	var e: float = Tween.interpolate_value(0.0, 1.0, t, 1.0, Tween.TRANS_BACK, Tween.EASE_OUT)
	global_position = _grab_from.lerp(target, e) + Vector3.UP * sin(t * PI) * GRAB_ANIM_ARC
	scale = Vector3.ONE * (1.0 + GRAB_ANIM_POP * sin(t * PI))

func grab() -> void:
	_grab_from = global_position
	_grab_start_ms = Time.get_ticks_msec()
	_leave_pile()
	held = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	# Carried items ride in front of their carrier without touching anything: no collision while they fly up to / stay at the arms
	_held_layer = collision_layer
	_held_mask = collision_mask
	collision_layer = 0
	collision_mask = 0

func release(throw_velocity: Vector3 = Vector3.ZERO) -> void:
	held = false
	scale = Vector3.ONE # in case it was dropped mid-hop
	collision_layer = _held_layer
	collision_mask = _held_mask
	freeze = false
	linear_velocity = throw_velocity

## The wood this log stood for went into a building: shrink away and disappear (on the server and every client)
func consume() -> void:
	_leave_pile()
	collected = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	var tween := create_tween()
	# Not all the way to zero: a zero-scale basis is singular and Jolt rejects it ("invalid transform... singular")
	tween.tween_property(self, "scale", Vector3.ONE * 0.01, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_callback(queue_free)

## Client: where the server says this prop is now
func set_net_target(pos: Vector3, rot: Vector3) -> void:
	_target_position = pos
	_target_quaternion = Quaternion.from_euler(rot)
	if not _has_target:
		_has_target = true
		global_position = pos
		quaternion = _target_quaternion

## Called by Carrier._push_colliding_bodies instead of apply_impulse. On the server it is a normal impulse; on a
## client the real prop is on the server, so the shove is sent there.
func net_push(impulse: Vector3, rel_position: Vector3) -> void:
	if is_puppet:
		if Globals.world_sync != null:
			Globals.world_sync.send_prop_impulse(String(name), impulse, rel_position)
	else:
		apply_impulse(impulse, rel_position)
