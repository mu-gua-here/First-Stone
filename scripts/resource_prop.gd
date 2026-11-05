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
# (The collection radius is Builder.stockpile_radius.)
const SETTLE_SPEED_THRESHOLD := 0.4
const PUPPET_SMOOTHING := 15.0

var collected: bool = false
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
	if collected:
		return # already on the woodpile (frozen)
	PhysicsPush.solve_rigid_contacts(self)
	var owning_builder = get_meta("builder", null)
	if owning_builder == null:
		return
	var stock: Vector3 = owning_builder.stockpile_position
	var flat_dist := Vector2(global_position.x - stock.x, global_position.z - stock.z).length()
	if flat_dist <= owning_builder.stockpile_radius and linear_velocity.length() < SETTLE_SPEED_THRESHOLD:
		_collect()

func _collect() -> void:
	collected = true
	var owning_builder = get_meta("builder", null)
	var resource_type: String = get_meta("resource_type", "")
	var amount: int = get_meta("amount", 0)
	print("Stockpile: collected %d %s" % [amount, resource_type])
	if owning_builder != null and resource_type != "" and amount > 0:
		owning_builder.deposit_resources({resource_type: amount})
	if Globals.hosting_world and Globals.world_sync != null:
		Globals.world_sync.broadcast("prop_collected", [String(name)])
	if owning_builder != null:
		owning_builder.on_prop_collected(self) # "+1 Wood", the board bounces, a thunk
		_stack_on_pile(owning_builder)

# The log leaves the loose-physics world and flies onto its place on the woodpile (Builder.claim_stack_slot).
# Frozen as a kinematic body: moving it with a tween still shows up on every client through the usual prop updates.
func _stack_on_pile(owning_builder) -> void:
	var slot: Transform3D = owning_builder.claim_stack_slot(self)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	var tween := create_tween()
	tween.tween_property(self, "global_transform", slot, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## The wood this log stood for went into a building: shrink away and disappear (on the server and every client)
func consume() -> void:
	collected = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
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
