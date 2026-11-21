extends Node
class_name Network

## One shared game server that everybody plays on (Godot high-level multiplayer over WebSockets, which -- unlike
## ENet -- also works from a web export).
##
## CLIENT (the normal game): asks for a username (remembered for next time), then connects to `server_url`, shows
## the status in the HUD label, and retries every few seconds if the server cannot be reached.
## SERVER: the same project run as the dedicated server. It is picked when the build has the "dedicated_server"
## feature, runs headless, or is started with the argument `--server` (or the feature tag `server`):
##     godot --headless --path . -- --server
## Optional server arguments:  --port=8910   --tls-key=<key.pem> --tls-cert=<fullchain.pem>
## A browser on an https page (itch.io) can only open wss:// connections, so the server needs TLS: give it the
## key/cert arguments above, or put a TLS proxy (Caddy, nginx, Cloudflare Tunnel) in front of it.
##
## Everyone plays their own copy of the world; what is shared is the players themselves: position, name,
## health, hunger, energy and pushing each other (see net_player.gd).

const DEFAULT_PORT := 8910
const BUFFER_SIZE := 1 << 20 # bytes; the default (64 KB) is too small for catching a new player up
const PROFILE_PATH := "user://profile.cfg" # on the web, user:// lives in the browser's IndexedDB, so it persists
const MAX_NAME_LENGTH := 16
const MIN_NAME_LENGTH := 2

## Address of the game server, e.g. "wss://play.example.com" (or "ws://127.0.0.1:8910" for testing).
@export var server_url := "ws://127.0.0.1:8910"
@export var retry_seconds := 5.0
## If the very first connection attempt fails (no server running, or a browser page that cannot reach it), play on
## your own copy of the world instead of sitting in a world where nothing responds. Never kicks in once you have
## been connected: a dropped connection still just retries.
@export var offline_fallback := true
@export var connect_timeout := 8.0 # seconds before an attempt that neither succeeds nor fails is given up
@export var net_player_scene: PackedScene
## Parent of all avatars. The MultiplayerSpawner's spawn path points here.
@export var net_players: Node3D
@export var status_label: Label

@export_group("Username dialog")
@export var name_dialog: CanvasLayer
@export var name_edit: LineEdit
@export var name_error: Label
@export var name_confirm: Button

var player_name := ""
var player_color := Color.WHITE # random on the first visit, then remembered (see _load_saved_color)
var _is_server := false
var _connected := false
var _ever_connected := false
var _standalone := false
var _connect_left := -1.0
var _retry_left := -1.0
var _last_status := ""
var _names := {} # server only: peer id -> name
var _colors := {} # server only: peer id -> colour


func _ready() -> void:
	_is_server = OS.has_feature("dedicated_server") or OS.has_feature("server") \
			or DisplayServer.get_name() == "headless" \
			or "--server" in OS.get_cmdline_user_args() or "--server" in OS.get_cmdline_args()
	print("Network: starting as %s" % ("SERVER" if _is_server else "client"))
	Globals.hosting_world = _is_server # the server simulates the world (the Builder waits a frame before it checks this)
	Globals.online_client = not _is_server
	Globals.network = self
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if _is_server:
		name_dialog.visible = false
		_start_server()
	else:
		_ask_for_name()


func _process(delta: float) -> void:
	if _is_server:
		_set_status("Server: %d player%s" % [net_players.get_child_count(), "" if net_players.get_child_count() == 1 else "s"])
		return
	if _standalone:
		return
	if _connect_left >= 0.0:
		_connect_left -= delta
		if _connect_left < 0.0 and not _connected:
			_fail()
			return
	if _connected:
		var count := net_players.get_child_count()
		_set_status("Online: %d player%s" % [count, "" if count == 1 else "s"])
	elif _retry_left >= 0.0:
		_retry_left -= delta
		if _retry_left < 0.0:
			_connect()
		else:
			_set_status("Could not reach the server.\nRetrying in %d s ..." % ceili(_retry_left))


