extends Node
class_name WorldSync

## Keeps the world the same for everybody. The SERVER owns it: the Builder (construction, chopping, props) and the
## citizens only run there. Clients get what happens as messages and ask for what they want to do.
##
##  server -> clients
##    events  broadcast(event, args)   things that changed the world for good (a hut placed, a tree felled, a log
##                                     spawned ...). Reliable, and KEPT in a log: a player who joins later gets the
##                                     whole log replayed, which rebuilds the world they missed. The world as authored
##                                     in main.tscn is identical everywhere, so only changes need sending.
##    state   state(event, args)       things that are just "how it is right now" (progress bars, stockpile, time of
##                                     day). Not logged; a joiner is sent the current values.
##    props   props_state(...)         transforms of logs that are moving (unreliable, ~10x a second)
##  clients -> server
##    req_*                            "build here", "demolish there", "I'm chopping that", "assign this citizen" ...
##                                     The server checks them again (it never trusts a client) and then does them.
##
## Ids (structures, sites, trees) are derived from cells / node paths, so they are the same on every copy.

@export var builder: Builder
@export var day_night: DayNightCycle

const STATE_INTERVAL := 0.1
const SNAPSHOT_CHUNK := 40 # events per message when catching a joiner up (a WebSocket packet is limited in size)
const CLIENT_SEND_INTERVAL := 0.1
const MAX_CHOP_STEP := 0.35 # most chop progress one request may add (the client sends ~10 a second)
const REACH_SLACK := 3.0 # how much further than Builder.PLAYER_WORK_REACH the server tolerates (lag)
const MAX_PROP_IMPULSE := 40.0
const PROP_PUSH_RANGE := 4.0

## The server's answer to a client's req_assign
signal assign_result(ok: bool, reason: String)
## The server's answer to a client's req_prop_grab
signal grab_result(prop_name: String, ok: bool)

# --- server side ---
var _log: Array = [] # every event so far, replayed to late joiners
var _timer := 0.0
var _time_timer := 0.0
var _chop_latest := {} # tree id -> progress waiting for the next broadcast
var _demolish_latest := {} # structure / site id -> demolish progress waiting for the next broadcast
var _site_sent := {}
var _stock_sent := ""
var _props_sent := {} # prop name -> [position, rotation] as last sent
var _carry_facing := {} # peer id -> the way that player last walked (carried fruit is held in front of them)
var _carry_last_pos := {} # peer id -> where their avatar was when the facing was last updated
const GRAB_RANGE := 15.0 # how close a client must be to a prop to grab it (a little looser than reach, for latency)
var _held_by := {} # peer id -> Array of names of the props that client is carrying (oldest first, up to ResourceProp.MAX_CARRY)

# --- client side ---
var _chop_pending := {} # tree id -> progress to add, waiting for the next request
var _demolish_pending := {} # structure / site id -> labour (share of the job) waiting for the next request
var _prop_pending := {} # prop name -> [impulse, relative position] waiting for the next request
var _send_timer := 0.0


func _ready() -> void:
	Globals.world_sync = self
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


## True only once there is a live connection to talk over. A WebSocket peer is assigned as soon as the client starts
## connecting (and a browser takes a while to finish the handshake), but RPCs fail until it is really CONNECTED.
func _online() -> bool:
	var peer := multiplayer.multiplayer_peer
	return not (peer is OfflineMultiplayerPeer) and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _avatar(peer_id: int) -> NetPlayer:
	if Globals.network == null:
		return null
	return Globals.network.net_players.get_node_or_null(str(peer_id)) as NetPlayer


# =====================================================================================================
# Server -> clients
# =====================================================================================================

## Called by the Builder (server only) whenever it changes the world for good.
func broadcast(event: String, args: Array) -> void:
	_log.append([event, args])
	if not multiplayer.get_peers().is_empty():
		evt.rpc(event, args)


func server_chop_progress(id: String, progress: float) -> void:
	_chop_latest[id] = progress


func server_demolish_progress(id: String, progress: float) -> void:
	_demolish_latest[id] = progress


@rpc("authority", "call_remote", "reliable")
func evt(event: String, args: Array) -> void:
	_apply(event, args)


@rpc("authority", "call_remote", "reliable")
func evt_batch(events: Array) -> void:
	for e in events:
		_apply(e[0], e[1], true)


