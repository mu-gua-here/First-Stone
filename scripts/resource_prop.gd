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
const SETTLE_SPEED_THRESHOLD := 0.4
const PUPPET_SMOOTHING := 15.0

const CARRY_HEIGHT := 1.9 # the first carried item floats this far above its carrier's origin (player.gd, world_sync.gd)
const CARRY_SPACING := 0.3 # each further carried item sits this much higher, forming a stack overhead
const MAX_CARRY := 10 # most small items one player can carry at a time

## Where the index-th carried item (0 = first grabbed) floats, relative to its carrier's position
static func carry_offset(index: int) -> Vector3:
	return Vector3.UP * (CARRY_HEIGHT + index * CARRY_SPACING)

var collected: bool = false # set once the prop was used up (consume()): it no longer counts or moves
var in_pile := false # a log that has tidied itself onto the woodpile: frozen in its slot until somebody takes it
var _taken := false # taken off the pile: it won't tidy itself back until it has been pushed out of the stockpile block
var _tween: Tween
var _pile_layer := 1
var _pile_mask := 1
var held: bool = false # carried overhead by the player (press E, see player.gd) -- frozen, not simulated
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

func _physics_process(delta: float) -> void:
	if is_puppet:
		if _has_target:
			var t := 1.0 - exp(-PUPPET_SMOOTHING * delta)
			global_position = global_position.lerp(_target_position, t)
			quaternion = quaternion.slerp(_target_quaternion, t)
		return
	if not held and not collected and not in_pile:
		PhysicsPush.solve_rigid_contacts(self) # loose logs and fruit are shoved around; nothing is locked until it is on the pile
	if held or collected or in_pile:
		return
	var owning_builder = get_meta("builder", null)
	if owning_builder == null or not owning_builder.is_stacked_type(String(get_meta("resource_type", ""))):
		return # fruit just lies where it lands
	if not owning_builder.is_in_stockpile(global_position):
		_taken = false # out of the block: free to tidy itself onto the pile again if it is pushed back in
	elif not _taken and is_settled():
		_stack_on_pile(owning_builder)

## True once this prop is lying still (not carried, not shrinking away): Builder counts a stockpile's contents from
## the settled props inside it, so a log that is flying around or knocked out of the block simply stops counting.
func is_settled() -> bool:
	return not held and not collected and not is_puppet and (sleeping or linear_velocity.length() < SETTLE_SPEED_THRESHOLD)

# A log pushed into the stockpile tidies itself onto the woodpile (Builder.claim_stack_slot): it flies to its slot without
# colliding (so it can't knock the other logs about) and is then frozen there as a solid body. take_from_pile() frees it.
func _stack_on_pile(owning_builder) -> void:
	in_pile = true
	var slot: Transform3D = owning_builder.claim_stack_slot(self)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	var layer := collision_layer
	var mask := collision_mask
	_pile_layer = layer
	_pile_mask = mask
	collision_layer = 0
	collision_mask = 0
	_tween = create_tween()
	_tween.tween_property(self, "global_transform", slot, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(func() -> void:
		if is_instance_valid(self):
			collision_layer = layer
			collision_mask = mask)

## Server / offline: somebody took this log off the pile. It is released as a loose log and sent flying away from the pile
## towards `towards` (the thief), and stays loose until it has been pushed out of the stockpile block.
func take_from_pile(towards: Vector3) -> void:
	if not in_pile:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
		collision_layer = _pile_layer # (a log taken mid-flight: give it its normal collision back)
		collision_mask = _pile_mask
	in_pile = false
	_taken = true
	freeze = false
	var away := towards - global_position
	away.y = 0.0
	apply_central_impulse(away.normalized() * mass * 4.0 + Vector3.UP * mass * 2.0)

## Small items (fruit) are picked up with E instead of shoved around: the player carries it overhead,
## and drops it again with Q (or just leaves it lying in the food stockpile, which counts it as usual).
## Only the simulating copy (offline / host) can be grabbed; a client asks the server (WorldSync.req_prop_grab).
func can_be_grabbed() -> bool:
	if collected or held or is_puppet:
		return false
	var owning_builder = get_meta("builder", null)
	return owning_builder == null or not owning_builder.is_stacked_type(String(get_meta("resource_type", "")))

func grab() -> void:
	held = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true

func release(throw_velocity: Vector3 = Vector3.ZERO) -> void:
	held = false
	freeze = false
	linear_velocity = throw_velocity

## The wood this log stood for went into a building: shrink away and disappear (on the server and every client)
func consume() -> void:
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
