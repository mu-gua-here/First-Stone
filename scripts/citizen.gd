extends Carrier

# Movement settings
@export var BASE_SPEED = 4.0
@export var BOUNCE_HEIGHT := 4.0
var actual_speed: float
var wander_timer: float = 0.0
var idle_timer: float = 0.0

# Chase settings
var is_chasing_player: bool = false
var chase_repath_timer := 0.0
const CHASE_REPATH_INTERVAL := 0.25

# Distance a citizen needs to be from a gatherable/build cell to start contributing
const WORK_REACH := 1.5

# Energy per second spent swimming (the player's move_energy)
const SWIM_ENERGY := 0.1

# Health lost per second while energy is below 30 (the player's hunger_dmg)
@export var hunger_dmg := 0.2

## Below this much health & energy the player starts to slow down (and jump / swim weaker), reaching a standstill at 0.
## Stacks multiplicatively with the low-energy slowdown, so being low on both is much worse than either.
@export var slow_below_health := 50.0
@export var slow_below_energy := 50.0

# Attack settings (only relevant while is_chasing_player is true)
@export var attack_damage: float = 10.0
@export var attack_cooldown_time: float = 1.0  # seconds between hits on the same target
@export var attack_knockback_force: float = 0.5
var attack_cooldown: float = 0.0
# Horizontal velocity the citizen wants this frame (from navigation/avoidance). Velocity steers toward it
# (see Carrier.steer_horizontal), so an impact can be steered against instead of being overwritten.
var _wanted_velocity := Vector3.ZERO

@onready var nav_agent = $NavigationAgent3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

@export var data: CitizenData

# --- Multiplayer (see network.gd) ---
# Only the SERVER runs a citizen's AI. On a client the copy spawned by the MultiplayerSpawner is a PUPPET: it
# skips all the AI below and just follows the net_* values, which the server fills in every physics frame and
# the "Sync" MultiplayerSynchronizer (citizen.tscn) replicates. The puppet copies them into `data` / `health`,
# so everything that reads a citizen (the selection panel, happiness colour) works unchanged.
var is_puppet := false
var net_position := Vector3.ZERO # Vector3.ZERO = nothing received yet
var net_name := ""
var net_id := ""
var net_age := 0
var net_job := ""
var net_happiness := 50.0
var net_energy := 100.0
var net_health := 100.0
var net_hostile := false
const PUPPET_SMOOTHING := 15.0
const ATTACK_RANGE := 1.3 # flat distance at which a chasing citizen hits a player (two capsule radii and a bit)
const PUSH_RPC_INTERVAL := 0.1 # a client's player shoving a puppet reports it to the server at most this often
var _push_rpc_cooldown := 0.0

var happiness_material: StandardMaterial3D

var housing_check_timer: float = 0.0
const HOUSING_CHECK_INTERVAL := 2.0 # how often to re-derive housing status from builder.buildings
var _has_housing: bool = false

var is_gathering: bool = false
var _warned_unreachable := false
var _debug_gather_timer := 0.0
const NO_ID := Builder.NO_ID
var gather_target_id: String = NO_ID
var gather_filter: String = "" # resource type to look for when picking the next tree ("" = anything gatherable)

# Jobs: an employed citizen keeps themselves busy (see _update_job)
const JOB_CHECK_INTERVAL := 3.0
var _job_timer := 0.0

# Building -- entered only via explicit assignment (manual click for now)
var is_building: bool = false
var build_target_id: String = NO_ID

# Pushing a gathered resource prop back toward the stockpile (Builder.stockpile_position)
# after a gather completes. The citizen first walks round to the far side of the prop, then
# walks at the stockpile -- shoving the prop ahead of them.
var is_pushing: bool = false
var push_target: RigidBody3D = null
var push_repath_timer: float = 0.0
const PUSH_REPATH_INTERVAL := 0.3
const PUSH_STANCE_DISTANCE := 0.7 # how far behind the prop to stand before shoving
const PUSH_LATERAL_TOLERANCE := 0.5 # how far off the prop-to-stockpile line still counts as "lined up"

