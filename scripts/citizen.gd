extends Carrier

# Movement settings
@export var BASE_SPEED = 4.0
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

@export var gather_debug := false

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
var net_hunger := 100.0
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
var _carry_forward := Vector3.FORWARD # the way this citizen last walked: carried fruit is held in front of them
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
const BUSH_SEEK_RADIUS := 25.0 # how far a fruit run looks for a bush once no loose fruit is left
const BUSH_PICK_REACH := 2.4 # how close (flat, to the bush's centre) to pick its fruit
const BUSH_PICK_TIME := 1.2 # seconds to pick one fruit
var _bush_pick_timer := 0.0
var _fruit_run := false # the current task is a carrying run (fruit, or a log when carry_logs is on) rather than pushing a log
var _log_run := false # ...and what it carries is a log: just MAX_CARRY_LOGS at a time, and it slows the citizen down
## Citizens pick logs up and walk them to the stockpile (slowly, one at a time) instead of shoving them there. Off = the old pushing.
@export var carry_logs := true
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

# Reproduction: while health AND hunger (well fed) stay above Builder.birth_min_stat, in-game days pile up here; reaching
# Builder.birth_interval_days is a chance of a child (see Builder.try_birth). Dropping to the threshold or below starts over.
var _thriving_days := 0.0
var _last_birth_clock := -1.0

# Eating -- an innate need, not a policy. A hungry citizen (hunger below Builder.hungry_below) with food in stock drops what
# they are doing, walks to the stockpile and eats until Builder.eat_until, then goes back to what they were doing.
var is_eating: bool = false
const EAT_BITE_INTERVAL := 0.8 # seconds between bites at the stockpile
const EAT_GIVE_UP_TIME := 25.0 # seconds of walking to the stockpile before giving up for a while
const EAT_RETRY_DELAY := 20.0 # how long a citizen who gave up leaves the food alone
var _eat_resume_hint := "" # set by _after_push so a bite between two logs resumes pushing afterwards

# Policies -- what a citizen does ABOUT THEIR NEEDS is innate (_update_needs: pass out, eat, sleep at night) and
# always comes first. What they do beyond that is decided by PolicyEngine.think() (traditions and the player's own rules), and
# only when no policy has anything for them to do do they amble about (start_wander). This script knows HOW to do each thing.
const POLICY_INTERVAL := 0.5 # how often the citizen asks the policies what to do
var _policy_timer := randf() * POLICY_INTERVAL # staggered so the whole village does not think on the same frame
## true while the citizen is on a task the player gave them by hand: policies leave them alone until it is
## finished (their innate needs, like eating, still run). Set by PolicyEngine.execute(), cleared in _update_policies().
var manual_task: bool = false
var _eat_retry_timer := 0.0
var _eat_bite_timer := 0.0
var _eat_elapsed := 0.0
var _eat_resume := "" # what to go back to afterwards: "build", "gather", "push", "rest" or "" (nothing, they were idle)

# Resting -- an innate need, not a policy. At night a citizen picks a shelter (the home they were
# assigned if any, otherwise a random one), walks there and sleeps until morning. Sleeping (Carrier.is_resting) recharges
# energy fastest; a citizen who is merely idle recharges it slowly (Carrier.idle_recharge), so a settlement with no shelter
# has citizens who recover only a little between jobs. One who runs completely dry passes out where they stand (_collapse).
var is_heading_to_rest := false # walking to the shelter (is_resting takes over once there)
const REST_GIVE_UP_TIME := 60.0 # seconds of walking before giving up (an exhausted citizen is slow)
const REST_RETRY_DELAY := 20.0 # how long a citizen who gave up leaves the shelters alone
var _rest_shelter_id := ""
var _rest_elapsed := 0.0
var _rest_retry_timer := 0.0

# Gather targets this citizen could not path to (the navmesh is split there): tree id -> time (s) to retry
const UNREACHABLE_GIVE_UP := 1.0 # seconds of "not reachable" before the tree is written off
const UNREACHABLE_RETRY_TIME := 60.0
var _unreachable_targets: Dictionary = {}
var _unreachable_time := 0.0
var _stand_still_timer := 0.0 # > 0: stand where we are (an assignment was refused), wandering resumes afterwards

# Walking to a spot the player clicked while this citizen was selected (Action GO_TO_POSITION). Ends on arrival, on giving up
# (GO_TO_TIMEOUT), or when anything else takes over (a survival policy such as eating, or another order).
var is_going_to_position := false
const GO_TO_REACH := 1.0 # flat metres from the clicked spot that count as arrived
const GO_TO_TIMEOUT := 60.0 # seconds before giving up on a spot that can't be reached after all
var _go_target := Vector3.ZERO
var _go_elapsed := 0.0
var is_going_to_zone := false
var _go_zone := -1
var _go_zone_elapsed := 0.0
var _go_zone_retry_timer := 0.0
var _failed_go_zone := -1
var _initial_navigation_pending := false

