extends Carrier

# Movement settings
@export var BASE_SPEED = 6.0
@export var BOUNCE_HEIGHT := 0.0
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
@onready var nameplate: Nameplate = $Nameplate # name, health and energy floating over the head (same scene the other players use)

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
# A log that makes no headway toward the stockpile for PUSH_STALL_TIME gets a direct shove; after PUSH_MAX_STALLS
# of those the citizen gives up on it for PUSH_IGNORE_TIME (a player can still push it) and goes back to work.
const PUSH_STALL_TIME := 6.0
const PUSH_MIN_PROGRESS := 0.5 # metres closer to the stockpile that count as headway
const PUSH_MAX_STALLS := 3
const PUSH_NUDGE_SPEED := 3.0 # m/s the direct shove gives the log
const PUSH_IGNORE_TIME := 45.0
var _push_best_dist := INF
var _push_stall_timer := 0.0
var _push_stalls := 0
var _ignored_props: Dictionary = {} # prop instance id -> time (s) until which this citizen leaves it alone

# Small items (fruit) are too small to shove, so a citizen picks them up like the player does (E): up to
# ResourceProp.MAX_CARRY, stacked overhead, then walks the whole armful onto the stockpile and drops them there.
const FRUIT_GRAB_REACH := 1.5 # how close to a fruit before it is picked up
const FRUIT_LEG_TIMEOUT := 20.0 # seconds to reach one fruit before giving up on it (delivery gets double)
var _fruit_run := false # the current task is carrying fruit rather than pushing a log
var _fruit_delivering := false # hands full / nothing left to pick up: heading for the stockpile
var _fruit_leg_time := 0.0
var _carried: Array = [] # ResourceProps held overhead, oldest first

# Hauling: a standing task (assigned by clicking a log, or by a HAUL job). The citizen shuttles every loose log to the
# stockpile, one after another, and never goes off to chop. Anyone else only clears the logs of the tree they just felled.
var is_hauling: bool = false
const HAUL_CHECK_INTERVAL := 1.0 # how often an idle hauler looks for another loose log
const LOG_CHAIN_RADIUS := 8.0 # a chopper keeps pushing logs lying this close to the tree they felled
var _haul_timer := 0.0
var _chain_origin := Vector3.INF # where the tree a chopper just felled stood (INF = any log will do)

# Eating -- the "food distribution" default tradition. A hungry citizen (energy below Builder.hungry_below) drops what
# they are doing, walks to the stockpile and eats until Builder.eat_until, then goes back to what they were doing.
var is_eating: bool = false
const EAT_BITE_INTERVAL := 0.8 # seconds between bites at the stockpile
const EAT_GIVE_UP_TIME := 25.0 # seconds of walking to the stockpile before giving up for a while
const EAT_RETRY_DELAY := 20.0 # how long a citizen who gave up leaves the food alone
var _eat_resume_hint := "" # set by _after_push so a bite between two logs resumes pushing afterwards

# Policies -- what a citizen does is decided by PolicyEngine.think() (the rule book: default traditions today, the
# player's own rules later); this script only knows HOW to do each thing (start_eating, start_wander, ...).
const POLICY_INTERVAL := 0.5 # how often the citizen asks the policies what to do
var _policy_timer := randf() * POLICY_INTERVAL # staggered so the whole village does not think on the same frame
## true while the citizen is on a task the player gave them by hand: ordinary policies leave them alone until it is
## finished (survival ones, like eating, still run). Set by PolicyEngine.execute(), cleared in _update_policies().
var manual_task: bool = false
var _eat_retry_timer := 0.0
var _eat_bite_timer := 0.0
var _eat_elapsed := 0.0
var _eat_resume := "" # what to go back to afterwards: "build", "gather", "push" or "" (nothing, they were idle)

# Gather targets this citizen could not path to (the navmesh is split there): tree id -> time (s) to retry
const UNREACHABLE_GIVE_UP := 1.0 # seconds of "not reachable" before the tree is written off
const UNREACHABLE_RETRY_TIME := 60.0
var _unreachable_targets: Dictionary = {}
var _unreachable_time := 0.0
var _stand_still_timer := 0.0 # > 0: stand where we are (an assignment was refused), wandering resumes afterwards

func _init() -> void:
	kill_height = -10.0 # citizens die this far below the world (the player's is Carrier's default)