func _init() -> void:
	kill_height = -10.0 # citizens die this far below the world (the player's is Carrier's default)

func _ready():
	if data == null:
		data = CitizenData.new()
	
	is_puppet = not multiplayer.is_server()
	add_to_group("citizen")
	_carrier_ready() # sets `builder` (see carrier.gd)
	
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	
	# Create the override material
	happiness_material = StandardMaterial3D.new()
	mesh_instance.set_surface_override_material(0, happiness_material)
	update_happiness_color()
	
	if is_puppet:
		# No AI / navigation here: wait for the server's first position, then follow it (see _puppet_process)
		visible = net_position != Vector3.ZERO
		if visible:
			global_position = net_position
		return
	
	# call_deferred only defers the CALL
	_request_initial_wander()

func _request_initial_wander() -> void:
	# A single await get_tree().physics_frame isn't reliably enough -- if the
	# NavigationRegion3D is still registering its polygons with the server around the same
	# time citizens spawn (both happening during the scene's initial _ready() pass), the
	# map's first sync can land on a later frame. map_get_iteration_id() is 0 until the map
	# has synced at least once, so poll it instead of guessing a frame count.
	var map_rid = nav_agent.get_navigation_map()
	while NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		await get_tree().physics_frame
		if not is_instance_valid(self):
			return
	set_new_destination(_wander_target(100.0))

func _exit_tree():
	if is_puppet:
		return # the server owns the Builder's records of this citizen
	if builder and is_instance_valid(builder) and data:
		builder.release_citizen(data.id)

