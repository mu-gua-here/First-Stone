extends Resource
class_name Action

## An Action describes "do this thing", dispatched by PolicyEngine.execute().
## `target_query` is how PolicyEngine finds *what to act on* (a building, a
## gatherable node, a construction site) when the action needs a target beyond
## the subject itself -- e.g. ASSIGN_JOB needs to find a workplace.
##
## For manual (UI-driven) actions, the target is already known (the player
## clicked it), so the UI constructs the Action with target_query left unused
## and instead pre-resolves the target itself before calling execute(). See
## PolicyEngine.execute() for how the two paths reconcile.

## New kinds go at the END (saved policies store the number).
## ALLOW / FORBID are PERMISSION actions: they never run, PolicyEngine.is_permitted() reads them (see Policy).
## GO_TO_ZONE walks to the nearest tile of `zone`.
## GO_TO_POSITION walks to a world position the player clicked (manual only: the Vector3 is the resolved_target).
enum Kind { ASSIGN_JOB, ASSIGN_HOUSING, ASSIGN_GATHER, ASSIGN_BUILD_TASK, ASSIGN_HAUL, EAT, WANDER, REST, ALLOW, FORBID, GO_TO_ZONE, GO_TO_POSITION }

## What a permission is about. ENTER = stand on / walk through the tile; the others are the work a citizen does there.
enum Activity { ENTER, CHOP, PICK_FRUIT, BUILD }

@export var kind: Kind
@export var target_query: Condition  # how to find the building/node to assign *to* (policy path)
## ALLOW / FORBID: what is allowed or forbidden
@export var activity: Activity = Activity.ENTER
## ALLOW / FORBID / GO_TO_ZONE: the zone type (ZoneMap.Type) it concerns
@export var zone: int = ZoneMap.Type.RESTRICTED

func is_permission() -> bool:
	return kind == Kind.ALLOW or kind == Kind.FORBID


static func new_assign_job() -> Action:
	var a := Action.new()
	a.kind = Kind.ASSIGN_JOB
	return a

static func new_assign_housing() -> Action:
	var a := Action.new()
	a.kind = Kind.ASSIGN_HOUSING
	return a

static func new_assign_gather() -> Action:
	var a := Action.new()
	a.kind = Kind.ASSIGN_GATHER
	return a

static func new_assign_build_task() -> Action:
	var a := Action.new()
	a.kind = Kind.ASSIGN_BUILD_TASK
	return a

## Push loose logs to the stockpile (a standing task, see Citizen._start_hauling)
static func new_assign_haul() -> Action:
	var a := Action.new()
	a.kind = Kind.ASSIGN_HAUL
	return a

## Legacy action ID. Eating is now handled as an innate citizen need.
static func new_eat() -> Action:
	var a := Action.new()
	a.kind = Kind.EAT
	return a

## Legacy action ID. Idle wandering is now handled by the citizen's innate behavior.
static func new_wander() -> Action:
	var a := Action.new()
	a.kind = Kind.WANDER
	return a

## Legacy action ID. Nighttime sheltering is now handled as an innate citizen need.
static func new_rest() -> Action:
	var a := Action.new()
	a.kind = Kind.REST
	return a

## Permission: `p_activity` is allowed in zones of type `p_zone`
static func new_allow(p_activity: Activity, p_zone: int) -> Action:
	var a := Action.new()
	a.kind = Kind.ALLOW
	a.activity = p_activity
	a.zone = p_zone
	return a

## Permission: `p_activity` is forbidden in zones of type `p_zone`
static func new_forbid(p_activity: Activity, p_zone: int) -> Action:
	var a := Action.new()
	a.kind = Kind.FORBID
	a.activity = p_activity
	a.zone = p_zone
	return a

## Walk to a clicked world position (see Citizen.start_go_to_position). The position is passed as the resolved_target.
static func new_go_to_position() -> Action:
	var a := Action.new()
	a.kind = Kind.GO_TO_POSITION
	return a

## Walk to the nearest tile of a zone (see Citizen.start_go_to_zone)
static func new_go_to_zone(p_zone: int) -> Action:
	var a := Action.new()
	a.kind = Kind.GO_TO_ZONE
	a.zone = p_zone
	return a