func _ready():
	if data == null:
		data = CitizenData.new()
	
	is_puppet = not multiplayer.is_server()
	add_to_group("citizen")
	nameplate.set_shown(false) # a citizen's nameplate only shows while the mouse is on them (see CitizenSelector)
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
	_drop_carried() # never leave fruit frozen in mid-air
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
	
	_update_policies(delta)
	_update_eating(delta)
	_update_gathering(delta)
	_update_building(delta)
	_update_pushing(delta)
	_update_hauling(delta)
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
	_stand_still_timer = maxf(_stand_still_timer - delta, 0.0)
	if not is_gathering and not is_building and not is_pushing and not is_eating:
		wander_timer -= delta
		if is_on_floor() and wander_timer > 0:
			if data.energy > 0.0:
				velocity.y = BOUNCE_HEIGHT
		else:
			wander_timer = randf_range(0, 2) * (100 - data.happiness)
			idle_timer -= delta # when it runs out, the "Wander when idle" tradition sends them off (start_wander)
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
			if is_gathering:
				_unreachable_time += delta
				if not _warned_unreachable:
					_warned_unreachable = true
					push_warning("Citizen %s: gather target %s is not reachable on the navmesh (target %s) -- picking another tree." % [name, gather_target_id, nav_agent.target_position])
				if _unreachable_time >= UNREACHABLE_GIVE_UP:
					# Written off for a while, and the citizen goes for a tree it can actually reach
					_unreachable_targets[gather_target_id] = Time.get_ticks_msec() / 1000.0 + UNREACHABLE_RETRY_TIME
					is_gathering = false
					_start_gathering()
			_wanted_velocity = Vector3.ZERO
		else:
			_unreachable_time = 0.0
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
	_update_nameplate()
		
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
	var id = builder.get_nearest_gatherable(global_position, gather_filter, _unreachable_targets)
	if id == NO_ID:
		return
	_start_gathering_at(id)

func _start_gathering_at(id: String) -> void:
	# Targeted version -- a specific tree assigned by the player or PolicyEngine.
	# Also used by _start_gathering() after it resolves the nearest id.
	_warned_unreachable = false
	_unreachable_time = 0.0
	is_hauling = false # an explicit tree assignment replaces a hauling task
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
	return global_position.distance_to(Vector3(p.x, global_position.y, p.z)) <= builder.get_gather_reach(gather_target_id)

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
	var close_enough = global_position.distance_to(target_world_pos) <= builder.get_gather_reach(gather_target_id)
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
		_chain_origin = target_pos # the logs of this tree are what we push next
		_after_push()

# What to do once a log is home (or given up on): push the NEXT loose log, one after another until none are left,
# and only then go back to chopping. A hauler has no chopping to go back to -- it waits for more logs
# (see _update_hauling).
func _after_push(skip_eating := false) -> void:
	if not skip_eating:
		# Between two logs is a natural moment to stop for a bite: ask the survival policies ("Eat when hungry")
		_eat_resume_hint = "push"
		var ate := PolicyEngine.think(self, true) and is_eating
		_eat_resume_hint = ""
		if ate:
			return
	if _start_pushing_nearest_prop():
		return
	if not is_hauling:
		_start_gathering()

# Walks up to the nearest uncollected resource prop (spawned incrementally during the gather -- see
# Builder.add_chop_progress()) and leans on it, nudging it toward the stockpile via the shared push logic in
# carrier.gd. A hauler considers every loose log; a chopper only the ones lying near the tree they felled, and
# neither takes a log another citizen is already shoving. Returns false if there is nothing to push.
func _start_pushing_nearest_prop() -> bool:
	var nearest := _nearest_pushable_prop(false)
	if nearest == null:
		return false
	_begin_pushing(nearest)
	return true