func _physics_process(delta):
	if is_puppet:
		_puppet_process(delta)
		return
	if is_dead:
		return # died this frame, waiting to be freed (see Carrier._on_death)
	_apply_gravity(delta) # see carrier.gd -- gradual sink in water, normal gravity on land
	_swim_toward_surface(delta) # tread water like the player instead of sinking to the bottom
	var in_fluid := is_in_fluid()
	if in_fluid:
		data.energy -= SWIM_ENERGY * delta # swimming is tiring, same as for the player
		
	var energy_mult := clampf(smoothstep(0.0, 1.0, data.energy * 0.02), 0.2, 1.0)
	var health_mult := clampf(smoothstep(0.0, 1.0, health / maxf(slow_below_health, 0.001)), 0.2, 1.0)
	var vitality_mult := energy_mult * health_mult
	
	# (gravity / sinking is applied above by _apply_gravity())
	
	# Periodically re-check whether this citizen is currently housed.
	# NOTE: job assignment is intentionally NOT auto-retried here -- per the
	# plan, manual (CitizenSelector) or policy (PolicyEngine) assignment is the only
	# path to a job right now.
	housing_check_timer -= delta
	if housing_check_timer <= 0.0:
		housing_check_timer = HOUSING_CHECK_INTERVAL
		_refresh_housing_status()
	
	_update_gathering(delta)
	_update_building(delta)
	_update_pushing(delta)
	_update_job(delta)
	
	# Update citizen stats
	if data.job == "":
		data.job_satisfaction -= 10 * delta
	else:
		data.job_satisfaction += randf_range(0.0, 0.01)
	
	data.job_satisfaction = clamp(data.job_satisfaction, 0.0, 100.0)
	
	# Housing satisfaction eases toward 100 if housed, 0 if not
	var housing_target = 100.0 if _has_housing else 0.0
	data.housing_satisfaction = move_toward(data.housing_satisfaction, housing_target, delta * 20.0)
	
	data.happiness = clamp(50 - (100 - data.energy) * 0.005 + (data.job_satisfaction * 0.01 if data.job != "" else -data.job_satisfaction * 0.01) + (data.housing_satisfaction - 50.0) * 0.1, 0, 100)
	update_happiness_color()
	
	actual_speed = BASE_SPEED + (100 - data.happiness) * 0.01
	nav_agent.max_speed = actual_speed
	
	if data.happiness < 0.1:
		is_chasing_player = true
	elif data.happiness > 10.0:
		is_chasing_player = false
	
	if is_chasing_player:
		chase_repath_timer -= delta
		if chase_repath_timer <= 0.0:
			chase_repath_timer = CHASE_REPATH_INTERVAL
			var target := _nearest_player()
			if target != null:
				set_new_destination(target.net_position)
		
		# Tick down attack cooldown
		if attack_cooldown > 0.0:
			attack_cooldown -= delta

	# Wander timer (skipped while actively gathering, building, or pushing)
	if not is_gathering and not is_building and not is_pushing:
		wander_timer -= delta
		if is_on_floor() and wander_timer > 0:
			if data.energy > 0.0:
				velocity.y = BOUNCE_HEIGHT
		else:
			wander_timer = randf_range(0, 2) * (100 - data.happiness)
			idle_timer -= delta
			if idle_timer <= 0:
				set_new_destination(_wander_target(100.0))
				idle_timer = clamp(randf_range(0.0, data.happiness * 0.2), 5.0, 20.0)
	else:
		# Working: the walk to the tree / site / prop used to have NO hop at all (only wandering did), which
		# looked like the citizen had frozen. Hop while travelling, stand still once at the work spot.
		if is_on_floor() and data.energy > 0.0 and not nav_agent.is_navigation_finished() and not _is_at_gather_target():
			velocity.y = BOUNCE_HEIGHT
	
	if not nav_agent.is_navigation_finished() and data.energy > 0.0:
		# Guards against the same "Invalid navigation index" error for targets that aren't
		# wander points (chase, gather, push) -- those come from real object positions, so
		# _wander_target()'s snapping doesn't cover them. If the river (or anything else)
		# splits the navmesh into disconnected pieces, a target on the far side is legitimately
		# unreachable and querying it every frame is what spams the engine error. Just coast
		# to a stop instead of repeatedly asking for a path that will never exist.
		if not nav_agent.is_target_reachable():
			if is_gathering and not _warned_unreachable:
				_warned_unreachable = true
				push_warning("Citizen %s: gather target %s is not reachable on the navmesh (target %s) -- standing still." % [name, gather_target_id, nav_agent.target_position])
			_wanted_velocity = Vector3.ZERO
		else:
			var next = nav_agent.get_next_path_position()
			var direction = (next - global_position).normalized()
			var desired_velocity := Vector3(direction.x * actual_speed, 0.0, direction.z * actual_speed)
			if nav_agent.avoidance_enabled:
				nav_agent.set_velocity(desired_velocity)  # triggers velocity_computed -> _wanted_velocity
			else:
				_wanted_velocity = desired_velocity
	else:
		_wanted_velocity = Vector3.ZERO
	
	# Slow citizen if citizen need food
	var wanted := _wanted_velocity
	if data.energy < slow_below_energy:
		wanted *= vitality_mult
	
	data.energy -= (data.metabolism + data.metabolism * Vector3(velocity.x, 0, velocity.z).length()) * delta
	data.energy = clamp(data.energy, 0, 100)
	
	# Starving eats away at health, same rule as the player (see player.gd)
	if data.energy < 30.0:
		health -= hunger_dmg * delta
	
	steer_horizontal(wanted, delta)
	_before_slide()
	var fall_speed := -velocity.y # captured before move_and_slide() zeroes it on landing
	move_and_slide()
	_apply_fall_damage(fall_speed, in_fluid) # see carrier.gd -- same rule as the player
	_push_colliding_bodies() # shared with player.gd, see carrier.gd -- must run AFTER move_and_slide() to read this frame's collisions
	
	# Real physical collision check — did we actually touch the player this frame?
	if is_chasing_player and attack_cooldown <= 0.0:
		var target := _nearest_player()
		if target != null and Vector2(target.net_position.x - global_position.x, target.net_position.z - global_position.z).length() <= ATTACK_RANGE \
				and absf(target.net_position.y - global_position.y) < 1.8:
			# The hit is applied by the victim's own client (their Player lives there)
			target.apply_damage.rpc_id(target.owner_id, attack_damage, global_position, attack_knockback_force)
			attack_cooldown = attack_cooldown_time
	
	_publish_net_state()
		
	_check_out_of_world() # falling out of the world kills, see carrier.gd

