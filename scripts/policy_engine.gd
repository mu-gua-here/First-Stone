extends Node

## PolicyEngine -- where players design their own policies to "automate" repetitive actions on citizens
##
##   "given a Condition and an Action, find all Subjects (citizens, buildings,
##    resource nodes) matching the Condition, and perform the Action on them."
##
## A manual player action is this engine invoked once, with the Subject
## already chosen by the click. A policy (Milestone B) is this engine invoked
## on a timer, searching all Subjects for matches. Both paths call evaluate()/
## execute() -- nothing about "what an action does" should ever be written
## twice (once for the click handler, once for the policy runner).
##
## Registered as an autoload singleton so both the manual UI and the future
## PolicyManager can reach it without a node reference.

# --- Field lookup table -----------------------------------------------
#
# Maps a string field name (as typed/selected by the player) to a Callable
# that extracts that field's value from a subject. Kept as a small table
# rather than an enum so new fields (new citizen stats, new building stats)
# can be added in one place without touching Condition itself.
#
# Each getter must be defensive: return null for a subject it doesn't apply
# to (e.g. asking a BuildingInstance for "age"), and evaluate() treats a null
# getter result as "condition fails safely" rather than crashing.

const _CITIZEN_FIELDS := {
	"age": "_get_citizen_age",
	"hunger": "_get_citizen_hunger",       # how well fed (100 = full), see Carrier
	"energy": "_get_citizen_energy",       # how rested (100 = fresh), see Carrier
	"happiness": "_get_citizen_happiness",
	"health": "_get_citizen_health",
	"job": "_get_citizen_job",
	"job_satisfaction": "_get_citizen_job_satisfaction",
	"housing_satisfaction": "_get_citizen_housing_satisfaction",
	"approval": "_get_citizen_approval",
	# Situation fields the default traditions read (see citizen.gd). Booleans/strings the engine derives for the
	# citizen so a rule can say "WHEN [Hungry] is [true]" without knowing any thresholds.
	"hungry": "_get_citizen_hungry",            # hunger below Builder.hungry_below
	"food_available": "_get_citizen_food_available", # the stockpile has food
	"eat_ready": "_get_citizen_eat_ready",       # not already eating, not mid-shove, not sulking after giving up
	"is_night": "_get_citizen_is_night",         # between Builder.night_starts and Builder.night_ends
	"shelter_available": "_get_citizen_shelter_available", # the settlement has at least one shelter (a house)
	"rest_ready": "_get_citizen_rest_ready",     # not already resting, not mid-shove, not sulking after failing to reach a shelter
	"busy": "_get_citizen_busy",                 # chopping, building, pushing a log, eating or resting
	"wander_ready": "_get_citizen_wander_ready", # the idle timer ran out
	"task": "_get_citizen_task",                 # "idle", "gathering", "building", "pushing", "hauling", "eating", "resting"
	"zone": "_get_citizen_zone",                 # the zone the citizen stands in: a ZoneMap item name ("restricted", "gathering"...) or "none"
}

const _BUILDING_FIELDS := {
	"type": "_get_building_type",
	"capacity": "_get_building_capacity",
	"worker_count": "_get_building_worker_count",
	"resident_count": "_get_building_resident_count",
	"residential_floors": "_get_building_residential_floors",
}


# --- evaluate / find_matches -------------------------------------------

## Recursively resolves a Condition tree against a single subject.
## Returns false (never crashes) if the field/subject combination is unknown.
func evaluate(condition: Condition, subject) -> bool:
	if condition == null:
		return true # no condition == match everything, used by always_true()

	match condition.kind:
		Condition.Kind.AND:
			for child in condition.children:
				if not evaluate(child, subject):
					return false
			return true

		Condition.Kind.OR:
			if condition.children.is_empty():
				return false
			for child in condition.children:
				if evaluate(child, subject):
					return true
			return false

		Condition.Kind.NOT:
			if condition.children.is_empty():
				return false
			return not evaluate(condition.children[0], subject)

		Condition.Kind.LEAF:
			return _evaluate_leaf(condition, subject)

	return false

