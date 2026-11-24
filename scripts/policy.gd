extends Resource
class_name Policy

## A Policy is one rule: "WHEN [condition on a citizen] THEN [action, action, ...]".
## PolicyEngine.think(citizen) walks the active policies from the highest priority down and runs the first one
## whose condition matches and which has a behaviour action that actually applies. This is the same Condition / Action
## pair the manual assignment path uses, so a click in CitizenSelector and a rule in the policy editor both end up in
## PolicyEngine.execute().
##
## A policy holds a LIST of actions, of two kinds (see Action.is_permission):
##  - behaviour actions (eat, gather, go to a zone...): tried in order, the first one that applies is run.
##  - permission actions (allow / forbid an activity in a zone type): never "run"; PolicyEngine.is_permitted() reads them
##    whenever a citizen is about to chop, pick fruit, build or walk somewhere. They apply to every citizen the
##    condition matches, whatever that citizen is currently doing.
## One policy can mix both: "WHEN [Age] is below [16] THEN [Forbid chopping in Restricted zones], [Go to Gathering area]".
##
## The editor builds these; PolicyEngine installs the default traditions below.

@export var policy_name: String = ""
@export var condition: Condition        # null = always matches
@export var actions: Array[Action] = []
## Higher runs first. Innate needs and idle wandering run outside policy ordering.
@export var priority: int = 0
@export var enabled: bool = true
## true = shipped with the settlement (a "Default Tradition"): the player may tweak or disable it, not lose it
@export var is_default: bool = false
## true = still runs while the citizen is busy with a task the player handed them by hand. Everything else waits
## until that task is finished (a manual assignment overrides ordinary policies; it does not override hunger).
@export var survival: bool = false
## true = skipped while the citizen is busy (chopping, building, eating...), so a rule such as "gather" does not keep
## restarting the very task the citizen is already doing. Rules made in the policy editor start with this on.
@export var only_when_idle: bool = false

## The FIRST action, for code (and the editor's single action dropdown) that still deals with one action per rule.
## Setting it replaces the first action and keeps the rest; setting null removes the first action.
var action: Action:
	get:
		return actions[0] if not actions.is_empty() else null
	set(value):
		if value == null:
			if not actions.is_empty():
				actions.remove_at(0)
		elif actions.is_empty():
			actions.append(value)
		else:
			actions[0] = value

func behaviour_actions() -> Array[Action]:
	var list: Array[Action] = []
	for a in actions:
		if a != null and not a.is_permission():
			list.append(a)
	return list

func permission_actions() -> Array[Action]:
	var list: Array[Action] = []
	for a in actions:
		if a != null and a.is_permission():
			list.append(a)
	return list
