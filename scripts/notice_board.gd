extends Node3D
class_name NoticeBoard

## The wooden tribal notice board near spawn: the physical entry point to the policy editor
## (see Policy_System_Design: the editor is reached through an era-appropriate centrepiece in the settlement).
## There is no policy UI yet, so for now this only exposes the hook: whatever builds the editor connects to
## `opened` (or calls open_policy_editor() when the player interacts with the board).

signal opened

## Drop the board onto the ground below it at start, so it never floats or sinks wherever it is placed in the editor.
@export_flags_3d_physics var ground_mask := 1

func _ready() -> void:
	add_to_group("policy_board")

## Called when the player interacts with the board. TODO: show the policy editor here.
func open_policy_editor() -> void:
	print("Notice board: policy editor not built yet.")
	opened.emit()