@rpc("authority", "call_remote", "reliable")
func state(event: String, args: Array) -> void:
	match event:
		"chop_progress":
			builder.apply_chop_progress(args[0], args[1])
		"site_state":
			builder.apply_site_state(args[0], args[1], args[2], args[3] if args.size() > 3 else {})
		"demolish_progress":
			builder.apply_demolish_progress(args[0], args[1])
		"stock":
			builder.map.stockpile = args[0]
			builder.map.lifetime_gathered = args[1]
		"time":
			if day_night != null:
				day_night.time_of_day = args[0]


@rpc("authority", "call_remote", "unreliable_ordered")
func props_state(props: Array) -> void:
	for p in props:
		var prop := builder.get_node_or_null(NodePath(p[0])) as ResourceProp
		if prop != null:
			prop.set_net_target(p[1], p[2])


# Applies one event on a client. Safe to repeat (a reconnecting client is caught up again from the start).
# `replay` = part of catching up on the past: no sounds / popups for things that happened long ago.
func _apply(event: String, a: Array, replay: bool = false) -> void:
	match event:
		"place":
			if not builder._cell_ids.has(a[1]):
				builder._place_structure(a[0], a[1], a[2])
		"plant":
			var root: Node = builder.objects_root if builder.objects_root != null else builder
			if root.get_node_or_null(NodePath(a[3])) == null:
				builder._plant_object(builder.structures[a[0]], a[1], a[3], a[2])
		"site_start":
			if not builder._site_cells.has(a[1]) and not builder._cell_ids.has(a[1]):
				builder._start_construction(a[1], a[2], a[0])
		"site_cancel":
			if builder.construction_sites.has(a[0]):
				builder._cancel_construction(a[0])
		"site_complete":
			if builder.construction_sites.has(a[0]):
				builder._complete_construction(a[0])
		"remove":
			builder.clear_chop_progress(a[0])
			if builder.placed_structures.has(a[0]):
				builder.remove_structure_instance(a[0])
		"regrow":
			builder._regrow_tree(a[0], a[1], a[2], a[3]) # a felled tree's stump grew a new tree
		"prop_spawn":
			builder._create_prop(a[0], a[1], a[2], a[3], a[4], true)
		"prop_collected":
			builder.mark_prop_collected(a[0], not replay)
		"prop_consume":
			builder.consume_prop(a[0])
		"zones":
			builder.apply_zones(a[0], a[1]) # tiles designated as a zone (stockpile, gathering...)


