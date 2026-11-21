extends Node

## One-shot sound effects, registered as the "Audio" autoload (Project Settings > Globals) so existing calls like
## Audio.play("sounds/toggle.ogg", -30) keep working. (The underwater/ambience effect lives in audio.gd, which is a node in
## main.tscn -- it is NOT the autoload, and it has no one-shot play(): AudioStreamPlayer.play() takes a start time.)
##
## `paths` is one res:// -relative file or several separated by commas; one is picked at random each call
## (e.g. Builder.SFX_PLACE). `volume_db` is the loudness.

const POOL_SIZE := 8 # sounds that can overlap; the oldest is cut off if more are triggered at once

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _cache := {} # path -> AudioStream

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # the pause menu plays a sample while you drag the volume sliders
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = &"Effects" # see audio/bus_layout.tres (falls back to Master if the bus is missing)
		add_child(player)
		_players.append(player)

func play(paths: String, volume_db: float = 0.0) -> void:
	var options := paths.split(",", false)
	if options.is_empty():
		return
	var path := "res://" + options[randi() % options.size()].strip_edges()
	var stream: AudioStream = _cache.get(path)
	if stream == null:
		if not ResourceLoader.exists(path):
			push_warning("Audio.play: sound not found: %s" % path)
			return
		stream = load(path)
		_cache[path] = stream
	var player := _players[_next]
	_next = (_next + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = volume_db
	player.play()