# Ambling about (innate): the fallback when no policy has anything for an idle citizen to do. It remains idle for policy
# eligibility, so a matching rule can take over without waiting for the stroll to finish.
var is_wandering := false
const WANDER_TIMEOUT := 40.0
var _wander_elapsed := 0.0

func _init() -> void:
	kill_height = -10.0 # citizens die this far below the world (the player's is Carrier's default)
	# Standing on a log and stepping off used to add the log's velocity to the citizen (the default), and a log that
	# lag had sent tumbling flung them away with it.
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING

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
	
	# Spawners set global_position after add_child(), so choose the first target only after that has happened.
	_initial_navigation_pending = true
	call_deferred("_request_initial_wander")

func _request_initial_wander() -> void:
	# If the NavigationRegion3D is still registering its polygons with the server around the same
	# time citizens spawn, the map's first sync can land on a later frame.
	# map_get_iteration_id() is 0 until the map has synced at least once
	var map_rid = nav_agent.get_navigation_map()
	while NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		await get_tree().physics_frame
		if not is_instance_valid(self):
			return
	set_new_destination(_wander_target(100.0))
	_initial_navigation_pending = false

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
	_guard_runaway(delta) # cap speed, and notice a citizen that got flung off the navmesh
	if _off_navmesh:
		_tick_off_navmesh(delta, in_fluid) # no AI, no path queries: it just obeys physics until it is back on the navmesh (or falls out of the world)
		return
		
	var vitality_mult := _vitality_mult() # hurt, hungry and tired all slow a citizen down (see carrier.gd)
	
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
	_update_going_to_position(delta)
	_update_going_to_zone(delta)
	_update_wandering(delta)
	_update_eating(delta)
	_update_resting(delta)
	_update_gathering(delta)
	_update_building(delta)
	_update_pushing(delta)
	_update_hauling(delta)
	_update_job(delta)
	_update_reproduction()
	
	# Update citizen stats
	if data.job == "":
		data.job_satisfaction -= 10 * delta
	else:
		data.job_satisfaction += randf_range(0.0, 0.01)
	
	data.job_satisfaction = clamp(data.job_satisfaction, 0.0, 100.0)
	
	# Housing satisfaction eases toward 100 if housed, 0 if not
	var housing_target = 100.0 if _has_housing else 0.0
	data.housing_satisfaction = move_toward(data.housing_satisfaction, housing_target, delta * 20.0)
	
	data.happiness = clamp(50 - (100 - hunger) * 0.005 - (100 - energy) * 0.005 + (data.job_satisfaction * 0.01 if data.job != "" else -data.job_satisfaction * 0.01) + (data.housing_satisfaction - 50.0) * 0.1, 0, 100)
	update_happiness_color()
	
	actual_speed = BASE_SPEED + (100 - data.happiness) * 0.01
	nav_agent.max_speed = actual_speed
	
	if collapsed:
		is_chasing_player = false
	elif data.happiness < 0.1:
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

	# One navigation query trigger per frame: is_navigation_finished() / is_target_reachable() / get_next_path_position()
	# all run update_navigation() (the path query) internally, so ask once, and never before the navmesh has synced.
	var nav_ready := _navigation_ready() and not collapsed
	var nav_finished: bool = true if not nav_ready else nav_agent.is_navigation_finished()
	
	# Wander timer (skipped while actively gathering, building, pushing, eating or resting)
	_stand_still_timer = maxf(_stand_still_timer - delta, 0.0)
	if not is_gathering and not is_building and not is_pushing and not is_eating and not is_heading_to_rest and not is_resting and not is_going_to_position and not is_going_to_zone:
		wander_timer -= delta
		if is_on_floor() and wander_timer > 0:
			if hunger > 0.0:
				velocity.y = BOUNCE_HEIGHT
		else:
			wander_timer = randf_range(0, 2) * (100 - data.happiness)
			idle_timer -= delta # when it runs out, the innate idle behavior starts a stroll
	else:
		# Working: the walk to the tree / site / prop used to have NO hop at all (only wandering did), which
		# looked like the citizen had frozen. Hop while travelling, stand still once at the work spot.
		if is_on_floor() and hunger > 0.0 and not nav_finished and not _is_at_gather_target():
			velocity.y = BOUNCE_HEIGHT
	
	if not nav_finished and hunger > 0.0:
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
	
	# Slow a citizen who is hurt, hungry or worn out (vitality_mult is 1.0 when all is well)
	var wanted := _wanted_velocity
	wanted *= vitality_mult * _carry_speed_mult() # a log in the arms slows them too
	
	steer_horizontal(wanted, delta)
	
	if wanted.length() > 0.0:
		_spend_travel_energy(delta, in_fluid) # walking tires, swimming more so
	
	# Walking, working, shoving or carrying is activity; anything else is idle and slowly recharges energy (Carrier.is_active)
	is_active = wanted.length() > 0.0 or is_gathering or is_building or is_pushing or is_going_to_position or is_going_to_zone or is_wandering or not _carried.is_empty()
	_tick_vitals(delta) # hunger burns, healing costs hunger, starving / exhaustion hurt, sleeping (fast) or idling (slowly) recharges energy (carrier.gd)
	
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
	var id = builder.get_nearest_gatherable(global_position, gather_filter, _unreachable_targets, self)
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
	is_going_to_position = false
	is_going_to_zone = false
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
	if gather_debug and not close_enough and _navigation_ready():
		_debug_gather_timer -= delta
		if _debug_gather_timer <= 0.0:
			_debug_gather_timer = 1.0
			print("[gather-debug] %s pos=%s nav_target=%s final=%s finished=%s reachable=%s flat_dist=%.2f next=%s wanted=%s vel=%s energy=%.1f" % [
				name, global_position, nav_agent.target_position, nav_agent.get_final_position(), nav_agent.is_navigation_finished(),
				nav_agent.is_target_reachable(), Vector2(global_position.x - target_pos.x, global_position.z - target_pos.z).length(),
				nav_agent.get_next_path_position(), _wanted_velocity, velocity, energy])
	if not close_enough and (not _navigation_ready() or not nav_agent.is_navigation_finished()):
		return
	
	# Arrived -- contribute labor toward the shared, persisted chop progress.
	var gather_time = builder.structures[structure_index].gather_time
	var energy_required = builder.structures[structure_index].energy_required
	energy = clamp(energy - energy_required * delta, 0.0, 100.0)
	# add_chop_progress returns a Dictionary (not a bool) -- it's ALWAYS
	# truthy since it always has keys, even mid-chop. Must check the
	# "completed" key explicitly, not the dict itself.
	# picking = true: at a bush a citizen only picks one fruit per gather cycle and leaves the bush standing (trees are
	# felled as before). Without it a bush was chopped down like a tree.
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / gather_time, true)
	if result.get("completed", false):
		is_gathering = false
		var hunger_bonus: float = result.get("hunger_bonus", 0.0)
		if hunger_bonus > 0.0:
			hunger = clamp(hunger + hunger_bonus, 0.0, 100.0)
		_chain_origin = target_pos # the logs of this tree are what we push next
		_after_push()

