@tool
extends Resource
class_name Structure

# One Resource for two kinds of thing: a BUILDING (placed on the Structures GridMap, built by builders) and a
# GATHERABLE (a tree/bush chopped for resources). The Inspector only shows the half that applies:
# tick `gatherable` for resources; otherwise pick a `type` and only that type's fields appear.

# What role this structure plays in the simulation
enum Type { DECORATIVE, HOUSE, WORKPLACE, SHOP }

# What a citizen employed at a WORKPLACE does with their time (see citizen.gd _update_job)
enum JobTask { NONE, GATHER, BUILD, HAUL, FORAGE }

@export_subgroup("Model")
@export var display_name: String = "" # Shown in the build HUD. Falls back to the item name
@export var item_name: String = "" # Name of this structure's item in the Structures GridMap's MeshLibrary (that mesh IS the structure; no scene is instantiated)
@export var scene: PackedScene # Alternative to item_name: a free-standing object (e.g. a tree) planted at the mouse point instead of a GridMap cell. Assign in the Inspector.
@export var depleted_item_name: String = "" # Gatherables: MeshLibrary item the cell turns into once used up. Empty = whatever was there before / the ground item

@export_subgroup("Gameplay")
@export var type: Type = Type.DECORATIVE: # What role this structure plays
	set(value):
		type = value
		notify_property_list_changed()
@export var capacity: int = 0 # Job slots if WORKPLACE (unused for HOUSE — see residential_floors below)
@export var job_title: String = "" # WORKPLACE: title given to employees (e.g. "Woodcutter"). Falls back to the display name
@export var job_task: JobTask = JobTask.NONE # What employees automatically do (GATHER = chop the nearest tree and push its logs, BUILD = work construction sites, HAUL = push loose logs to the stockpile, FORAGE = pick fruit from bushes and carry it to the food stockpile)
@export var happiness_bonus: float = 0.0 # Passive happiness boost for nearby citizens (decorative structures)

@export_subgroup("Housing")
@export var residential_floors: int = 0 # Floors usable as housing (HOUSE/SHOP types). Each floor = 1 household, household size rolled 2-6 at move-in.

@export_subgroup("Resources")
@export var gatherable: bool = false: # If true, this is a resource (tree/rock): citizens can chop/mine it for raw resources
	set(value):
		gatherable = value
		notify_property_list_changed()
@export var resource_type: String = "" # e.g. "wood", "stone" — matches a key in DataMap's stockpile
@export var resource_yield: int = 0 # Amount granted to the stockpile per gather (the minimum, when resource_yield_max is set)
@export var resource_yield_max: int = 0 # If above resource_yield, every tree rolls its own yield between the two (a fruit tree: 1-2 logs). 0 = always exactly resource_yield
@export var secondary_resource_type: String = "" # A second thing dropped while it is chopped, e.g. "food" for a fruit tree. Empty = nothing
@export var secondary_yield_min: int = 0 # Fruit per tree, rolled per tree between min and max
@export var secondary_yield_max: int = 0
@export var gather_time: float = 3.0 # Seconds a citizen must spend gathering before the yield is granted
@export var energy_required: float = 1.0 # Energy (tiredness) collecting the resource costs player/NPC per second
@export_range(0.0, 1.0) var food_chance: float = 0.1 # chance this gatherable yields bonus food for whoever chops it down (e.g. a tree occasionally carrying something edible)
@export var food_hunger_bonus: float = 15.0 # hunger restored to the gatherer on a successful food_chance roll

@export_subgroup("Construction")
@export var build_cost: Dictionary = {} # resource_type (String) -> amount required from the stockpile, drawn down as builders work the site
@export var build_time: float = 10.0 # Total builder-seconds of labor needed to finish (see ConstructionSite.progress)
@export var build_energy_required: float = 1.0 # Energy cost per second of active labor spent building this structure (player or citizen)
@export var demolish_time: float = 4.0 # Seconds of the player's labour (enter with Command+B, then click and hold the structure) to take it apart

@export_subgroup("Unlock")
@export var unlock_requirements: Dictionary = {} # resource_type (String) -> cumulative lifetime amount gathered (DataMap.lifetime_gathered, not current stockpile) needed before this is buildable. Empty = unlocked from the start.

func get_display_name() -> String:
	if display_name != "":
		return display_name
	if item_name != "":
		return item_name.capitalize()
	return "Structure"

## How much of the main resource (wood) one tree gives: fixed, or rolled between resource_yield and resource_yield_max
func roll_yield() -> int:
	if resource_yield_max > resource_yield:
		return randi_range(resource_yield, resource_yield_max)
	return resource_yield

## How many of the secondary resource (fruit) one tree gives
func roll_secondary_yield() -> int:
	if secondary_resource_type == "" or secondary_yield_max <= 0:
		return 0
	return randi_range(mini(secondary_yield_min, secondary_yield_max), secondary_yield_max)

func get_job_title() -> String:
	if job_title != "":
		return job_title
	return get_display_name()

# Hide the Inspector fields that don't apply (values stay stored; they just aren't shown)
const _GATHERABLE_ONLY := ["depleted_item_name", "resource_type", "resource_yield", "resource_yield_max", "secondary_resource_type", "secondary_yield_min", "secondary_yield_max", "gather_time", "energy_required", "food_chance", "food_hunger_bonus"]
const _BUILDING_ONLY := ["type", "happiness_bonus", "build_cost", "build_time", "build_energy_required", "demolish_time"]

func _validate_property(property: Dictionary) -> void:
	var n: String = property.name
	var hide := false
	if n in _GATHERABLE_ONLY:
		hide = not gatherable
	elif n in _BUILDING_ONLY:
		hide = gatherable
	elif n == "residential_floors":
		hide = gatherable or not (type == Type.HOUSE or type == Type.SHOP)
	elif n == "capacity" or n == "job_title" or n == "job_task":
		hide = gatherable or type != Type.WORKPLACE
	if hide:
		property.usage &= ~PROPERTY_USAGE_EDITOR
