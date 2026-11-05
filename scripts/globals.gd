extends Node3D

## Autoload. Scene singletons register themselves here in _ready() so other
## scripts can reach them directly instead of searching the tree or groups.
## Player stats (health, energy) live on the Player itself -- read them via
## Globals.player or connect to Player.health_changed.

var player: CharacterBody3D = null
var builder: Node = null

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

func get_player_position() -> Vector3:
	if player:
		return player.global_position
	push_warning("Globals.gd: No player detected, returning Vector3.ZERO")
	return Vector3.ZERO