# What to do once a log is home (or given up on): push the NEXT loose log, one after another until none are left,
# and only then go back to chopping. A hauler has no chopping to go back to -- it waits for more logs
# (see _update_hauling).
func _after_push(skip_eating := false) -> void:
	if not skip_eating:
		# Between two logs is a natural moment to stop for a bite
		_eat_resume_hint = "push"
		var ate := _wants_to_eat() and start_eating()
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
func _nearest_pushable_prop(only_small: bool, only_logs := false) -> RigidBody3D:
	var nearest: RigidBody3D = null
	var nearest_dist := INF
	var now := Time.get_ticks_msec() / 1000.0
	var chain_origin := Vector3.INF if is_hauling else _chain_origin
	for prop in get_tree().get_nodes_in_group("resource_prop"):
		if not is_instance_valid(prop) or prop.collected:
			continue # already piled at the stockpile -- nothing left to push
		if prop is ResourceProp and not (prop as ResourceProp).can_be_grabbed():
			continue # still held, collected, or flying onto the pile
		if prop.held:
			continue # somebody is carrying it
		if not _handles_resource(String(prop.get_meta("resource_type", ""))):
			continue # not what this citizen's job is about
		if not only_small and builder.is_in_pile_block(String(prop.get_meta("resource_type", "")), prop.global_position):
			continue # already over its stockpile: the pile tidies it, nobody needs to push it
		if only_small and builder.is_stacked_type(String(prop.get_meta("resource_type", ""))):
			continue
		if only_logs and not builder.is_stacked_type(String(prop.get_meta("resource_type", ""))):
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
	_log_run = carry_logs and builder.is_stacked_type(String(prop.get_meta("resource_type", "")))
	_fruit_run = _log_run or not builder.is_stacked_type(String(prop.get_meta("resource_type", "")))
	_fruit_delivering = false
	_fruit_leg_time = 0.0
	if _fruit_run:
		set_new_destination(prop.global_position)
	else:
		set_new_destination(_push_destination())

# Whether this citizen's job covers a resource: woodcutters and haulers deal with logs only, foragers with fruit only;
# everyone else (no workplace job, builders) as before.
func _handles_resource(resource_type: String) -> bool:
	var is_log: bool = builder.is_stacked_type(resource_type)
	match data.job_task:
		Structure.JobTask.GATHER, Structure.JobTask.HAUL:
			return is_log
		Structure.JobTask.FORAGE:
			return not is_log
	return true