func _evaluate_leaf(condition: Condition, subject) -> bool:
	var actual = _get_field(subject, condition.field)
	if actual == null:
		return false # unknown field for this subject type -- fail safely

	return _compare(actual, condition.op, condition.value)

func _compare(actual, op: String, expected) -> bool:
	match op:
		"==":
			return actual == expected
		"!=":
			return actual != expected
		"<":
			return actual < expected
		">":
			return actual > expected
		"<=":
			return actual <= expected
		">=":
			return actual >= expected
	push_warning("PolicyEngine: unknown operator '%s'" % op)
	return false

## Filters a pool of subjects (citizens, BuildingInstances, etc.) down to the
## ones matching condition. `pool` can be any Array -- callers decide what
## population to search (e.g. builder.citizens, builder.buildings.values()).
func find_matches(condition: Condition, pool: Array) -> Array:
	var matches: Array = []
	for subject in pool:
		if evaluate(condition, subject):
			matches.append(subject)
	return matches


# --- field getters -------------------------------------------------------
#
# Subjects in this game are either citizen nodes (CharacterBody3D with a
# `.data: CitizenData`) or BuildingInstance resources. Dispatch on subject
# shape rather than a Subject base class, since citizen.gd and
# BuildingInstance are unrelated types we don't want to touch the
# inheritance of.

func _get_field(subject, field: String):
	if subject == null:
		return null

	if _is_citizen(subject):
		if _CITIZEN_FIELDS.has(field):
			return call(_CITIZEN_FIELDS[field], subject)
		return null

	if subject is BuildingInstance:
		if _BUILDING_FIELDS.has(field):
			return call(_BUILDING_FIELDS[field], subject)
		return null

	return null

func _is_citizen(subject) -> bool:
	return subject is Node and subject.is_in_group("citizen")

func _get_citizen_age(citizen): return citizen.data.age
# The stats live on the citizen's body (Carrier), not on its CitizenData
func _get_citizen_hunger(citizen): return citizen.hunger
func _get_citizen_energy(citizen): return citizen.energy
func _get_citizen_happiness(citizen): return citizen.data.happiness
func _get_citizen_health(citizen): return citizen.health
func _get_citizen_job(citizen): return citizen.data.job
func _get_citizen_job_satisfaction(citizen): return citizen.data.job_satisfaction
func _get_citizen_housing_satisfaction(citizen): return citizen.data.housing_satisfaction
func _get_citizen_approval(citizen): return citizen.data.approval
func _get_citizen_hungry(citizen):
	var b = _builder()
	return b != null and citizen.hunger < b.hungry_below
func _get_citizen_food_available(_citizen):
	var b = _builder()
	return b != null and b.has_food()
func _get_citizen_eat_ready(citizen): return citizen.eat_ready()
func _get_citizen_is_night(_citizen):
	var b = _builder()
	return b != null and b.is_night()
func _get_citizen_shelter_available(_citizen):
	var b = _builder()
	return b != null and not b.shelter_ids().is_empty()
func _get_citizen_rest_ready(citizen): return citizen.rest_ready()
func _get_citizen_busy(citizen): return citizen.is_busy()
func _get_citizen_wander_ready(citizen): return citizen.wander_ready()
func _get_citizen_task(citizen): return citizen.task_name()
func _get_citizen_zone(citizen):
	var b = _builder()
	if b == null:
		return null
	var item := ZoneMap.item_name(b.zone_at(citizen.global_position))
	return item if item != "" else "none"

# BuildingInstance doesn't carry a back-reference to its Structure, so these
# getters need the owning Builder to resolve structure_index -> Structure.
# We resolve it through Globals.builder (registered by Builder._ready) rather
# than threading a builder reference through every BuildingInstance.
func _builder():
	return Globals.builder

func _get_building_type(instance: BuildingInstance):
	var b = _builder()
	if b == null or instance.structure_index < 0 or instance.structure_index >= b.structures.size():
		return null
	return b.structures[instance.structure_index].type