func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_send_snapshot(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		builder.release_builder("player_%d" % peer_id)
		_drop_held(peer_id)


# Catches a new player up: replay everything that ever happened, then the current "how it is right now" values.
func _send_snapshot(peer_id: int) -> void:
	for i in range(0, _log.size(), SNAPSHOT_CHUNK):
		evt_batch.rpc_id(peer_id, _log.slice(i, i + SNAPSHOT_CHUNK))
	state.rpc_id(peer_id, "stock", [builder.map.stockpile.duplicate(), builder.map.lifetime_gathered.duplicate()])
	if day_night != null:
		state.rpc_id(peer_id, "time", [day_night.time_of_day])
	for id in builder.gather_progress:
		state.rpc_id(peer_id, "chop_progress", [id, builder.gather_progress[id]])
	for id in builder.demolish_progress:
		state.rpc_id(peer_id, "demolish_progress", [id, builder.demolish_progress[id]])
	for id in builder.construction_sites:
		var site: ConstructionSite = builder.construction_sites[id]
		state.rpc_id(peer_id, "site_state", [id, site.progress, builder.is_site_resourced(id), site.resources_committed.duplicate()])
	var all_props := _moved_props(true)
	if not all_props.is_empty():
		props_state.rpc_id(peer_id, all_props)


func _process(delta: float) -> void:
	if not _online():
		# Not connected (yet / any more): drop what was queued so stale chops aren't sent in a burst on connect
		_chop_pending.clear()
		_demolish_pending.clear()
		_prop_pending.clear()
		return
	if multiplayer.is_server():
		_carry_held_props()
		_server_tick(delta)
	else:
		_client_tick(delta)


func _server_tick(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = STATE_INTERVAL
	if multiplayer.get_peers().is_empty():
		_chop_latest.clear()
		_demolish_latest.clear()
		return

	for id in _chop_latest:
		state.rpc("chop_progress", [id, _chop_latest[id]])
	_chop_latest.clear()
	for id in _demolish_latest:
		state.rpc("demolish_progress", [id, _demolish_latest[id]])
	_demolish_latest.clear()

	for id in builder.construction_sites:
		var site: ConstructionSite = builder.construction_sites[id]
		var resourced := builder.is_site_resourced(id)
		var key := "%.3f|%s|%s" % [site.progress, resourced, str(site.resources_committed)]
		if _site_sent.get(id, "") != key:
			_site_sent[id] = key
			state.rpc("site_state", [id, site.progress, resourced, site.resources_committed.duplicate()])
	for id in _site_sent.keys():
		if not builder.construction_sites.has(id):
			_site_sent.erase(id)

	var stock_key := str(builder.map.stockpile) + str(builder.map.lifetime_gathered)
	if stock_key != _stock_sent:
		_stock_sent = stock_key
		state.rpc("stock", [builder.map.stockpile.duplicate(), builder.map.lifetime_gathered.duplicate()])

	var moved := _moved_props(false)
	if not moved.is_empty():
		props_state.rpc(moved)

	_time_timer += STATE_INTERVAL
	if _time_timer >= 5.0 and day_night != null:
		_time_timer = 0.0
		state.rpc("time", [day_night.time_of_day])


# Props that moved since they were last sent (all of them if `full`)
func _moved_props(full: bool) -> Array:
	var out := []
	for node in get_tree().get_nodes_in_group("resource_prop"):
		var prop := node as ResourceProp
		if prop == null or prop.is_puppet:
			continue
		var pos := prop.global_position
		var rot := prop.rotation
		var last = _props_sent.get(prop.name)
		if full or last == null or last[0].distance_squared_to(pos) > 0.0001 or last[1].distance_squared_to(rot) > 0.0001:
			_props_sent[prop.name] = [pos, rot]
			out.append([String(prop.name), pos, rot])
	return out


# =====================================================================================================
# Clients -> server
# =====================================================================================================

func _client_tick(delta: float) -> void:
	_send_timer -= delta
	if _send_timer > 0.0:
		return
	_send_timer = CLIENT_SEND_INTERVAL
	for id in _chop_pending:
		req_chop.rpc_id(1, id, _chop_pending[id])
	_chop_pending.clear()
	for id in _demolish_pending:
		req_demolish_progress.rpc_id(1, id, _demolish_pending[id])
	_demolish_pending.clear()
	for prop_name in _prop_pending:
		var p: Array = _prop_pending[prop_name]
		req_prop_impulse.rpc_id(1, prop_name, p[0], p[1])
	_prop_pending.clear()


## Client: this much chopping happened (Builder.add_chop_progress); sent in the next batch
func client_chop(id: String, amount: float) -> void:
	_chop_pending[id] = _chop_pending.get(id, 0.0) + amount


## Client: this much demolishing labour was put in (Builder.add_demolish_progress); sent in the next batch
func client_demolish(id: String, amount: float) -> void:
	_demolish_pending[id] = _demolish_pending.get(id, 0.0) + amount


## Client: the player shoved a prop (Carrier -> ResourceProp.net_push); sent in the next batch
func send_prop_impulse(prop_name: String, impulse: Vector3, rel_position: Vector3) -> void:
	var existing: Array = _prop_pending.get(prop_name, [Vector3.ZERO, rel_position])
	_prop_pending[prop_name] = [existing[0] + impulse, rel_position]


func req_build(structure_index: int, cell: Vector3i, rotation_y: float, world_position: Vector3) -> void:
	if _online():
		_req_build.rpc_id(1, structure_index, cell, rotation_y, world_position)

func req_assign_builder(site_id: String) -> void:
	if _online():
		_req_assign_builder.rpc_id(1, site_id)

func req_release_builder() -> void:
	if _online():
		_req_release_builder.rpc_id(1)

func req_assign(kind: int, citizen_id: String, target_id: String) -> void:
	if _online():
		_req_assign.rpc_id(1, kind, citizen_id, target_id)

## "send this citizen to that spot": the player clicked the ground with a citizen selected
func req_go_to(citizen_id: String, world_position: Vector3) -> void:
	if _online():
		_req_go_to.rpc_id(1, citizen_id, world_position)


# --- Handlers (run on the server) ---

@rpc("any_peer", "call_remote", "reliable")
func _req_build(structure_index: int, cell: Vector3i, rotation_y: float, world_position: Vector3) -> void:
	if multiplayer.is_server():
		builder.perform_build(structure_index, cell, rotation_y, world_position)

func req_zones(cells: Array, zone: int) -> void:
	if _online():
		_req_zones.rpc_id(1, cells, zone)

@rpc("any_peer", "call_remote", "reliable")
func _req_zones(cells: Array, zone: int) -> void:
	if multiplayer.is_server():
		builder.perform_paint_zones(cells, zone)


@rpc("any_peer", "call_remote", "reliable")
func req_demolish_progress(id: String, amount: float) -> void:
	if not multiplayer.is_server() or not builder.can_demolish(id):
		return
	var avatar := _avatar(multiplayer.get_remote_sender_id())
	if avatar == null:
		return
	if Builder.flat_distance(avatar.net_position, builder.get_demolish_position(id)) > Builder.PLAYER_WORK_REACH + REACH_SLACK:
		return # not actually next to it
	builder.add_demolish_progress(id, clampf(amount, 0.0, MAX_CHOP_STEP))


@rpc("any_peer", "call_remote", "reliable")
func req_chop(id: String, amount: float) -> void:
	if not multiplayer.is_server() or not builder.placed_structures.has(id):
		return
	var sender := multiplayer.get_remote_sender_id()
	var avatar := _avatar(sender)
	if avatar == null:
		return
	var pos: Vector3 = builder.placed_structures[id]["position"]
	if Builder.flat_distance(avatar.net_position, pos) > builder.get_gather_reach(id) + REACH_SLACK:
		return # not actually next to it
	var result: Dictionary = builder.add_chop_progress(id, clampf(amount, 0.0, MAX_CHOP_STEP))
	var bonus: float = result.get("hunger_bonus", 0.0)
	if result.get("completed", false) and bonus > 0.0:
		grant_hunger.rpc_id(sender, bonus) # the player's hunger lives on their own client


@rpc("authority", "call_remote", "reliable")
func grant_hunger(amount: float) -> void:
	var player := Globals.player
	if player != null:
		player.hunger += amount


@rpc("any_peer", "call_remote", "reliable")
func _req_assign_builder(site_id: String) -> void:
	if multiplayer.is_server():
		builder.assign_builder_to_site("player_%d" % multiplayer.get_remote_sender_id(), site_id)


@rpc("any_peer", "call_remote", "reliable")
func _req_release_builder() -> void:
	if multiplayer.is_server():
		builder.release_builder("player_%d" % multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func _req_assign(kind: int, citizen_id: String, target_id: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var citizen = null
	for c in builder.citizens:
		if is_instance_valid(c) and c.data != null and c.data.id == citizen_id:
			citizen = c
			break
	var ok := false
	if citizen != null:
		match kind:
			Action.Kind.ASSIGN_BUILD_TASK:
				ok = PolicyEngine.execute(Action.new_assign_build_task(), citizen, target_id)
			Action.Kind.ASSIGN_GATHER:
				ok = PolicyEngine.execute(Action.new_assign_gather(), citizen, target_id)
			Action.Kind.ASSIGN_HAUL:
				ok = PolicyEngine.execute(Action.new_assign_haul(), citizen, target_id)
			Action.Kind.ASSIGN_HOUSING:
				if builder.buildings.has(target_id):
					ok = PolicyEngine.execute(Action.new_assign_housing(), citizen, builder.buildings[target_id])
			Action.Kind.ASSIGN_JOB:
				if builder.buildings.has(target_id):
					ok = PolicyEngine.execute(Action.new_assign_job(), citizen, builder.buildings[target_id])
	answer_assign.rpc_id(sender, ok, PolicyEngine.last_failure)


@rpc("any_peer", "call_remote", "reliable")
func _req_go_to(citizen_id: String, world_position: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var ok := false
	if world_position.is_finite():
		for c in builder.citizens:
			if is_instance_valid(c) and c.data != null and c.data.id == citizen_id:
				ok = PolicyEngine.execute(Action.new_go_to_position(), c, world_position)
				break
	answer_assign.rpc_id(sender, ok, PolicyEngine.last_failure)


@rpc("authority", "call_remote", "reliable")
func answer_assign(ok: bool, reason: String) -> void:
	assign_result.emit(ok, reason)


## Client: ask the server to pick up (want = true) or put down (false) a small prop, see Player._update_grab_online
func req_prop_grab(prop_name: String, want: bool) -> void:
	if _online():
		_req_prop_grab.rpc_id(1, prop_name, want)

@rpc("any_peer", "call_remote", "reliable")
func _req_prop_grab(prop_name: String, want: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not want:
		_drop_held(sender, prop_name)
		return
	var prop := builder.get_node_or_null(NodePath(prop_name)) as ResourceProp
	var avatar := _avatar(sender)
	var carried: Array = _held_by.get(sender, [])
	var ok := prop != null and avatar != null and _has_room_for(carried, prop) and not carried.has(prop.name) \
			and prop.can_be_grabbed() and avatar.net_position.distance_to(prop.global_position) <= GRAB_RANGE
	if ok:
		prop.grab()
		carried.append(prop.name)
		_held_by[sender] = carried
	answer_prop_grab.rpc_id(sender, prop_name, ok)

@rpc("authority", "call_remote", "reliable")
func answer_prop_grab(prop_name: String, ok: bool) -> void:
	grab_result.emit(prop_name, ok)

## Server: does a client already carrying the props named in `carried` have room for `prop`? (small items stack, a log
## needs free arms and only MAX_CARRY_LOGS fit, see ResourceProp.has_room_for)
func _has_room_for(carried: Array, prop: ResourceProp) -> bool:
	var props: Array = []
	for held_name in carried:
		var held := builder.get_node_or_null(NodePath(String(held_name))) as ResourceProp
		if held != null:
			props.append(held)
	return ResourceProp.has_room_for(props, prop)

## Server: let go of what `peer_id` is carrying -- just the named prop, or everything when no name is given
## (they dropped it, or left)
func _drop_held(peer_id: int, prop_name: String = "") -> void:
	var carried: Array = _held_by.get(peer_id, [])
	# Names are kept as StringName (prop.name) but arrive from the RPC as String: Array.has() treats those as different, so
	# compare like with like or the drop silently matches nothing and the fruit stays frozen over the carrier's head
	var to_drop: Array = carried.duplicate() if prop_name == "" else ([StringName(prop_name)] if carried.has(StringName(prop_name)) else [])
	for dropped in to_drop:
		carried.erase(dropped)
		var prop := builder.get_node_or_null(NodePath(String(dropped))) as ResourceProp
		if prop != null and prop.held and not prop.collected:
			prop.release()
	if carried.is_empty():
		_held_by.erase(peer_id)
	else:
		_held_by[peer_id] = carried

## Server: every frame, keep each carried prop floating over its carrier (the prop is frozen, so it doesn't move itself)
func _carry_held_props() -> void:
	for peer_id in _held_by.keys():
		var avatar := _avatar(peer_id)
		if avatar == null:
			_drop_held(peer_id)
			continue
		var carried: Array = _held_by.get(peer_id, [])
		# Facing isn't replicated: use the way the avatar last moved
		var last_pos: Vector3 = _carry_last_pos.get(peer_id, avatar.net_position)
		var moved := Vector3(avatar.net_position.x - last_pos.x, 0.0, avatar.net_position.z - last_pos.z)
		if moved.length() > 0.03:
			_carry_facing[peer_id] = moved.normalized()
			_carry_last_pos[peer_id] = avatar.net_position
		elif not _carry_last_pos.has(peer_id):
			_carry_last_pos[peer_id] = avatar.net_position
		var forward: Vector3 = _carry_facing.get(peer_id, Vector3.FORWARD)
		var slot := 0
		for prop_name in carried.duplicate():
			var prop := builder.get_node_or_null(NodePath(String(prop_name))) as ResourceProp
			if prop == null or prop.collected:
				carried.erase(prop_name) # collected (or gone): the stack closes up
				continue
			prop.carry_to(avatar.net_position + ResourceProp.carry_offset(slot, forward), forward)
			slot += 1
		if carried.is_empty():
			_held_by.erase(peer_id)
			_carry_facing.erase(peer_id)
			_carry_last_pos.erase(peer_id)
		else:
			_held_by[peer_id] = carried


@rpc("any_peer", "call_remote", "unreliable_ordered")
func req_prop_impulse(prop_name: String, impulse: Vector3, rel_position: Vector3) -> void:
	if not multiplayer.is_server() or impulse.length() > MAX_PROP_IMPULSE:
		return
	var prop := builder.get_node_or_null(NodePath(prop_name)) as ResourceProp
	var avatar := _avatar(multiplayer.get_remote_sender_id())
	if prop == null or prop.is_puppet or avatar == null:
		return
	if avatar.net_position.distance_to(prop.global_position) > PROP_PUSH_RANGE:
		return # not actually next to it
	prop.apply_impulse(impulse, rel_position)