# Fruit run, nothing loose left to grab: walk to the nearest bush that still has fruit and pick it one by one until the
# armful is full. Returns true while it is busy with a bush.
func _pick_from_bush(delta: float) -> bool:
	if not _handles_resource("food") or _fruit_leg_time >= FRUIT_LEG_TIMEOUT:
		return false
	var bush: Gatherable = builder.nearest_pickable_bush(global_position, BUSH_SEEK_RADIUS, self)
	if bush == null:
		_bush_pick_timer = 0.0
		return false
	if Builder.flat_distance(global_position, bush.global_position) > BUSH_PICK_REACH:
		_bush_pick_timer = 0.0
		if push_repath_timer <= 0.0:
			push_repath_timer = PUSH_REPATH_INTERVAL
			set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), bush.global_position))
		return true
	_bush_pick_timer += delta
	if _bush_pick_timer >= BUSH_PICK_TIME:
		_bush_pick_timer = 0.0
		var fruit: ResourceProp = builder.pick_bush_fruit(bush)
		if fruit != null:
			fruit.grab()
			_carried.append(fruit)
			_fruit_leg_time = 0.0
	return true

# One tick of a fruit run: walk to the nearest loose fruit and grab it, repeat until the armful is 10 (or none are
# left), then walk onto the stockpile and let go -- the fruits settle there and are collected as usual.
func _update_fruit_run(delta: float) -> void:
	if is_eating:
		return # the bite comes first; the fruit stays in hand
	_fruit_leg_time += delta
	push_repath_timer -= delta
	if push_target != null and (not is_instance_valid(push_target) or push_target.collected or push_target.held):
		push_target = null
	if not _fruit_delivering and _carried.size() < (ResourceProp.MAX_CARRY_LOGS if _log_run else ResourceProp.MAX_CARRY):
		if push_target == null:
			var next := _nearest_pushable_prop(not _log_run, _log_run)
			if next != null:
				next.set_meta("pusher", self)
				push_target = next
				_fruit_leg_time = 0.0
				push_repath_timer = 0.0
			elif not _log_run and _pick_from_bush(delta):
				return # busy picking from a bush
		if push_target != null:
			if push_repath_timer <= 0.0:
				push_repath_timer = PUSH_REPATH_INTERVAL
				set_new_destination(push_target.global_position)
			if Builder.flat_distance(global_position, push_target.global_position) <= FRUIT_GRAB_REACH:
				if push_target is ResourceProp and (push_target as ResourceProp).can_be_grabbed():
					(push_target as ResourceProp).grab()
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
		var store_zone := ZoneMap.Type.LOG_STOCKPILE if _log_run else ZoneMap.Type.FOOD_STOCKPILE
		set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.nearest_zone_point(store_zone, global_position)))
	var at_store: bool = builder.is_in_stockpile(global_position) if _log_run else builder.is_in_food_stockpile(global_position)
	if at_store or _fruit_leg_time >= FRUIT_LEG_TIMEOUT * 2.0:
		_drop_carried()
		_finish_fruit_run()

func _finish_fruit_run() -> void:
	is_pushing = false
	push_target = null
	_fruit_run = false
	_log_run = false
	_fruit_delivering = false
	_after_push() # on to the next thing (more fruit / logs / back to work)

# A log in the arms slows the citizen (see Carrier._carry_speed_mult)
func _carry_speed_mult() -> float:
	return ResourceProp.carry_speed_mult(_carried)

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
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if flat_velocity.length() > 0.1:
		_carry_forward = flat_velocity.normalized() # carried in front of them, the way they are walking
	for i in _carried.size():
		(_carried[i] as ResourceProp).carry_to(global_position + ResourceProp.carry_offset(i, _carry_forward), _carry_forward)

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
	# The log is over the stockpile block: our job is done. Stop here instead of walking on through the pile --
	# the pile itself tidies the log onto its slot (see ResourceProp / Builder.claim_stack_slot).
	if builder.is_in_stockpile(push_target.global_position):
		is_pushing = false
		push_target = null
		_after_push()
		return
	push_repath_timer -= delta
	if push_repath_timer <= 0.0:
		push_repath_timer = PUSH_REPATH_INTERVAL
		set_new_destination(_push_destination())

	# Stuck check: is the log actually getting closer to the stockpile?
	var stock: Vector3 = builder.nearest_zone_point(ZoneMap.Type.LOG_STOCKPILE, push_target.global_position)
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
	var stock: Vector3 = builder.nearest_zone_point(ZoneMap.Type.LOG_STOCKPILE, push_target.global_position)
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
	is_going_to_position = false
	is_going_to_zone = false
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
	if not is_hauling or is_pushing or is_gathering or is_building or is_eating or is_heading_to_rest or is_resting or builder == null:
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
		return # whether to start eating is an innate need (_update_needs -> start_eating)
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
	hunger = clampf(hunger + builder.take_food(), 0.0, 100.0)
	if hunger >= builder.eat_until:
		_stop_eating(0.0)