func _get_building_capacity(instance: BuildingInstance):
	var b = _builder()
	if b == null or instance.structure_index < 0 or instance.structure_index >= b.structures.size():
		return null
	return b.structures[instance.structure_index].capacity

func _get_building_worker_count(instance: BuildingInstance):
	return instance.workers.size()

func _get_building_resident_count(instance: BuildingInstance):
	return instance.residents.size()

func _get_building_residential_floors(instance: BuildingInstance):
	var b = _builder()
	if b == null or instance.structure_index < 0 or instance.structure_index >= b.structures.size():
		return null
	return b.structures[instance.structure_index].residential_floors


# --- execute --------------------------------------------------------------

## Why the most recent execute() was refused ("" if it wasn't, or no reason was given). The UI shows this to the
## player in red, like the build cursor's "can't build here" messages. Online the server sends it back with its answer.
var last_failure := ""
const UNREACHABLE_PAUSE := 4.0 # seconds a citizen stands still after being sent somewhere they can't walk to

## Dispatches an Action against a subject. This routes through the EXISTING
## builder methods (has_housing_for, request_job, etc.) per the plan -- this
## milestone does not rewrite those, it's the single place both manual clicks
## and (later) policies funnel through.
##
## `resolved_target` is optional: when the UI already knows the target
## (e.g. the player clicked a specific building), pass it here and execute()
## uses it directly instead of searching via action.target_query. Policies
## (Milestone B) leave this null and let execute() search.
func execute(action: Action, subject, resolved_target = null) -> bool:
	last_failure = ""
	var ok := _dispatch(action, subject, resolved_target)
	# A task the player handed a citizen by hand: ordinary policies leave that citizen alone until it is done.
	# Innate needs are handled by Citizen before the policy engine runs. See Policy.survival and think().
	if ok and resolved_target != null and _is_citizen(subject) and action != null \
			and action.kind in [Action.Kind.ASSIGN_GATHER, Action.Kind.ASSIGN_BUILD_TASK, Action.Kind.ASSIGN_HAUL, Action.Kind.GO_TO_POSITION]:
		subject.manual_task = true
	return ok

func _dispatch(action: Action, subject, resolved_target = null) -> bool:
	if action == null or subject == null:
		return false

	var b = _builder()
	if b == null:
		push_warning("PolicyEngine.execute: no Builder found in scene tree")
		return false

	match action.kind:
		Action.Kind.ASSIGN_JOB:
			return _execute_assign_job(b, subject, resolved_target)

		Action.Kind.ASSIGN_HOUSING:
			return _execute_assign_housing(b, subject, resolved_target)

		Action.Kind.ASSIGN_GATHER:
			return _execute_assign_gather(b, subject, resolved_target)

		Action.Kind.ASSIGN_BUILD_TASK:
			return _execute_assign_build_task(b, subject, resolved_target)

		Action.Kind.ASSIGN_HAUL:
			return _execute_assign_haul(b, subject, resolved_target)

		Action.Kind.EAT, Action.Kind.WANDER, Action.Kind.REST:
			return false # Legacy action IDs remain loadable, but needs and idle wandering are innate behavior.

		Action.Kind.GO_TO_ZONE:
			return _is_citizen(subject) and subject.has_method("start_go_to_zone") and subject.start_go_to_zone(action.zone)

		Action.Kind.GO_TO_POSITION:
			return _execute_go_to_position(subject, resolved_target)

		Action.Kind.ALLOW, Action.Kind.FORBID:
			return false # permissions are read by is_permitted(); they are never "run"

	push_warning("PolicyEngine.execute: unhandled Action.Kind %s" % action.kind)
	return false

