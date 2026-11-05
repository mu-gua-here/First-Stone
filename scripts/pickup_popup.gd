extends Node3D
class_name PickupPopup

## A short floating message ("+1 Wood") that rises and fades out, then removes itself.
## Builder shows one where a log is collected into the stockpile.

@export var label: Label3D
@export var rise := 1.6 # metres it floats up
@export var duration := 1.2 # seconds


## Call right after adding it to the tree.
func pop(world_position: Vector3, text: String) -> void:
	global_position = world_position
	label.text = text
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "global_position:y", world_position.y + rise, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, duration * 0.5).set_delay(duration * 0.5)
	tween.chain().tween_callback(queue_free)