# The closest loose prop this citizen could deal with (only_small: fruit only, used to keep filling the armful)
func _nearest_pushable_prop(only_small: bool) -> RigidBody3D:
	var nearest: RigidBody3D = null
	var nearest_dist := INF
	var now := Time.get_ticks_msec() / 1000.0
	var chain_origin := Vector3.INF if is_hauling else _chain_origin
	for prop in get_tree().get_nodes_in_group("resource_prop"):
		if not is_instance_valid(prop) or prop.collected:
			continue # already piled at the stockpile -- nothing left to push
		if prop.held:
			continue # somebody is carrying it
		if only_small and builder.is_stacked_type(String(prop.get_meta("resource_type", ""))):
			continue
		if _ignored_props.get(prop.get_instance_id(), 0.0) > now:
			continue # this one defeated us; leave it for the player
		if chain_origin != Vector3.INF and Builder.flat_distance(prop.global_position, chain_origin) > LOG_CHAIN_RADIUS:
			continue # not from the tree we just felled
		var other = prop.get_meta("pusher") if prop.has_meta("pusher") else null # (get_meta with a null default still logs an error when the key is missing)
		if other != null and is_instance_valid(other) and other != self and other.is_pushing and other.push_target == prop:
			continue # somebody is already on it
		var d = global_position.distance_squared_to(prop.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = prop
	return nearest

# Starts the task for one prop: a log is shoved home; a small item (fruit) is picked up and carried
func _begin_pushing(prop: RigidBody3D) -> void:
	prop.set_meta("pusher", self)
	is_pushing = true
	push_target = prop
	push_repath_timer = 0.0
	_push_best_dist = INF
	_push_stall_timer = 0.0
	_push_stalls = 0
	_fruit_run = not builder.is_stacked_type(String(prop.get_meta("resource_type", "")))
	_fruit_delivering = false
	_fruit_leg_time = 0.0
	if _fruit_run:
		set_new_destination(prop.global_position)
	else:
		set_new_destination(_push_destination())

# One tick of a fruit run: walk to the nearest loose fruit and grab it, repeat until the armful is 10 (or none are
# left), then walk onto the stockpile and let go -- the fruits settle there and are collected as usual.
func _update_fruit_run(delta: float) -> void:
	if is_eating:
		return # the bite comes first; the fruit stays in hand
	_fruit_leg_time += delta
	push_repath_timer -= delta
	if push_target != null and (not is_instance_valid(push_target) or push_target.collected or push_target.held):
		push_target = null
	if not _fruit_delivering and _carried.size() < ResourceProp.MAX_CARRY:
		if push_target == null:
			var next := _nearest_pushable_prop(true)
			if next != null:
				next.set_meta("pusher", self)
				push_target = next
				_fruit_leg_time = 0.0
				push_repath_timer = 0.0
		if push_target != null:
			if push_repath_timer <= 0.0:
				push_repath_timer = PUSH_REPATH_INTERVAL
				set_new_destination(push_target.global_position)
			if Builder.flat_distance(global_position, push_target.global_position) <= FRUIT_GRAB_REACH:
				push_target.grab()
				_carried.append(push_target)
				push_target = null
				_fruit_leg_time = 0.0
			elif _fruit_leg_time >= FRUIT_LEG_TIMEOUT:
				_ignored_props[push_target.get_instance_id()] = Time.get_ticks_msec() / 1000.0 + PUSH_IGNORE_TIME
				push_target = null
				_fruit_leg_time = 0.0
			return
	# Hands full, or nothing more to pick up: take what we have to the stockpile
	if _carried.is_empty():
		_finish_fruit_run()
		return
	if not _fruit_delivering:
		_fruit_delivering = true
		_fruit_leg_time = 0.0
		push_repath_timer = 0.0
	if push_repath_timer <= 0.0:
		push_repath_timer = PUSH_REPATH_INTERVAL
		set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.food_stockpile_position))
	if builder.is_in_food_stockpile(global_position) or _fruit_leg_time >= FRUIT_LEG_TIMEOUT * 2.0:
		_drop_carried()
		_finish_fruit_run()

func _finish_fruit_run() -> void:
	is_pushing = false
	push_target = null
	_fruit_run = false
	_fruit_delivering = false
	_after_push() # on to the next thing (more fruit / logs / back to work)

# Keeps the armful floating overhead; anything that ended the fruit task (new job, ...) drops it
func _hold_carried() -> void:
	if _carried.is_empty():
		return
	for i in range(_carried.size() - 1, -1, -1):
		var held_prop := _carried[i] as ResourceProp
		if not is_instance_valid(held_prop) or held_prop.collected:
			_carried.remove_at(i)
	if not is_pushing or not _fruit_run:
		_drop_carried()
		return
	for i in _carried.size():
		(_carried[i] as ResourceProp).global_position = global_position + ResourceProp.carry_offset(i)

func _drop_carried() -> void:
	for node in _carried:
		var prop := node as ResourceProp
		if is_instance_valid(prop) and not prop.collected:
			prop.global_position += Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)) # don't land in one spot
			prop.release()
	_carried.clear()