## resolved_target, when given, is a specific BuildingInstance the caller
## already picked (the manual click path -- A.3). With no resolved_target,
## searches for the nearest workplace (by placed position) with a free
## slot -- this is what a Milestone B policy with no specific target_query
## will use. NOTE: builder.gd has no request_job()/has_housing_for() any
## more (post-GridMap rewrite) -- this searches b.buildings directly.
func _execute_assign_job(b, citizen, resolved_target = null) -> bool:
	if not _is_citizen(citizen):
		return false

	var target: BuildingInstance = resolved_target if resolved_target is BuildingInstance else _find_nearest_building_with_free_slot(b, citizen.global_position, Structure.Type.WORKPLACE)
	if target == null:
		return false

	var structure: Structure = b.structures[target.structure_index]
	if structure.type != Structure.Type.WORKPLACE:
		return false
	if target.workers.size() >= structure.capacity:
		return false # no free slot at this specific building
	if citizen.data.id in target.workers:
		return true # already assigned here
	# One job at a time: leave any previous workplace first
	b.release_job(citizen.data.id)
	target.workers.append(citizen.data.id)
	citizen.set_job(structure.get_job_title(), structure.job_task, target.id)
	return true

## See _execute_assign_job for the resolved_target / search-fallback split.
func _execute_assign_housing(b, citizen, resolved_target = null) -> bool:
	if not _is_citizen(citizen):
		return false

	var target: BuildingInstance = resolved_target if resolved_target is BuildingInstance else _find_nearest_building_with_free_slot(b, citizen.global_position, Structure.Type.HOUSE)
	if target == null:
		return false

	var structure: Structure = b.structures[target.structure_index]
	if structure.residential_floors <= 0:
		return false
	if target.residents.size() >= structure.residential_floors:
		return false # no free slot at this specific building
	if citizen.data.id in target.residents:
		return true # already housed here
	# One home at a time: leave any previous house first
	b.release_housing(citizen.data.id)
	target.residents.append(citizen.data.id)
	return true

## Nearest BuildingInstance of `type` (by placed world position, see
## b.get_structure_position()) that still has a free worker/resident slot,
## or null. Shared by the no-resolved_target ( policy ) path of both
## _execute_assign_job and _execute_assign_housing.
func _find_nearest_building_with_free_slot(b, pos: Vector3, type: int) -> BuildingInstance:
	var nearest: BuildingInstance = null
	var nearest_dist := INF
	for id in b.buildings.keys():
		var instance: BuildingInstance = b.buildings[id]
		var structure: Structure = b.structures[instance.structure_index]
		if structure.type != type:
			continue
		var has_room: bool
		if type == Structure.Type.WORKPLACE:
			has_room = instance.workers.size() < structure.capacity
		else:
			has_room = instance.residents.size() < structure.residential_floors
		if not has_room:
			continue
		var dist = pos.distance_squared_to(b.get_structure_position(id))
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = instance
	return nearest

## resolved_target, when given, is the specific placed-structure String id
## (see Builder.placed_structures) the player clicked (manual path -- A.3).
## Pass it directly to the citizen so they walk to that exact tree, not
## whatever happens to be nearest. Policy path (no resolved_target) falls
## back to the citizen finding the nearest gatherable themselves.
func _execute_assign_gather(b, citizen, resolved_target = null) -> bool:
	if not _is_citizen(citizen):
		return false
	if resolved_target is String and resolved_target != b.NO_ID:
		if citizen.has_method("can_reach") and not citizen.can_reach(b.get_structure_position(resolved_target)):
			last_failure = "That target is unreachable."
			if citizen.has_method("stand_still"):
				citizen.stand_still(UNREACHABLE_PAUSE)
			return false
		if citizen.has_method("_start_gathering_at"):
			citizen._start_gathering_at(resolved_target)
			return true
		return false
	if citizen.has_method("_start_gathering"):
		citizen._start_gathering()
		return true
	return false

## Manual order: walk to the world position the player clicked (resolved_target is that Vector3). Refused, with a reason
## the HUD shows, if the spot is off limits or the citizen can't walk there.
func _execute_go_to_position(citizen, resolved_target) -> bool:
	if not _is_citizen(citizen) or not resolved_target is Vector3 or not citizen.has_method("start_go_to_position"):
		return false
	return citizen.start_go_to_position(resolved_target)