## Drop what they are doing, walk to the stockpile and eat until full, then resume what can be resumed.
func start_eating() -> bool:
	if is_eating or collapsed or builder == null or hunger >= builder.hungry_below or not builder.has_food():
		return false
	if _eat_resume_hint != "":
		_eat_resume = _eat_resume_hint
	elif is_resting or is_heading_to_rest:
		_eat_resume = "rest"
	elif is_building:
		_eat_resume = "build"
	elif is_gathering:
		_eat_resume = "gather"
	elif is_going_to_position:
		_eat_resume = "go_to_position"
	else:
		_eat_resume = ""
	is_resting = false # a hungry citizen gets up for a meal (and goes back to bed after, see _stop_eating)
	is_wandering = false
	is_heading_to_rest = false
	is_going_to_position = false # the bite comes first; they do not resume the walk
	is_going_to_zone = false
	is_gathering = false
	is_building = false # (the site keeps its builder slot; _stop_eating walks back to it)
	is_eating = true
	_eat_elapsed = 0.0
	_eat_bite_timer = 0.0
	set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.nearest_zone_point(ZoneMap.Type.FOOD_STOCKPILE, global_position)))
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
		"go_to_position":
			is_going_to_position = true
			_go_elapsed = 0.0
			set_new_destination(_go_target)
		"rest":
			if builder.is_night():
				start_resting() # still night: back to bed

# Begins walking to an already-assigned construction site
func _start_building(site_id: String) -> void:
	is_hauling = false # an explicit site assignment replaces a hauling task
	is_going_to_position = false
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
	energy = clamp(energy - structure.build_energy_required * delta, 0.0, 100.0)

## Every destination is snapped onto the navmesh here, so a raw prop / site / chase position (possibly in water or on a
## hut) can never make the path query start from or aim at a polygon that does not exist.
func set_new_destination(target: Vector3):
	if _off_navmesh:
		return # lost off the navmesh: no path queries until it is back
	var map_rid: RID = nav_agent.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		return # navmesh not synced yet: the policies ask again within half a second
	nav_agent.target_position = NavigationServer3D.map_get_closest_point(map_rid, target)

func _navigation_ready() -> bool:
	return not _initial_navigation_pending and NavigationServer3D.map_get_iteration_id(nav_agent.get_navigation_map()) != 0

# Safety net against a citizen being launched away (stacked spawn, a shove that piled up, a tumbling log): speed is capped,
# and one that ends up away from the navmesh (off the island) stops asking for paths -- see _tick_off_navmesh().
# It is NOT put back on land: it stays wherever it landed (and dies if it falls out of the world).
const MAX_FLAT_SPEED := 20.0
const MAX_UP_SPEED := 20.0
const OFF_NAVMESH_DISTANCE := 4.0 # metres from the nearest navmesh point before a citizen counts as off the navmesh
const STRAY_CHECK_INTERVAL := 0.5
var _stray_timer := 0.0
var _off_navmesh := false
func _guard_runaway(delta: float) -> void:
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() > MAX_FLAT_SPEED:
		flat = flat.limit_length(MAX_FLAT_SPEED)
		velocity.x = flat.x
		velocity.z = flat.y
	velocity.y = minf(velocity.y, MAX_UP_SPEED)
	_stray_timer -= delta
	if _stray_timer > 0.0:
		return
	_stray_timer = STRAY_CHECK_INTERVAL
	var map_rid: RID = nav_agent.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		return
	var closest := NavigationServer3D.map_get_closest_point(map_rid, global_position)
	_off_navmesh = closest.distance_to(global_position) > OFF_NAVMESH_DISTANCE

## The physics-only frame of a citizen that is off the navmesh: no navigation or path queries, no tasks.
func _tick_off_navmesh(delta: float, in_fluid: bool) -> void:
	_wanted_velocity = Vector3.ZERO
	steer_horizontal(Vector3.ZERO, delta)
	is_active = false
	_tick_vitals(delta)
	_before_slide()
	var fall_speed := -velocity.y
	move_and_slide()
	_apply_fall_damage(fall_speed, in_fluid)
	_push_colliding_bodies()
	_publish_net_state()
	_update_nameplate()
	_check_out_of_world()

## Can this citizen walk to `pos` on the current navmesh? Used to refuse an assignment up front instead of letting the
## citizen wander off and give up (the Policy Engine reports the refusal to the player).
func can_reach(pos: Vector3) -> bool:
	if _off_navmesh:
		return false
	var map_rid:RID = nav_agent.get_navigation_map()
	if not _navigation_ready():
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
	return is_gathering or is_building or is_pushing or is_eating or is_heading_to_rest or is_resting \
			or is_going_to_position or is_going_to_zone