func _on_velocity_computed(safe_velocity: Vector3):
	_wanted_velocity = Vector3(safe_velocity.x, 0.0, safe_velocity.z)

# Derives housing status directly from builder.buildings (the source of
# truth for occupancy) instead of a since-removed has_housing_for() call.
# A citizen is housed if their id appears in any BuildingInstance's residents.
func _refresh_housing_status() -> void:
	if builder == null:
		return
	_has_housing = false
	for instance in builder.buildings.values():
		if data.id in instance.residents:
			_has_housing = true
			break
	
	# Citizens without housing/a job just wander until the player assigns them
	# something via CitizenSelector -> PolicyEngine (or a future policy).

func _start_gathering() -> void:
	var id = builder.get_nearest_gatherable(global_position, gather_filter)
	if id == NO_ID:
		return
	_start_gathering_at(id)

func _start_gathering_at(id: String) -> void:
	# Targeted version -- a specific tree assigned by the player or PolicyEngine.
	# Also used by _start_gathering() after it resolves the nearest id.
	_warned_unreachable = false
	gather_target_id = id
	is_gathering = true
	# Trees are hand-placed in main.tscn at y = 4 (origin height), which is nowhere near the navmesh, so the
	# agent called them unreachable (target_desired_height). Aim at the closest navmesh point instead.
	var tree_pos: Vector3 = builder.get_structure_position(id)
	set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), tree_pos))

# True while gathering and already within WORK_REACH of the tree (so no more hopping, the citizen is chopping)
func _is_at_gather_target() -> bool:
	if not is_gathering or builder == null:
		return false
	var p: Vector3 = builder.get_structure_position(gather_target_id)
	if p == Vector3.INF:
		return false
	return global_position.distance_to(Vector3(p.x, global_position.y, p.z)) <= WORK_REACH

func _update_gathering(delta: float) -> void:
	if not is_gathering:
		return
	if builder == null:
		is_gathering = false
		return
	
	# Tree already destroyed, go somewhere else
	var structure_index = builder.get_structure_index(gather_target_id)
	if structure_index < 0 or structure_index >= builder.structures.size() or not builder.structures[structure_index].gatherable:
		is_gathering = false
		_start_gathering()
		return
	
	# Still walking -- no progress, UNLESS already physically close enough
	# (guards against is_navigation_finished() never triggering -- see WORK_REACH).
	var target_pos = builder.get_structure_position(gather_target_id)
	var target_world_pos = Vector3(target_pos.x, global_position.y, target_pos.z)
	var close_enough = global_position.distance_to(target_world_pos) <= WORK_REACH
	if OS.is_debug_build() and not close_enough:
		_debug_gather_timer -= delta
		if _debug_gather_timer <= 0.0:
			_debug_gather_timer = 1.0
			print("[gather-debug] %s pos=%s nav_target=%s final=%s finished=%s reachable=%s flat_dist=%.2f next=%s wanted=%s vel=%s energy=%.1f" % [
				name, global_position, nav_agent.target_position, nav_agent.get_final_position(), nav_agent.is_navigation_finished(),
				nav_agent.is_target_reachable(), Vector2(global_position.x - target_pos.x, global_position.z - target_pos.z).length(),
				nav_agent.get_next_path_position(), _wanted_velocity, velocity, data.energy])
	if not nav_agent.is_navigation_finished() and not close_enough:
		return
	
	# Arrived -- contribute labor toward the shared, persisted chop progress.
	var gather_time = builder.structures[structure_index].gather_time
	var energy_required = builder.structures[structure_index].energy_required
	data.energy = clamp(data.energy - energy_required * delta, 0.0, 100.0)
	# add_chop_progress returns a Dictionary (not a bool) -- it's ALWAYS
	# truthy since it always has keys, even mid-chop. Must check the
	# "completed" key explicitly, not the dict itself.
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / gather_time)
	if result.get("completed", false):
		is_gathering = false
		var energy_bonus: float = result.get("energy_bonus", 0.0)
		if energy_bonus > 0.0:
			data.energy = clamp(data.energy + energy_bonus, 0.0, 100.0)
		_start_pushing_nearest_prop()

