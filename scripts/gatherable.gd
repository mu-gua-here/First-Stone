extends Node3D
class_name Gatherable

## Put this on the root of any free-standing, choppable object (a tree scene). It registers itself
## with the Builder, so citizens and the player can chop it, and its logs spawn from it.
## Nothing here is tied to the GridMap -- place these anywhere, with Asset Placer or by hand.
## (A scene placed before the Builder is ready is picked up by the Builder's own start-up scan.)

## Gather stats for this object (resource_type, resource_yield, gather_time, energy_required,
## food_chance...). Fill the Structure in the Inspector; it is shared by every instance of the scene.
@export var structure: Structure

## Where the chop-progress bar floats. Drop a Marker3D just above the crown in the tree scene and assign it
## here: it follows each instance's scale, so tall and short trees each get the bar at the right height.
@export var progress_anchor: Node3D
## Used only when no anchor is assigned.
@export var fallback_bar_height := 6.0

## Optional "you can interact with me" marker (a billboard Sprite3D in the tree scene, hidden by default).
## It is shown while the player is within hint_distance of this object.
@export var interact_hint: Node3D
@export var hint_distance := 5.0
const HINT_CHECK_INTERVAL := 0.15 # seconds between distance checks (cheap, and there are many trees)
var _hint_timer := randf() * HINT_CHECK_INTERVAL # desync the trees so they don't all check on one frame

func get_progress_position() -> Vector3:
	if progress_anchor != null:
		return progress_anchor.global_position
	return global_position + Vector3.UP * fallback_bar_height

func _ready() -> void:
	add_to_group("gatherable")
	set_process(interact_hint != null)
	if interact_hint != null:
		interact_hint.visible = false
	if structure == null:
		push_warning("Gatherable '%s' has no Structure assigned." % name)
		return
	if Globals.builder != null:
		Globals.builder.register_gatherable(self, structure)

func _process(delta: float) -> void:
	_hint_timer -= delta
	if _hint_timer > 0.0:
		return
	_hint_timer = HINT_CHECK_INTERVAL
	var player := Globals.player
	interact_hint.visible = player != null \
			and global_position.distance_squared_to(player.global_position) <= hint_distance * hint_distance
