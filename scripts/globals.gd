extends Node3D

## Autoload. Scene singletons register themselves here in _ready() so other
## scripts can reach them directly instead of searching the tree or groups.
## Player stats (health, energy) live on the Player itself -- read them via
## Globals.player or connect to Player.health_changed.

var player: CharacterBody3D = null
var builder: Node = null
var day_night: Node = null # the DayNightCycle: the game's clock (see game_days)

## Multiplayer (set by Network in its _ready). The dedicated server runs the world's simulation -- the Builder and
## every citizen's AI. Clients get their citizens as puppets replicated from the server.
var hosting_world := false
var online_client := false
var network: Node = null
var world_sync: Node = null

## Where the player is pointing on screen: the mouse, or the screen centre while shift lock has the mouse captured.
func aim_position() -> Vector2:
	var vp := get_viewport()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return vp.get_visible_rect().size * 0.5
	return vp.get_mouse_position()

func register_player(p: CharacterBody3D) -> void:
	player = p

func register_builder(b: Node) -> void:
	builder = b

func register_day_night(d: Node) -> void:
	day_night = d

func is_gameplay_input_blocked() -> bool:
	for blocker in get_tree().get_nodes_in_group("gameplay_input_blocker"):
		if blocker.has_method("is_open") and bool(blocker.call("is_open")):
			return true
	return false

func cancel_gameplay_input() -> void:
	if player != null and player.has_method("cancel_gameplay_input"):
		player.call("cancel_gameplay_input")
	var view_node := get_tree().get_first_node_in_group("view")
	if view_node != null and view_node.has_method("cancel_gameplay_input"):
		view_node.call("cancel_gameplay_input")

## In-game days elapsed since the game started (a fraction while a day is in progress; 0.0 without a day/night cycle).
## Regrowth and births count time in these, so they follow the day length and stand still while the clock is stopped.
func game_days() -> float:
	return day_night.total_days if day_night != null else 0.0

func get_player_position() -> Vector3:
	if player:
		return player.global_position
	push_warning("Globals.gd: No player detected, returning Vector3.ZERO")
	return Vector3.ZERO