# --- Username ---

# Shown on every start with the saved name filled in, so it is one Enter to carry on (or type another name).
# The game is paused behind it so nothing happens (or gets typed into the world) meanwhile.
func _ask_for_name() -> void:
	name_edit.max_length = MAX_NAME_LENGTH
	name_edit.text = _load_saved_name()
	player_color = _load_saved_color()
	name_error.text = ""
	name_confirm.pressed.connect(_on_name_confirmed)
	name_edit.text_submitted.connect(_on_name_confirmed)
	name_dialog.visible = true
	get_tree().paused = true
	if _is_touch_web():
		# Browsers only open the on-screen keyboard from inside a real tap, so focusing the field here (no tap yet) would
		# leave it focused but keyboard-less and impossible to type into. Wait for the player to tap it instead.
		name_edit.virtual_keyboard_enabled = true
		name_edit.gui_input.connect(_on_name_edit_gui_input)
	else:
		name_edit.grab_focus()
		name_edit.select_all()
	_set_status("Choose a name")


# Phones/tablets in the browser (itch.io mobile page)
func _is_touch_web() -> bool:
	return OS.has_feature("web") and (OS.has_feature("web_android") or OS.has_feature("web_ios") \
			or DisplayServer.is_touchscreen_available())


# Called inside the tap itself, which is what lets the browser raise the virtual keyboard
func _on_name_edit_gui_input(event: InputEvent) -> void:
	var tapped: InputEvent = (event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
	if not tapped:
		return
	name_edit.grab_focus()
	DisplayServer.virtual_keyboard_show(name_edit.text, name_edit.get_global_rect(), DisplayServer.KEYBOARD_TYPE_DEFAULT,
			MAX_NAME_LENGTH, name_edit.caret_column, name_edit.caret_column)


func _on_name_confirmed(_text: String = "") -> void:
	var clean := sanitize_name(name_edit.text)
	if clean.length() < MIN_NAME_LENGTH:
		name_error.text = "Please enter at least %d characters." % MIN_NAME_LENGTH
		return
	player_name = clean
	_save_name(clean)
	if Globals.player != null and Globals.player.has_method("set_body_color"):
		Globals.player.set_body_color(player_color) # you wear your colour too
	var own_plate = Globals.player.get("nameplate") if Globals.player != null else null
	if own_plate != null:
		own_plate.set_player_name(clean) # your own name above your own head
	name_dialog.visible = false
	name_edit.release_focus()
	DisplayServer.virtual_keyboard_hide()
	get_tree().paused = false
	_connect()


static func sanitize_name(text: String) -> String:
	var out := ""
	for ch in text.strip_edges():
		var code := ch.unicode_at(0)
		if code >= 32 and code != 127:
			out += ch
	return out.substr(0, MAX_NAME_LENGTH).strip_edges()


func _load_saved_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) != OK:
		return ""
	return sanitize_name(str(cfg.get_value("player", "name", "")))


# Random hue (that is what tells players apart), kept bright enough to read against the ground. Stored with the
# name, so the same player keeps the same colour from visit to visit.
func _load_saved_color() -> Color:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) == OK and cfg.has_section_key("player", "color"):
		return Color.html(str(cfg.get_value("player", "color")))
	return Color.from_hsv(randf(), randf_range(0.6, 0.9), randf_range(0.8, 1.0))


func _save_name(value: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH) # keep any other saved settings
	cfg.set_value("player", "name", value)
	cfg.set_value("player", "color", player_color.to_html(false))
	cfg.save(PROFILE_PATH)


