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

## Optional: a Node3D whose children are fruit meshes hanging on the tree (the fruit tree's "Fruit" node). Chopping then
## detaches them one by one -- each hanging fruit disappears and the same fruit drops as a real prop from where it hung --
## instead of spawning new ones. The tree's fruit count is the number of children. Needs Structure.secondary_resource_type.
@export var fruit_container: Node3D

## What stands here once this object is used up (a stump for a tree). Leave empty to simply remove it.
@export var depleted_scene: PackedScene
## A bush: fruit is picked one at a time (E for the player, one per gather cycle for citizens) without any progress bar,
## and the bush stays standing, bare, once the last one is gone. The player can still chop it down like a tree
## (hold click): the fruit still hanging drops, and depleted_scene (trampled bushes) is left behind.
@export var pick_fruit_only := false

## Optional "you can interact with me" marker (a billboard Sprite3D in the tree scene, hidden by default).
## It is shown while the player is within hint_distance of this object.
@export var interact_hint: Node3D
@export var hint_distance := 4.0
const HINT_CHECK_INTERVAL := 0.15 # seconds between distance checks (cheap, and there are many trees)
var _hint_timer := randf() * HINT_CHECK_INTERVAL # desync the trees so they don't all check on one frame

func get_progress_position() -> Vector3:
	if progress_anchor != null:
		return progress_anchor.global_position
	return global_position + Vector3.UP * fallback_bar_height

## How many fruits hang on this tree when untouched (0 = no fruit_container)
func get_fruit_count() -> int:
	return fruit_container.get_child_count() if fruit_container != null else 0

## Where the index-th fruit hangs, in world space
func get_fruit_position(index: int) -> Vector3:
	if fruit_container != null and index < fruit_container.get_child_count():
		var fruit := fruit_container.get_child(index) as Node3D
		if fruit != null:
			return fruit.global_position
	return global_position

## Chop progress 0..1 -> fruits still hanging: the first ones go as soon as the chopping starts (same rule as the
## dropped props, see Builder._spawn_fruit_drops), so every peer shows the same tree.
func update_fruit_visibility(progress: float) -> void:
	var total := get_fruit_count()
	var gone := floori(progress * total)
	for i in range(mini(gone, total)):
		(fruit_container.get_child(i) as Node3D).visible = false # (never shows one again: some may already be picked)

## Fruits still hanging that nobody has picked (pick_fruit_only bushes)
func fruits_left() -> int:
	if fruit_container == null:
		return 0
	var count := 0
	for fruit in fruit_container.get_children():
		if (fruit as Node3D).visible:
			count += 1
	return count

## Loading a save: hides fruit until only `left` hang here. The hidden ones count as picked, so chopping the tree later
## doesn't drop them a second time (they already exist as props, or were eaten).
func set_fruits_left(left: int) -> void:
	if fruit_container == null:
		return
	var to_remove := fruits_left() - left
	for fruit in fruit_container.get_children():
		if to_remove <= 0:
			break
		var node := fruit as Node3D
		if node.visible:
			node.visible = false
			node.set_meta("picked", true)
			to_remove -= 1

## A bush with nothing left to pick (it stays in the world, just bare)
func is_depleted() -> bool:
	return pick_fruit_only and fruits_left() <= 0

## Takes one hanging fruit off (hides it) and returns where it hung, or Vector3.INF if there is none
func take_fruit() -> Vector3:
	if fruit_container == null:
		return Vector3.INF
	for fruit in fruit_container.get_children():
		var node := fruit as Node3D
		if node.visible:
			node.visible = false
			node.set_meta("picked", true)
			return node.global_position
	return Vector3.INF

## Whether the index-th fruit was already picked by hand (so chopping the bush doesn't drop it a second time)
func is_fruit_picked(index: int) -> bool:
	if fruit_container == null or index >= fruit_container.get_child_count():
		return false
	return fruit_container.get_child(index).get_meta("picked", false)

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
	interact_hint.visible = player != null and not is_depleted() \
			and global_position.distance_squared_to(player.global_position) <= hint_distance * hint_distance
