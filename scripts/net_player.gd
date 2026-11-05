extends CharacterBody3D
class_name NetPlayer

## One avatar per connected player, created by the server (see network.gd) and replicated to everybody by the
## MultiplayerSpawner in main.tscn. The node is named after its owner's peer id.
##
## The SERVER has authority over every avatar. The owning client reports its state (position, health, energy) to
## the server with an RPC, the server stores it in the properties below, and the MultiplayerSynchronizer child
## ("Sync", see net_player.tscn) sends them to ALL clients. (A client cannot send synchronizer data straight to
## other clients -- clients only talk to the server.)
## A client never draws its own avatar and it has no collision there: it already has the real Player.
##
## Pushing works exactly like it does for citizens: an avatar is a solid CharacterBody3D that exposes `mass`,
## `velocity` and receive_push(), so Carrier._push_colliding_bodies() shoves it and you recoil. The shove is then
## sent to the player it belongs to (their own Player is what actually moves), via the server.

## Replicated by "Sync". net_position == Vector3.ZERO means "nothing received yet".
var net_position := Vector3.ZERO
var player_name := ""
var net_health := 100
var net_energy := 100
var player_color := Color(1.0, 0.55, 0.2) # this player's colour, chosen on their own client (see Network)

## Used by the push maths (PhysicsPush.mass_of): same as a Player's default.
@export var mass := 50.0
## How quickly remote avatars catch up with the received position (higher = snappier).
@export var smoothing := 15.0
## Seconds between state reports sent by the owning client.
@export var send_interval := 0.05
## Shoves are collected and sent this often, not every physics frame.
@export var push_send_interval := 0.1
@export var nameplate: Nameplate
@export var body_mesh: MeshInstance3D

const MAX_PUSH_SPEED := 15.0 # same cap as Carrier.MAX_IMPACT_SPEED
const SERVER_PUSH_RANGE := 4.0 # server rejects pushes between avatars further apart than this (allows for lag)
const SOLID_LAYER := 4 # collision layer 3, the one citizens are on

var owner_id := 0
var _snapped := false
var _send_timer := 0.0
var _push_timer := 0.0
var _pending_push := Vector3.ZERO
var _prev_position := Vector3.ZERO
var _shown_name := "\n" # impossible name, so the first update always draws
var _shown_health := -1
var _shown_energy := -1
var _shown_color := Color(0, 0, 0, 0) # impossible colour (alpha 0), so the first update always applies
var _last_push_msec := 0 # server side: when this avatar's owner last pushed somebody


func _enter_tree() -> void:
	owner_id = str(name).to_int() # Network names the avatar after its owner's peer id


func _ready() -> void:
	# Not solid until the owner's first position arrives (it would sit at the origin), and never solid for its owner
	collision_layer = 0
	collision_mask = 0


func _is_mine() -> bool:
	return owner_id == multiplayer.get_unique_id()


# --- Reporting state (owner -> server) ---

@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_state(pos: Vector3, health: int, energy: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != owner_id:
		return # only the owner may change their avatar
	net_position = pos
	net_health = clampi(health, 0, 100)
	net_energy = clampi(energy, 0, 100)


# --- Being shoved ---

# Called by Carrier._push_colliding_bodies / PhysicsPush when somebody (or a citizen, or a log) shoves this avatar.
# Collected, then sent to its owner in _flush_push().
func receive_push(dv: Vector3) -> void:
	if _is_mine():
		return # your own avatar has no collision, this should not happen
	_pending_push += dv


func _flush_push(delta: float) -> void:
	_push_timer -= delta
	if _push_timer > 0.0 or _pending_push == Vector3.ZERO:
		return
	_push_timer = push_send_interval
	var dv := _pending_push.limit_length(MAX_PUSH_SPEED)
	_pending_push = Vector3.ZERO
	if multiplayer.is_server():
		apply_push.rpc_id(owner_id, dv) # a citizen or log on the server shoved them
	else:
		request_push.rpc_id(1, dv) # another player shoved them: let the server relay it


# Runs on the server: `self` is the avatar that was pushed, the sender is the one who pushed.
@rpc("any_peer", "call_remote", "reliable")
func request_push(dv: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == owner_id or dv.length() > MAX_PUSH_SPEED + 0.5:
		return
	var pusher := get_parent().get_node_or_null(str(sender)) as NetPlayer
	if pusher == null or pusher.net_position.distance_to(net_position) > SERVER_PUSH_RANGE:
		return # not actually next to each other
	var now := Time.get_ticks_msec()
	if now - pusher._last_push_msec < 50:
		return # flood guard
	pusher._last_push_msec = now
	apply_push.rpc_id(owner_id, dv)


# Runs on the pushed player's own client
@rpc("authority", "call_remote", "reliable")
func apply_push(dv: Vector3) -> void:
	var player := Globals.player as Carrier
	if _is_mine() and player != null:
		player.receive_push(dv)


# --- Damage (server -> victim) ---

# A citizen hit this player. The server decides that (it runs the citizens), the victim's own client applies it
# to their real Player, which is where health lives.
@rpc("authority", "call_remote", "reliable")
func apply_damage(amount: float, source_position: Vector3, knockback_force: float) -> void:
	var player := Globals.player
	if _is_mine() and player != null and player.has_method("take_damage"):
		player.take_damage(amount, source_position, knockback_force)


# --- Per-frame ---

func _physics_process(delta: float) -> void:
	if _is_mine():
		if multiplayer.is_server():
			return
		_send_timer -= delta
		if _send_timer > 0.0:
			return
		_send_timer = send_interval
		var player := Globals.player as Carrier
		if player != null:
			submit_state.rpc_id(1, player.global_position, roundi(player.health), roundi(Globals.player.get("energy")))
		return

	# Somebody else's avatar (on the server too): follow their reported position
	if net_position == Vector3.ZERO:
		return
	if not _snapped:
		_snapped = true
		global_position = net_position
		_prev_position = global_position
		collision_layer = SOLID_LAYER
		return
	if multiplayer.is_server():
		global_position = net_position
	else:
		global_position = global_position.lerp(net_position, 1.0 - exp(-smoothing * delta))
	if delta > 0.0:
		# What Carrier reads as this body's velocity when working out how hard somebody ran into it
		velocity = velocity.lerp((global_position - _prev_position) / delta, 0.3)
	_prev_position = global_position
	_flush_push(delta)


func _process(_delta: float) -> void:
	if multiplayer.is_server():
		return # nothing to draw on the server
	visible = _snapped and not _is_mine()
	if visible:
		_update_nameplate()


func _update_nameplate() -> void:
	if player_color != _shown_color:
		_shown_color = player_color
		# The scene's material is shared by every avatar, so tint a private copy
		var base := body_mesh.get_active_material(0)
		if base is BaseMaterial3D:
			var tinted: BaseMaterial3D = base.duplicate()
			tinted.albedo_color = player_color
			body_mesh.material_override = tinted
	if player_name != _shown_name:
		_shown_name = player_name
		nameplate.set_player_name(player_name if player_name != "" else "...")
	if net_health != _shown_health or net_energy != _shown_energy:
		_shown_health = net_health
		_shown_energy = net_energy
		nameplate.set_stats(net_health, net_energy)