func _update_pushing(delta: float) -> void:
	_hold_carried()
	if not is_pushing:
		return
	if _fruit_run:
		_update_fruit_run(delta)
		return
	# Prop already got collected (by us or anyone else nudging it in) --
	# resource_prop.gd no longer frees itself on collection (logs stay
	# visible forever as the stockpile pile -- see resource_prop.gd), so
	# check its `collected` flag instead of instance validity.
	if push_target == null or not is_instance_valid(push_target) or push_target.collected:
		is_pushing = false
		push_target = null
		_after_push() # on to the next log
		return
	push_repath_timer -= delta
	if push_repath_timer <= 0.0:
		push_repath_timer = PUSH_REPATH_INTERVAL
		set_new_destination(_push_destination())

	# Stuck check: is the log actually getting closer to the stockpile?
	var stock: Vector3 = builder.stockpile_position
	var dist_to_stock := Vector2(push_target.global_position.x - stock.x, push_target.global_position.z - stock.z).length()
	if dist_to_stock < _push_best_dist - PUSH_MIN_PROGRESS:
		_push_best_dist = dist_to_stock
		_push_stall_timer = 0.0
		return
	_push_stall_timer += delta
	if _push_stall_timer < PUSH_STALL_TIME:
		return
	_push_stall_timer = 0.0
	_push_stalls += 1
	if _push_stalls >= PUSH_MAX_STALLS:
		# Give up on this log for a while (the player can still shove it) and carry on with work
		_ignored_props[push_target.get_instance_id()] = Time.get_ticks_msec() / 1000.0 + PUSH_IGNORE_TIME
		is_pushing = false
		push_target = null
		_after_push()
		return
	# Direct shove toward the stockpile, for logs wedged where leaning on them does nothing
	var toward := Vector3(stock.x - push_target.global_position.x, 0.0, stock.z - push_target.global_position.z).normalized()
	push_target.net_push(toward * push_target.mass * PUSH_NUDGE_SPEED + Vector3.UP * push_target.mass * 0.5, Vector3.ZERO)

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

# Standing task: move every loose log to the stockpile. `prop_name` (the log the player clicked) goes first; with
# "" the nearest one does. Called by PolicyEngine for ASSIGN_HAUL.
func _start_hauling(prop_name: String = "") -> void:
	is_hauling = true
	is_gathering = false # leave the tree
	is_building = false
	is_pushing = false
	push_target = null
	_haul_timer = 0.0
	var prop = builder.get_node_or_null(NodePath(prop_name)) if prop_name != "" else null
	if prop is ResourceProp and not prop.collected and not prop.held:
		_ignored_props.erase(prop.get_instance_id()) # the player asked for this one specifically
		_begin_pushing(prop)
	else:
		_start_pushing_nearest_prop()

# An idle hauler keeps an eye out for logs that need moving (new ones from the choppers, or ones it gave up on)
func _update_hauling(delta: float) -> void:
	if not is_hauling or is_pushing or is_gathering or is_building or is_eating or builder == null:
		return
	_haul_timer -= delta
	if _haul_timer > 0.0:
		return
	_haul_timer = HAUL_CHECK_INTERVAL
	_start_pushing_nearest_prop()

# --- Eating ---------------------------------------------------------------

func _update_eating(delta: float) -> void:
	if builder == null:
		return
	if not is_eating:
		_eat_retry_timer = maxf(_eat_retry_timer - delta, 0.0)
		return # whether to start eating is the "Eat when hungry" tradition's call (PolicyEngine.think -> start_eating)
	_eat_elapsed += delta
	if not builder.has_food():
		_stop_eating(5.0) # somebody ate the last of it
		return
	if _eat_elapsed > EAT_GIVE_UP_TIME:
		_stop_eating(EAT_RETRY_DELAY) # can't reach the stockpile
		return
	if not builder.is_at_food_store(global_position):
		return # still walking there
	_eat_bite_timer -= delta
	if _eat_bite_timer > 0.0:
		return
	_eat_bite_timer = EAT_BITE_INTERVAL
	data.energy = clampf(data.energy + builder.take_food(), 0.0, 100.0)
	if data.energy >= builder.eat_until:
		_stop_eating(0.0)

## Action EAT: drop what they are doing, walk to the stockpile and eat until full, then go back to it. Whether they
## should is decided by the policies (hungry, food in stock, not sulking), so this only checks that food exists.
func start_eating() -> bool:
	if is_eating or builder == null or not builder.has_food():
		return false
	_eat_resume = _eat_resume_hint if _eat_resume_hint != "" else ("build" if is_building else ("gather" if is_gathering else ""))
	is_gathering = false
	is_building = false # (the site keeps its builder slot; _stop_eating walks back to it)
	is_eating = true
	_eat_elapsed = 0.0
	_eat_bite_timer = 0.0
	set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.stockpile_position))
	return true

func _stop_eating(retry_delay: float) -> void:
	is_eating = false
	_eat_retry_timer = retry_delay
	var resume := _eat_resume
	_eat_resume = ""
	match resume:
		"build":
			if builder.construction_sites.has(build_target_id):
				_start_building(build_target_id)
		"gather":
			_start_gathering()
		"push":
			_after_push(true)