# Called once a gather finishes. Rather than carrying anything, the citizen
# walks up to the nearest uncollected resource prop (spawned incrementally
# during the gather -- see Builder.add_chop_progress()) and leans on it,
# nudging it toward the spawn/stockpile point via the shared push logic in
# carrier.gd. If there's nothing to push (someone/something else already
# pushed every prop in), it just goes back to gathering.
func _start_pushing_nearest_prop() -> void:
	var nearest: RigidBody3D = null
	var nearest_dist := INF
	for prop in get_tree().get_nodes_in_group("resource_prop"):
		if not is_instance_valid(prop) or prop.collected:
			continue # already piled at the stockpile -- nothing left to push
		var d = global_position.distance_squared_to(prop.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = prop
	if nearest == null:
		_start_gathering()
		return
	is_pushing = true
	push_target = nearest
	push_repath_timer = 0.0
	set_new_destination(_push_destination())

func _update_pushing(delta: float) -> void:
	if not is_pushing:
		return
	# Prop already got collected (by us or anyone else nudging it in) --
	# resource_prop.gd no longer frees itself on collection (logs stay
	# visible forever as the stockpile pile -- see resource_prop.gd), so
	# check its `collected` flag instead of instance validity.
	if push_target == null or not is_instance_valid(push_target) or push_target.collected:
		is_pushing = false
		push_target = null
		_start_gathering()
		return
	push_repath_timer -= delta
	if push_repath_timer <= 0.0:
		push_repath_timer = PUSH_REPATH_INTERVAL
		set_new_destination(_push_destination())

# Where to walk while pushing: round the far side of the prop first, then straight at the
# stockpile once lined up behind it, so the walk itself shoves the prop home.
func _push_destination() -> Vector3:
	var stock: Vector3 = builder.stockpile_position
	var prop_pos := push_target.global_position
	var toward := Vector3(stock.x - prop_pos.x, 0.0, stock.z - prop_pos.z)
	if toward.length() < 0.05:
		return prop_pos
	toward = toward.normalized()

	var rel := global_position - prop_pos
	rel.y = 0.0
	var along := rel.dot(toward) # negative = we are on the far side from the stockpile
	var lateral := (rel - toward * along).length()
	if along < -0.2 and lateral < PUSH_LATERAL_TOLERANCE:
		return Vector3(stock.x, prop_pos.y, stock.z)
	return prop_pos - toward * PUSH_STANCE_DISTANCE

# Begins walking to an already-assigned construction site
func _start_building(site_id: String) -> void:
	build_target_id = site_id
	is_building = true
	set_new_destination(builder.construction_sites[site_id].position)

func _update_building(delta: float) -> void:
	if not is_building:
		return
	if builder == null:
		is_building = false
		return
	
	# Site finished, got demolished, or was unassigned -- stop walking toward it
	if not builder.construction_sites.has(build_target_id):
		is_building = false
		build_target_id = NO_ID
		return
	
	var site = builder.construction_sites[build_target_id]
	if not data.id in site.assigned_builders:
		is_building = false
		build_target_id = NO_ID
		return
	
	# Building costs energy while actively assigned to a site -- same
	# per-second model as gathering (see Structure.build_energy_required).
	var structure: Structure = builder.structures[site.structure_index]
	data.energy = clamp(data.energy - structure.build_energy_required * delta, 0.0, 100.0)

func set_new_destination(target):
	nav_agent.target_position = target

# --- Jobs -------------------------------------------------------------------

# Called by PolicyEngine when the citizen is employed at a workplace.
func set_job(title: String, task: int, workplace_id: String) -> void:
	data.job = title
	data.job_task = task
	data.workplace_id = workplace_id
	gather_filter = "wood" if task == Structure.JobTask.GATHER else ""
	_job_timer = 0.0 # get to work straight away

# Called by Builder when the citizen loses their job (workplace demolished, reassigned, ...).
func clear_job() -> void:
	data.job = ""
	data.job_task = Structure.JobTask.NONE
	data.workplace_id = ""
	gather_filter = ""

# An employed citizen with nothing on their hands goes looking for work in line with their job.
# Only runs while idle, so manual assignments and an in-progress task are never overridden.
func _update_job(delta: float) -> void:
	if data.job == "" or builder == null:
		return
	if is_gathering or is_building or is_pushing:
		return
	_job_timer -= delta
	if _job_timer > 0.0:
		return
	_job_timer = JOB_CHECK_INTERVAL
	match data.job_task:
		Structure.JobTask.GATHER:
			_start_gathering()
		Structure.JobTask.BUILD:
			var site_id: String = builder.get_nearest_construction_site(global_position)
			if site_id != NO_ID:
				PolicyEngine.execute(Action.new_assign_build_task(), self, site_id)

# Wander targets used to be raw random points with no regard for whether the navmesh
# actually covers that spot
func _wander_target(nav_range: float) -> Vector3:
	var raw = global_position + Vector3(randf_range(-nav_range, nav_range), 0, randf_range(-nav_range, nav_range))
	var map_rid = nav_agent.get_navigation_map()
	# If map not synced yet, return raw (unsnapped) point
	if NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		return raw
	return NavigationServer3D.map_get_closest_point(map_rid, raw)

var _last_color_t := -1.0

func update_happiness_color():
	# Green when happy, red when unhappy. Only touch the material when the
	# (rounded) value actually changed -- this is called every frame per citizen.
	var t := snappedf(data.happiness / 100.0, 0.01)
	if t == _last_color_t:
		return
	_last_color_t = t
	happiness_material.albedo_color = Color(1.0 - t, t, 0.0)

# --- Multiplayer -------------------------------------------------------------

# Server: the nearest connected player (the avatar the server keeps for each client) to chase / hit.
# The server's own Player just stands at the spawn point, it is nobody.
func _nearest_player() -> NetPlayer:
	if Globals.network == null:
		return null
	var best: NetPlayer = null
	var best_dist := INF
	for child in Globals.network.net_players.get_children():
		var avatar := child as NetPlayer
		if avatar == null or avatar.net_position == Vector3.ZERO:
			continue # not reported its position yet
		var d := global_position.distance_squared_to(avatar.net_position)
		if d < best_dist:
			best_dist = d
			best = avatar
	return best

# Server: copy what clients need to see into the replicated net_* values
func _publish_net_state() -> void:
	net_position = global_position
	net_name = data.citizen_name
	net_id = data.id
	net_age = data.age
	net_job = data.job
	net_happiness = snappedf(data.happiness, 0.1)
	net_energy = snappedf(data.energy, 0.1)
	net_health = snappedf(health, 0.1)
	net_hostile = is_chasing_player

# Client: follow the server's copy of this citizen
func _puppet_process(delta: float) -> void:
	if net_position == Vector3.ZERO:
		visible = false
		return
	if not visible:
		visible = true
		global_position = net_position
	global_position = global_position.lerp(net_position, 1.0 - exp(-PUPPET_SMOOTHING * delta))
	data.citizen_name = net_name
	data.id = net_id
	data.age = net_age
	data.job = net_job
	data.happiness = net_happiness
	data.energy = net_energy
	health = maxf(net_health, 0.01) # not 0: that would run the death logic here, the server decides who dies
	is_chasing_player = net_hostile
	update_happiness_color()
	_push_rpc_cooldown -= delta

# A shove (see Carrier._push_colliding_bodies). On a client the real citizen is on the server, so pass it on.
func receive_push(dv: Vector3) -> void:
	if is_puppet:
		if _push_rpc_cooldown <= 0.0:
			_push_rpc_cooldown = PUSH_RPC_INTERVAL
			request_push.rpc_id(1, dv)
		return
	super.receive_push(dv)

@rpc("any_peer", "call_remote", "reliable")
func request_push(dv: Vector3) -> void:
	if not multiplayer.is_server() or Globals.network == null or dv.length() > MAX_IMPACT_SPEED + 0.5:
		return
	var avatar := Globals.network.net_players.get_node_or_null(str(multiplayer.get_remote_sender_id())) as NetPlayer
	if avatar == null or avatar.net_position.distance_to(global_position) > 4.0:
		return # not actually next to this citizen
	receive_push(dv)
