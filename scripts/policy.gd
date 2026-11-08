extends Resource
class_name Policy

## A Policy is one rule: "WHEN [condition on a citizen] THEN [action]".
## PolicyEngine.think(citizen) walks the active policies from the highest priority down and runs the first one
## whose condition matches and whose action actually applies. This is the same Condition / Action pair the manual
## assignment path uses, so a click in CitizenSelector and a rule in the policy editor both end up in
## PolicyEngine.execute().
##
## The editor (later) builds these; for now PolicyEngine installs the default traditions below.

@export var policy_name: String = ""
@export var condition: Condition        # null = always matches
@export var action: Action
## Higher runs first. Survival traditions (eating) sit at the top, idle behaviour (wandering) at the bottom.
@export var priority: int = 0
@export var enabled: bool = true
## true = shipped with the settlement (a "Default Tradition"): the player may tweak or disable it, not lose it
@export var is_default: bool = false
## true = still runs while the citizen is busy with a task the player handed them by hand. Everything else waits
## until that task is finished (a manual assignment overrides ordinary policies; it does not override hunger).
@export var survival: bool = false
