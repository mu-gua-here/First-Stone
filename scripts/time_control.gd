extends Node
class_name TimeControl

## Game speed control, like a civ game's fast-forward. It sets Engine.time_scale, which scales EVERY delta in the game
## (_process and _physics_process), so the day/night cycle, hunger, regrowth, births and citizen AI all speed up together
## with no changes to those scripts. Use it to watch slow processes play out or to stress-test that nothing breaks.
##
## Keys (input actions in Project Settings > Input Map): time_slower, time_faster, time_normal.
## Tuned for desktop/web playtesting: at high speeds the player and camera move faster too, since they run on the same delta.

## The selectable speeds, slowest to fastest. Keep the top one modest: physics has to run speed x 60 ticks a second.
@export var speeds: Array[float] = [0.5, 1.0, 2.0, 4.0, 8.0]
## Index into `speeds` the game starts at (1 = 1x with the default list).
@export var start_index := 1
## Physics steps allowed per rendered frame while sped up. Godot's default is 8, which at 8x only works at 60 FPS and
## makes the sim run slower than asked on the 30 FPS preset; this raises it so the speed actually holds.
@export var max_physics_steps_when_fast := 16
## Shows the current speed (top right). Hidden at 1x so it doesn't clutter the screen.
@export var speed_label: Label

var _index := 1
var _default_max_steps := 8


func _ready() -> void:
	_default_max_steps = Engine.max_physics_steps_per_frame
	_set_index(start_index)


func _exit_tree() -> void:
	# Loading a save reloads the scene; never leave the engine sped up behind us
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = _default_max_steps


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed("time_faster"):
		_set_index(_index + 1)
	elif event.is_action_pressed("time_slower"):
		_set_index(_index - 1)
	elif event.is_action_pressed("time_normal"):
		_set_index(speeds.find(1.0))
	else:
		return
	get_viewport().set_input_as_handled()


func _set_index(i: int) -> void:
	if speeds.is_empty():
		return
	_index = clampi(i, 0, speeds.size() - 1)
	var scale: float = speeds[_index]
	# Online clients follow the server's clock; speeding up locally would desync them
	if Globals.online_client:
		scale = 1.0
	Engine.time_scale = scale
	Engine.max_physics_steps_per_frame = max_physics_steps_when_fast if scale > 1.0 else _default_max_steps
	if speed_label:
		speed_label.visible = not is_equal_approx(scale, 1.0) and not Globals.online_client
		speed_label.text = "Speed  %sx" % str(scale).trim_suffix(".0")