## Standing task: push loose logs to the stockpile. resolved_target, when given, is the name of the log the
## player clicked (it is hauled first); without one the citizen starts with the nearest loose log.
## Always succeeds -- a hauler with no logs to move just waits for the choppers to make some.
func _execute_assign_haul(_b, citizen, resolved_target = null) -> bool:
	if not _is_citizen(citizen) or not citizen.has_method("_start_hauling"):
		return false
	citizen._start_hauling(resolved_target if resolved_target is String else "")
	return true

# --- Policies ---------------------------------------------------------------
#
# The active rule book, highest priority first. For now it only holds the Default Traditions below; the policy
# editor will add / edit / disable entries here, and the whole list is plain Resources so it can be saved and sent
# to clients. Citizens run on the server / offline only, so this never needs to exist on a client.

var policies: Array[Policy] = []

## Emitted whenever the rule book changes (a rule added, removed, reordered, reset or edited in the policy editor).
## The save system can listen to this to know the rules need saving.
signal policies_changed

## Which tiers of fields the player may use in new conditions (see PolicyCatalog). Research / administration buildings
## call unlock_tier() as the society advances; rules that already use a locked field keep running.
var unlocked_tiers: Array[String] = [PolicyCatalog.TIER_PHYSICAL, PolicyCatalog.TIER_SITUATION]

func _ready() -> void:
	_install_default_traditions()

func add_policy(policy: Policy) -> void:
	policies.append(policy)
	policies.sort_custom(func(a: Policy, b: Policy) -> bool: return a.priority > b.priority)
	policies_changed.emit()

func unlock_tier(tier: String) -> void:
	if not tier in unlocked_tiers:
		unlocked_tiers.append(tier)
		policies_changed.emit()

func is_field_unlocked(field: String) -> bool:
	return PolicyCatalog.field_tier(field) in unlocked_tiers

## Public read of a subject's field (the editor's Data Hub and live preview use this)
func get_field(subject, field: String):
	return _get_field(subject, field)

## Default Traditions can be switched off but never deleted
func remove_policy(policy: Policy) -> void:
	if policy == null or policy.is_default:
		return
	policies.erase(policy)
	policies_changed.emit()

## direction -1 = runs earlier (higher priority), +1 = runs later. Priorities are only an ordering, so they are renumbered.
func move_policy(policy: Policy, direction: int) -> void:
	var i := policies.find(policy)
	var j := i + direction
	if i < 0 or j < 0 or j >= policies.size():
		return
	policies.remove_at(i)
	policies.insert(j, policy)
	var n := policies.size()
	for k in n:
		policies[k].priority = (n - k) * 10
	policies_changed.emit()

## Throws away every rule (including the player's own) and restores the starting traditions
func reset_to_default_traditions() -> void:
	policies.clear()
	_install_default_traditions()
	policies_changed.emit()

## The settlement's starting rules ("Default Traditions" in the design doc): customs every new civilisation begins with, so the
## editor is never a blank canvas. Hunger, exhaustion and bedtime are NOT traditions: they are innate (see Citizen._update_needs and
## Player), so what is left here is how the community arranges itself.
func _install_default_traditions() -> void:
	# Gather at the gathering area: idle citizens (not working, eating, sleeping or out for a stroll) walk to the designated
	# gathering area, the blue zone in front of the notice board, and stay there. Without a gathering zone (or once they stand in
	# it) this has nothing to do and they amble about on their own. A tradition like any other: the player can edit or disable it.
	var gather_when: Array[Condition] = [
		Condition.leaf("busy", "==", false),
		Condition.leaf("zone", "!=", ZoneMap.item_name(ZoneMap.Type.GATHERING)),
	]
	var gather := Policy.new()
	gather.policy_name = "Gather at the gathering area"
	gather.priority = 10
	gather.is_default = true
	gather.only_when_idle = true
	gather.condition = Condition.op_and(gather_when)
	gather.actions.append(Action.new_go_to_zone(ZoneMap.Type.GATHERING))
	add_policy(gather)



	# Restricted areas: nobody enters, chops, picks fruit or builds there. A permission policy (it never "runs"), so it
	# sits above the gathering tradition only to be ordered against the player's own rules: put an ALLOW for some citizens
	# above it and they are let in. The player can switch it off but not delete it.
	var restricted := Policy.new()
	restricted.policy_name = "Restricted areas are off limits"
	restricted.priority = 95
	restricted.is_default = true
	restricted.condition = Condition.always_true()
	for activity in [Action.Activity.ENTER, Action.Activity.CHOP, Action.Activity.PICK_FRUIT, Action.Activity.BUILD]:
		restricted.actions.append(Action.new_forbid(activity, ZoneMap.Type.RESTRICTED))
	add_policy(restricted)