func task_name() -> String:
	if is_eating: return "eating"
	if is_going_to_position: return "walking"
	if is_going_to_zone: return "walking to zone"
	if is_resting or is_heading_to_rest: return "resting"
	if is_pushing: return "pushing"
	if is_building: return "building"
	if is_gathering: return "gathering"
	if is_hauling: return "hauling"
	if is_wandering: return "wandering"
	return "idle"

## Not already eating, not in the middle of shoving a log (that is finished first), not sulking after giving up
func eat_ready() -> bool:
	return not is_eating and not is_pushing and _eat_retry_timer <= 0.0

## Not already in bed or on the way, not in the middle of shoving a log (that is finished first), not chasing the player,
## not sulking after failing to reach a shelter
func rest_ready() -> bool:
	return not is_resting and not is_heading_to_rest and not is_eating and not is_pushing \
			and not is_chasing_player and _rest_retry_timer <= 0.0

## At night, walk to the assigned shelter or a random shelter and sleep there until morning.
func start_resting() -> bool:
	if builder == null or is_resting or is_heading_to_rest or is_eating:
		return false
	var shelter_id: String = builder.pick_shelter(data.id)
	if shelter_id == builder.NO_ID:
		return false
	_rest_shelter_id = shelter_id
	_rest_elapsed = 0.0
	is_gathering = false # (the job / the policies pick the work up again in the morning)
	is_building = false
	is_going_to_position = false
	is_going_to_zone = false
	is_heading_to_rest = true
	set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.get_structure_position(shelter_id)))
	return true

func _stop_resting(retry_delay: float) -> void:
	is_resting = false # (Carrier.is_resting: energy stops recharging)
	collapsed = false
	is_heading_to_rest = false
	_rest_shelter_id = ""
	_rest_retry_timer = retry_delay

# Walks to the chosen shelter, then rests there until morning. Energy only recharges while is_resting (see Carrier._tick_vitals).
func _update_resting(delta: float) -> void:
	if builder == null:
		return
	if collapsed:
		# Passed out where they stood (see _collapse): out cold until rested enough, whatever the time of day. At night the
		# sleep need then walks them to bed. A shelter right there makes the sleep as good as a bed.
		sleeping_in_shelter = builder.is_near_shelter(global_position)
		if energy >= collapse_wake:
			_stop_resting(0.0)
		return
	if not is_heading_to_rest and not is_resting:
		_rest_retry_timer = maxf(_rest_retry_timer - delta, 0.0)
		return # whether to go to bed is an innate need (_update_needs -> start_resting)
	if not builder.is_night():
		_stop_resting(0.0) # morning: get up
		return
	if is_gathering or is_building or is_pushing or is_chasing_player:
		_stop_resting(0.0) # something else took over (a job handed out by hand, an angry chase)
		return
	if not builder.buildings.has(_rest_shelter_id):
		# The shelter was pulled down: pick another one, or give up if there is none left
		var other: String = builder.pick_shelter(data.id)
		if other == builder.NO_ID:
			_stop_resting(REST_RETRY_DELAY)
			return
		_rest_shelter_id = other
		_rest_elapsed = 0.0
		is_resting = false
		is_heading_to_rest = true
		set_new_destination(NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), builder.get_structure_position(other)))
		return
	if is_resting:
		return # in bed: stay put until morning
	_rest_elapsed += delta
	var shelter_pos: Vector3 = builder.get_structure_position(_rest_shelter_id)
	# Arrived: close enough to the shelter, or as close as the navmesh lets them get (a walled-in hut)
	if Builder.flat_distance(global_position, shelter_pos) <= builder.shelter_reach \
			or (_navigation_ready() and nav_agent.is_navigation_finished() and _rest_elapsed > 2.0):
		is_heading_to_rest = false
		is_resting = true
		sleeping_in_shelter = true
		set_new_destination(global_position) # stand still
		return
	if _rest_elapsed > REST_GIVE_UP_TIME:
		_stop_resting(REST_RETRY_DELAY) # can't get there (another random shelter is tried after the delay)

## The idle timer has run out and they are not standing still because an assignment was just refused
func wander_ready() -> bool:
	return idle_timer <= 0.0 and _stand_still_timer <= 0.0

## Amble off to a random spot when no policy or need has taken over.
func start_wander() -> void:
	set_new_destination(_wander_target(100.0))
	is_going_to_zone = false
	idle_timer = clamp(randf_range(0.0, data.happiness * 0.2), 5.0, 20.0)
	is_wandering = true
	_wander_elapsed = 0.0

