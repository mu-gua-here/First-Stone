extends Node3D
class_name NoticeBoard

## The wooden tribal notice board near spawn: the physical entry point to the policy editor
## (see Policy_System_Design: the editor is reached through an era-appropriate centrepiece in the settlement).
## Stand close and press E to read the notices (opens the PolicyEditor, which finds itself via the
## "policy_editor" group). `opened` fires whenever the editor is opened from here.

signal opened

## Drop the board onto the ground below it at start, so it never floats or sinks wherever it is placed in the editor.
@export_flags_3d_physics var ground_mask := 1
## How close the player must stand (flat distance from the board's centre) to read the notices
@export var reach := 3.5

@onready var _hint: Label3D = $Hint

func _ready() -> void:
	add_to_group("policy_board")

## The "[E] Read the notices" hint floats over the board while the player is close enough to use it
func _process(_delta: float) -> void:
	_hint.visible = _player_in_reach() and not _editor_open()

func _unhandled_key_input(event: InputEvent) -> void:
	if Globals.is_gameplay_input_blocked():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_E:
		return
	if not _player_in_reach() or _editor_open():
		return
	get_viewport().set_input_as_handled()
	open_policy_editor()

## Opens the policy editor
func open_policy_editor() -> void:
	var editor = get_tree().get_first_node_in_group("policy_editor")
	if editor == null:
		push_warning("NoticeBoard: no policy editor in the scene (expected a node in group \"policy_editor\").")
		return
	editor.open()
	opened.emit()

func _editor_open() -> bool:
	var editor = get_tree().get_first_node_in_group("policy_editor")
	return editor != null and editor.is_open()

func _player_in_reach() -> bool:
	var player = Globals.player
	if player == null:
		return false
	var offset: Vector3 = player.global_position - global_position
	return Vector2(offset.x, offset.z).length() <= reach