## One decision for one citizen: the first enabled policy (highest priority first) whose condition matches and whose
## action applies is run. While the citizen is on a task the player gave them by hand, only survival policies
## are considered (`survival_only` does the same without a manual task: used between two logs, where only a bite to
## eat is worth interrupting for). Returns true if some policy ran. Called by Citizen about twice a second.
func think(citizen, survival_only: bool = false) -> bool:
	if not _is_citizen(citizen):
		return false
	var saved_failure := last_failure # a policy that does not apply must not wipe the reason the HUD is about to show
	var ran := false
	for policy in policies:
		if not policy.enabled or ((citizen.manual_task or survival_only) and not policy.survival):
			continue
		if policy.only_when_idle and citizen.is_busy():
			continue
		if evaluate(policy.condition, citizen) and _run_behaviour(policy, citizen):
			ran = true
			break
	last_failure = saved_failure
	return ran

## Tries a policy's behaviour actions in order and stops at the first one that applies (permission actions are skipped:
## see is_permitted). Returns true if one ran.
func _run_behaviour(policy: Policy, citizen) -> bool:
	for a in policy.actions:
		if a == null or a.is_permission():
			continue
		if _dispatch(a, citizen):
			return true
	return false

## May this citizen do `activity` (an Action.Activity) at world position `pos`? Only the zone on that tile matters, so a tile
## with no zone is always fine. Policies are read from the highest priority down; the first enabled one whose condition
## matches the citizen AND that mentions this activity in this zone decides it (a FORBID beats an ALLOW inside one policy).
## No policy saying anything = allowed. Used by Builder / Citizen before choosing what to chop, pick, build or walk to.
func is_permitted(citizen, activity: int, pos: Vector3) -> bool:
	var b = _builder()
	if b == null or citizen == null:
		return true
	var zone: int = b.zone_at(pos)
	if zone == ZoneMap.Type.NONE:
		return true
	for policy in policies:
		if not policy.enabled:
			continue
		var allowed := false
		var forbidden := false
		for a in policy.actions:
			if a == null or not a.is_permission() or a.activity != activity or a.zone != zone:
				continue
			if a.kind == Action.Kind.FORBID:
				forbidden = true
			else:
				allowed = true
		if not forbidden and not allowed:
			continue # this policy says nothing about it: don't even evaluate its condition
		if not evaluate(policy.condition, citizen):
			continue
		return not forbidden
	return true

## resolved_target, when given, is a specific construction site's String id
## (see Builder.construction_sites) the caller already picked (manual click
## -- A.3). With no resolved_target, searches via
## b.get_nearest_construction_site() from the citizen's current position,
## which is what a Milestone B policy with no specific target_query will use.
func _execute_assign_build_task(b, citizen, resolved_target = null) -> bool:
	if not _is_citizen(citizen):
		return false

	var site_id: String
	if resolved_target is String and resolved_target != b.NO_ID:
		site_id = resolved_target
	else:
		site_id = b.get_nearest_construction_site(citizen.global_position, citizen)
		if site_id == b.NO_ID:
			return false # nothing under construction right now

	if not b.assign_builder_to_site(citizen.data.id, site_id):
		return false

	if citizen.has_method("_start_building"):
		citizen._start_building(site_id)
	return true
