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

enum Kind { ASSIGN_JOB, ASSIGN_HOUSING, ASSIGN_GATHER, ASSIGN_BUILD_TASK, ASSIGN_HAUL, EAT, WANDER, REST }

@export var kind: Kind
@export var target_query: Condition  # how to find the building/node to assign *to* (policy path)


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

## Walk to the stockpile and eat until full (see Citizen.start_eating). Used by the "Eat when hungry" tradition.
static func new_eat() -> Action:
	var a := Action.new()
	a.kind = Kind.EAT
	return a

## Amble off to a random spot (see Citizen.start_wander). Used by the "Wander when idle" tradition.
static func new_wander() -> Action:
	var a := Action.new()
	a.kind = Kind.WANDER
	return a

## Walk to a shelter and rest there (see Citizen.start_resting). Used by the "Sleep in a shelter at night" tradition.
static func new_rest() -> Action:
	var a := Action.new()
	a.kind = Kind.REST
	return a