# The client tells the server its name once connected; the server stores it on the avatar, which replicates it.
@rpc("any_peer", "call_remote", "reliable")
func register_player(requested_name: String, requested_color: Color) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var clean := sanitize_name(requested_name)
	if clean.is_empty():
		clean = "Player"
	_names[id] = clean
	var color := Color(clampf(requested_color.r, 0.0, 1.0), clampf(requested_color.g, 0.0, 1.0), clampf(requested_color.b, 0.0, 1.0))
	_colors[id] = color
	var avatar := net_players.get_node_or_null(str(id)) as NetPlayer
	if avatar != null:
		avatar.player_name = clean
		avatar.player_color = color


# --- Connecting ---

func _start_server() -> void:
	var port := int(_user_arg("--port=", str(DEFAULT_PORT)))
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = BUFFER_SIZE # a late joiner is sent the world's history in big chunks
	peer.outbound_buffer_size = BUFFER_SIZE
	var err := peer.create_server(port, "*", _tls_options())
	if err != OK:
		push_error("Network: could not start the server on port %d (error %d)." % [port, err])
		_set_status("Server failed to start (error %d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	print("Network: server listening on port %d" % port)


func _connect() -> void:
	_retry_left = -1.0
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = BUFFER_SIZE
	peer.outbound_buffer_size = BUFFER_SIZE
	var err := peer.create_client(server_url)
	if err != OK:
		_fail()
		return
	multiplayer.multiplayer_peer = peer
	_connect_left = connect_timeout
	_set_status("Connecting to the server ...")


# Back to offline and try again shortly
func _fail() -> void:
	_connected = false
	_connect_left = -1.0
	if offline_fallback and not _ever_connected:
		_go_standalone()
		return
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	for avatar in net_players.get_children():
		avatar.queue_free()
	_retry_left = retry_seconds


# No server to talk to: become our own server. The Builder and the citizens run here, and nothing waits for requests
# that would never be answered (every click on an object, a tree or a build site is a request while online_client).
func _go_standalone() -> void:
	if _standalone:
		return
	_standalone = true
	_retry_left = -1.0
	var peer := multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	for avatar in net_players.get_children():
		avatar.queue_free()
	Globals.hosting_world = true
	Globals.online_client = false
	var builder := Globals.builder as Builder
	if builder != null:
		builder.spawn_citizens(builder.starting_citizens) # a client never spawns them, the server does
	print("Network: no server reachable, playing offline")
	_set_status("Offline (no server reachable)")


func _tls_options() -> TLSOptions:
	var key_path := _user_arg("--tls-key=", "")
	var cert_path := _user_arg("--tls-cert=", "")
	if key_path.is_empty() or cert_path.is_empty():
		return null
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(key_path) != OK or cert.load(cert_path) != OK:
		push_error("Network: could not load the TLS key/certificate, starting without TLS.")
		return null
	return TLSOptions.server(key, cert)


func _user_arg(prefix: String, default: String) -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return default


func _set_status(text: String) -> void:
	if text != _last_status:
		_last_status = text
		if status_label != null:
			status_label.text = text


# --- Avatars (only the server creates/removes them; the spawner replicates that to everyone) ---

func _add_avatar(peer_id: int) -> void:
	if net_players.has_node(str(peer_id)):
		return
	var avatar := net_player_scene.instantiate() as NetPlayer
	avatar.name = str(peer_id) # must be set before it enters the tree: NetPlayer reads its owner from it
	avatar.player_name = _names.get(peer_id, "")
	avatar.player_color = _colors.get(peer_id, avatar.player_color)
	net_players.add_child(avatar)


func _remove_avatar(peer_id: int) -> void:
	var avatar := net_players.get_node_or_null(str(peer_id))
	if avatar != null:
		avatar.queue_free()
	_names.erase(peer_id)
	_colors.erase(peer_id)


# --- Connection signals ---

func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_add_avatar(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		_remove_avatar(peer_id)


func _on_connected_to_server() -> void:
	_connected = true
	_ever_connected = true
	_connect_left = -1.0
	register_player.rpc_id(1, player_name, player_color)


func _on_connection_failed() -> void:
	_fail.call_deferred()


func _on_server_disconnected() -> void:
	_fail.call_deferred()