# Begins walking to an already-assigned construction site
func _start_building(site_id: String) -> void:
	is_hauling = false # an explicit site assignment replaces a hauling task
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

## Can this citizen walk to `pos` on the current navmesh? Used to refuse an assignment up front instead of letting the
## citizen wander off and give up (the Policy Engine reports the refusal to the player).
func can_reach(pos: Vector3) -> bool:
	var map_rid:RID = nav_agent.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		return true # map not synced yet: can't tell, don't refuse
	var goal := NavigationServer3D.map_get_closest_point(map_rid, pos)
	var path := NavigationServer3D.map_get_path(map_rid, global_position, goal, true)
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(goal) < 1.0

## Drop whatever the citizen was walking to and stay put for a few seconds before the wander routine takes over again.
func stand_still(seconds: float) -> void:
	is_gathering = false
	gather_target_id = NO_ID
	nav_agent.target_position = global_position
	_wanted_velocity = Vector3.ZERO
	_stand_still_timer = seconds

# --- What the policies can ask of a citizen ---------------------------------
# Situation getters read by PolicyEngine's citizen fields, and the actions its default traditions run.

func is_busy() -> bool:
	return is_gathering or is_building or is_pushing or is_eating

func task_name() -> String:
	if is_eating: return "eating"
	if is_pushing: return "pushing"
	if is_building: return "building"
	if is_gathering: return "gathering"
	if is_hauling: return "hauling"
	return "idle"

## Not already eating, not in the middle of shoving a log (that is finished first), not sulking after giving up
func eat_ready() -> bool:
	return not is_eating and not is_pushing and _eat_retry_timer <= 0.0

## The idle timer has run out and they are not standing still because an assignment was just refused
func wander_ready() -> bool:
	return idle_timer <= 0.0 and _stand_still_timer <= 0.0

## Action WANDER
func start_wander() -> void:
	set_new_destination(_wander_target(100.0))
	idle_timer = clamp(randf_range(0.0, data.happiness * 0.2), 5.0, 20.0)

func _update_policies(delta: float) -> void:
	if manual_task and not (is_gathering or is_building or is_pushing or is_hauling or is_eating):
		manual_task = false # the task the player gave them is finished
	_policy_timer -= delta
	if _policy_timer > 0.0:
		return
	_policy_timer = POLICY_INTERVAL
	PolicyEngine.think(self)

# --- Jobs -------------------------------------------------------------------

# Called by PolicyEngine when the citizen is employed at a workplace.
func set_job(title: String, task: int, workplace_id: String) -> void:
	data.job = title
	data.job_task = task
	data.workplace_id = workplace_id
	gather_filter = "wood" if task == Structure.JobTask.GATHER else ""
	is_hauling = task == Structure.JobTask.HAUL
	_haul_timer = 0.0
	_job_timer = 0.0 # get to work straight away

# Called by Builder when the citizen loses their job (workplace demolished, reassigned, ...).
func clear_job() -> void:
	data.job = ""
	data.job_task = Structure.JobTask.NONE
	data.workplace_id = ""
	gather_filter = ""
	is_hauling = false

# An employed citizen with nothing on their hands goes looking for work in line with their job.
# Only runs while idle, so manual assignments and an in-progress task are never overridden.
func _update_job(delta: float) -> void:
	if data.job == "" or builder == null:
		return
	if is_gathering or is_building or is_pushing or is_hauling or is_eating:
		return # (a hauler finds its own work, see _update_hauling)
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

var _shown_name := "\n" # impossible name, so the first update always draws
var _shown_health := -1
var _shown_energy := -1

## Keeps the floating nameplate in step with the citizen. Only touches it when a value actually changed
## (each bar is a small viewport, so redrawing them every frame for every citizen would be wasteful).
func _update_nameplate() -> void:
	if DisplayServer.get_name() == "headless":
		return # dedicated server: nothing to draw
	if data.citizen_name != _shown_name:
		_shown_name = data.citizen_name
		nameplate.set_player_name(_shown_name if _shown_name != "" else "Unnamed")
	var health_pct := roundi(health / maxf(max_health, 1.0) * 100.0)
	var energy_pct := roundi(data.energy)
	if health_pct != _shown_health or energy_pct != _shown_energy:
		_shown_health = health_pct
		_shown_energy = energy_pct
		nameplate.set_stats(health_pct, energy_pct)

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
	_update_nameplate()
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