func _update_wandering(delta: float) -> void:
	if not is_wandering:
		return
	_wander_elapsed += delta
	if is_gathering or is_building or is_pushing or is_eating or is_heading_to_rest or is_resting or is_going_to_position or is_chasing_player:
		is_wandering = false # something else took over
		return
	if (_wander_elapsed > 0.5 and _navigation_ready() and nav_agent.is_navigation_finished()) or _wander_elapsed > WANDER_TIMEOUT:
		is_wandering = false

## Action GO_TO_ZONE: walk to the nearest tile of `zone`. False (so the next action of the rule is tried) when nothing is
## zoned that way, when the policies keep this citizen out of it, or when they are already standing in it.
func start_go_to_zone(zone: int) -> bool:
	if builder == null or not builder.zones.has_any(zone) or builder.zone_at(global_position) == zone:
		return false
	if is_going_to_zone and _go_zone == zone:
		return true
	if _go_zone_retry_timer > 0.0 and _failed_go_zone == zone:
		return false
	if not _navigation_ready():
		return false
	var spot: Vector3 = builder.nearest_zone_point(zone, global_position)
	if not PolicyEngine.is_permitted(self, Action.Activity.ENTER, spot):
		return false
	is_wandering = false
	is_going_to_position = false
	is_going_to_zone = true
	_go_zone = zone
	_go_zone_elapsed = 0.0
	set_new_destination(spot)
	return true

func _update_going_to_zone(delta: float) -> void:
	_go_zone_retry_timer = maxf(_go_zone_retry_timer - delta, 0.0)
	if not is_going_to_zone:
		return
	_go_zone_elapsed += delta
	if is_gathering or is_building or is_pushing or is_eating or is_heading_to_rest or is_resting \
			or is_going_to_position or is_chasing_player:
		is_going_to_zone = false
		return
	if builder == null or not builder.zones.has_any(_go_zone) or builder.zone_at(global_position) == _go_zone:
		is_going_to_zone = false
		nav_agent.target_position = global_position
		return
	if _go_zone_elapsed > GO_TO_TIMEOUT:
		is_going_to_zone = false
		_failed_go_zone = _go_zone
		_go_zone_retry_timer = UNREACHABLE_RETRY_TIME
		nav_agent.target_position = global_position

## Action GO_TO_POSITION: drop whatever they were doing and walk to a spot the player clicked. Refused (with the reason in
## PolicyEngine.last_failure) if the policies keep this citizen out of that spot or the navmesh has no way there.
func start_go_to_position(pos: Vector3) -> bool:
	if builder == null:
		return false
	if collapsed:
		PolicyEngine.last_failure = "They are out cold from exhaustion."
		return false
	if not PolicyEngine.is_permitted(self, Action.Activity.ENTER, pos):
		PolicyEngine.last_failure = "That area is off limits."
		return false
	if not can_reach(pos):
		PolicyEngine.last_failure = "That spot is unreachable."
		return false
	# Leave the current task (a log in the arms is dropped by _hold_carried once pushing stops; a site keeps its builder slot, like eating)
	is_gathering = false
	gather_target_id = NO_ID
	is_building = false
	is_pushing = false
	push_target = null
	is_hauling = false
	is_going_to_zone = false
	if is_resting or is_heading_to_rest:
		_stop_resting(0.0)
	_go_target = NavigationServer3D.map_get_closest_point(nav_agent.get_navigation_map(), pos)
	_go_elapsed = 0.0
	is_going_to_position = true
	set_new_destination(_go_target)
	return true

func _update_going_to_position(delta: float) -> void:
	if not is_going_to_position:
		return
	_go_elapsed += delta
	if is_gathering or is_building or is_pushing or is_eating or is_heading_to_rest or is_resting:
		is_going_to_position = false # something else took over
		return
	var arrived: bool = Builder.flat_distance(global_position, _go_target) <= GO_TO_REACH \
			or (_go_elapsed > 0.5 and _navigation_ready() and nav_agent.is_navigation_finished()) # (not on the first frames: the path may not exist yet)
	if arrived or _go_elapsed > GO_TO_TIMEOUT:
		is_going_to_position = false
		nav_agent.target_position = global_position # stand here; the idle timer decides when wandering resumes
		idle_timer = clamp(randf_range(0.0, data.happiness * 0.2), 5.0, 20.0)

func _update_policies(delta: float) -> void:
	if manual_task and not (is_gathering or is_building or is_pushing or is_hauling or is_eating or is_heading_to_rest or is_resting or is_going_to_position or is_going_to_zone):
		manual_task = false # the task the player gave them is finished
	_policy_timer -= delta
	if _policy_timer > 0.0:
		return
	_policy_timer = POLICY_INTERVAL
	if _update_needs():
		return # the body comes first: no policy gets to overrule hunger, exhaustion or bedtime
	if PolicyEngine.think(self):
		return
	# No tradition or rule had anything for them to do: an idle citizen ambles about (innate, not a policy)
	if not manual_task and not is_busy() and wander_ready():
		start_wander()

