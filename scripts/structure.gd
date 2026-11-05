extends Resource
class_name Structure

# What role this structure plays in the simulation
enum Type { DECORATIVE, HOUSE, WORKPLACE, SHOP }

# What a citizen employed at a WORKPLACE does with their time (see citizen.gd _update_job)
enum JobTask { NONE, GATHER, BUILD }

@export_subgroup("Model")
@export var display_name: String = "" # Shown in the build HUD. Falls back to the item name
@export var item_name: String = "" # Name of this structure's item in the Structures GridMap's MeshLibrary (that mesh IS the structure; no scene is instantiated)
@export var scene: PackedScene # Alternative to item_name: a free-standing object (e.g. a tree) planted at the mouse point instead of a GridMap cell. Assign in the Inspector.
@export var depleted_item_name: String = "" # Gatherables: MeshLibrary item the cell turns into once used up. Empty = whatever was there before / the ground item

@export_subgroup("Gameplay")
@export var type: Type = Type.DECORATIVE # What role this structure plays
@export var capacity: int = 0 # Job slots if WORKPLACE (unused for HOUSE — see residential_floors below)
@export var job_title: String = "" # WORKPLACE: title given to employees (e.g. "Woodcutter"). Falls back to the display name
@export var job_task: JobTask = JobTask.NONE # WORKPLACE: what employees automatically do (GATHER = chop the nearest tree, BUILD = work construction sites)
@export var happiness_bonus: float = 0.0 # Passive happiness boost for nearby citizens (decorative structures)

@export_subgroup("Housing")
@export var residential_floors: int = 0 # Floors usable as housing (HOUSE/SHOP types). Each floor = 1 household, household size rolled 2-6 at move-in.

@export_subgroup("Resources")
@export var gatherable: bool = false # If true, citizens can chop/mine this structure for raw resources
@export var resource_type: String = "" # e.g. "wood", "stone" — matches a key in DataMap's stockpile
@export var resource_yield: int = 0 # Amount granted to the stockpile per gather
@export var gather_time: float = 3.0 # Seconds a citizen must spend gathering before the yield is granted
@export var energy_required: float = 1.0 # Energy collecting the resource costs player/NPC
@export_range(0.0, 1.0) var food_chance: float = 0.1 # chance this gatherable yields bonus energy for whoever chops it down (e.g. a tree occasionally carrying something edible)
@export var food_energy_bonus: float = 15.0 # energy granted to the gatherer on a successful food_chance roll

@export_subgroup("Construction")
@export var build_cost: Dictionary = {} # resource_type (String) -> amount required from the stockpile, drawn down as builders work the site
@export var build_time: float = 10.0 # Total builder-seconds of labor needed to finish (see ConstructionSite.progress)
@export var build_energy_required: float = 1.0 # Energy cost per second of active labor spent building this structure (player or citizen)
@export var demolish_time: float = 4.0 # Seconds of the player's labour (hold Del + click and hold the structure) to take it apart

@export_subgroup("Unlock")
@export var unlock_requirements: Dictionary = {} # resource_type (String) -> cumulative lifetime amount gathered (DataMap.lifetime_gathered, not current stockpile) needed before this is buildable. Empty = unlocked from the start.

func get_display_name() -> String:
	if display_name != "":
		return display_name
	if item_name != "":
		return item_name.capitalize()
	return "Structure"

func get_job_title() -> String:
	if job_title != "":
		return job_title
	return get_display_name()