# --- Innate needs -------------------------------------------------------------
# Not policies: every citizen does these whatever the player's rules say, and a task handed out by hand does not stop them.
# In order of urgency: pass out when exhausted, eat when hungry, sleep at night.

## hungry, food in stock, not already eating / shoving a log / sulking after giving up
func _wants_to_eat() -> bool:
	return builder != null and hunger < builder.hungry_below and builder.has_food() and eat_ready()

## Returns true if a need just took over (or the citizen is out cold), so the policies sit this tick out.
func _update_needs() -> bool:
	if builder == null:
		return false
	if collapsed:
		if energy < collapse_wake:
			return true
		_stop_resting(0.0)
	if energy <= collapse_below:
		_collapse()
		return true
	if is_eating:
		return true
	if _wants_to_eat() and start_eating():
		return true
	if is_resting or is_heading_to_rest:
		return true
	if builder.is_night() and not builder.shelter_ids().is_empty() and rest_ready():
		return start_resting()
	return false

## Energy ran out: drop everything and pass out where they stand until energy is back above collapse_wake. Sleeping out in
## the open recharges at Carrier.outdoor_sleep_mult of the rate in bed (the player's version lives in player.gd).
func _collapse() -> void:
	is_gathering = false
	is_building = false
	is_pushing = false
	push_target = null
	is_eating = false
	_eat_resume = ""
	is_going_to_position = false
	is_going_to_zone = false
	is_heading_to_rest = false
	is_wandering = false
	collapsed = true
	is_resting = true
	is_chasing_player = false
	_wanted_velocity = Vector3.ZERO
	sleeping_in_shelter = builder.is_near_shelter(global_position)
	set_new_destination(global_position) # stand still

# --- Jobs -------------------------------------------------------------------

# Called by PolicyEngine when the citizen is employed at a workplace.
func set_job(title: String, task: int, workplace_id: String) -> void:
	data.job = title
	data.job_task = task
	data.workplace_id = workplace_id
	gather_filter = "wood" if task == Structure.JobTask.GATHER else ("food" if task == Structure.JobTask.FORAGE else "")
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
	if is_gathering or is_building or is_pushing or is_hauling or is_eating or is_heading_to_rest or is_resting or is_going_to_position:
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

# --- Reproduction -----------------------------------------------------------

# Counts in-game days (the day clock, so a stopped clock stops this too) during which health AND hunger are both above
# Builder.birth_min_stat. Every Builder.birth_interval_days of that is one try at a child; whether it happens is Builder.try_birth's
# dice roll. The count starts over after each try, and whenever either stat dips to the threshold or below.
func _update_reproduction() -> void:
	if builder == null or Globals.day_night == null:
		return
	var now := Globals.game_days()
	var days_passed := 0.0 if _last_birth_clock < 0.0 else maxf(now - _last_birth_clock, 0.0)
	_last_birth_clock = now
	if health <= builder.birth_min_stat or hunger <= builder.birth_min_stat:
		_thriving_days = 0.0
		return
	_thriving_days += days_passed
	if _thriving_days < builder.birth_interval_days:
		return
	_thriving_days = 0.0
	builder.try_birth(self)

# Wander targets used to be raw random points with no regard for whether the navmesh
# actually covers that spot
# A random spot to amble to. Spots the policies keep this citizen out of (a restricted zone) are re-rolled a few times.
func _wander_target(nav_range: float) -> Vector3:
	var target: Vector3 = _pick_wander_point(nav_range)
	for i in 6:
		if PolicyEngine.is_permitted(self, Action.Activity.ENTER, target):
			break
		target = _pick_wander_point(nav_range)
	return target

func _pick_wander_point(nav_range: float) -> Vector3:
	var raw = global_position + Vector3(randf_range(-nav_range, nav_range), 0, randf_range(-nav_range, nav_range))
	var map_rid = nav_agent.get_navigation_map()
	# If map not synced yet, return raw (unsnapped) point
	if NavigationServer3D.map_get_iteration_id(map_rid) == 0:
		return raw
	return NavigationServer3D.map_get_closest_point(map_rid, raw)

var _shown_name := "\n" # impossible name, so the first update always draws
var _shown_health := -1
var _shown_hunger := -1
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
	var hunger_pct := roundi(hunger)
	var energy_pct := roundi(energy)
	if health_pct != _shown_health or hunger_pct != _shown_hunger or energy_pct != _shown_energy:
		_shown_health = health_pct
		_shown_hunger = hunger_pct
		_shown_energy = energy_pct
		nameplate.set_stats(health_pct, hunger_pct, energy_pct)

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
	net_hunger = snappedf(hunger, 0.1)
	net_energy = snappedf(energy, 0.1)
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
	hunger = net_hunger
	energy = net_energy
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
