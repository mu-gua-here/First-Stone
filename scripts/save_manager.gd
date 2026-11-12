extends Node
class_name SaveManager

## Saves and loads the game to user://savegame.tres (see SaveData). First stage: structures, logs and fruit.
##
## Save: press the "save" input action. A dialog with a progress bar pops up while the data is gathered a few hundred
## things per frame (so the bar really moves); "Cancel" abandons it at any point. The file is written to a temp file
## first and only swapped in once complete, so a cancelled or failed save never damages the previous one (which is also
## kept as savegame.bak.tres).
## Load: press the "load" input action. The scene restarts clean, then the save is applied on top of the fresh world.
## Only offline: an online client (Globals.online_client, which is every multiplayer web player) can't save or load,
## because the server owns the world. Playing offline, on web or native, works.

const SAVE_PATH := "user://savegame.tres"
const BACKUP_PATH := "user://savegame.bak.tres"
const TEMP_PATH := "user://savegame.tmp.tres"
const CHUNK := 200 # things handled per frame, so the progress bar can update and Cancel can be pressed

## Survives reload_current_scene(): tells the fresh scene to apply the save once the Builder has started up
static var _load_pending := false

@export var dialog: CanvasLayer
@export var title_label: Label
@export var status_label: Label
@export var progress_bar: ProgressBar
@export var cancel_button: Button

var _busy := false
var _cancelled := false
var _saved_mouse_mode := Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if dialog != null:
		dialog.visible = false
	if cancel_button != null:
		cancel_button.pressed.connect(func(): _cancelled = true)
	if _load_pending:
		_load_pending = false
		_apply_saved_game()

func _unhandled_input(event: InputEvent) -> void:
	if _busy or Globals.online_client:
		return
	if event.is_action_pressed("save"):
		get_viewport().set_input_as_handled()
		save_game()
	elif event.is_action_pressed("load"):
		get_viewport().set_input_as_handled()
		load_game()

# --- Dialog helpers ------------------------------------------------------------

func _begin(title: String, status: String, cancel_text := "Cancel") -> void:
	_busy = true
	_cancelled = false
	title_label.text = title
	cancel_button.text = cancel_text
	cancel_button.visible = true
	_set_progress(0.0, status)
	_saved_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE # the Cancel button needs a cursor
	dialog.visible = true

func _end() -> void:
	dialog.visible = false
	Input.mouse_mode = _saved_mouse_mode
	_busy = false

func _set_progress(fraction: float, status: String) -> void:
	progress_bar.value = clampf(fraction, 0.0, 1.0) * 100.0
	status_label.text = status

## Shows progress, yields one frame so the dialog redraws, and returns true if the player pressed Cancel/Skip
func _step(fraction: float, status: String) -> bool:
	_set_progress(fraction, status)
	await get_tree().process_frame
	return _cancelled

## A short message in the dialog (no cancel button), then closes it
func _notice(title: String, message: String, seconds := 1.8) -> void:
	_begin(title, message)
	cancel_button.visible = false
	progress_bar.value = 0.0
	await get_tree().create_timer(seconds).timeout
	_end()

# --- Save ----------------------------------------------------------------------

func save_game() -> void:
	var b := Globals.builder as Builder
	if _busy or b == null or Globals.online_client:
		return
	_begin("Saving game", "Buildings...")
	var data := SaveData.new()
	data.build_version = str(ProjectSettings.get_setting("application/config/version", ""))
	data.saved_unix_time = int(Time.get_unix_time_from_system())

	if await _step(0.05, "Buildings..."):
		_end()
		return
	_capture_buildings(b, data)
	if not await _capture_props(data):
		_end()
		return

	if await _step(0.9, "Writing file..."):
		_end()
		return
	# The write itself is one blocking call: the label above is already on screen when it starts
	var err := ResourceSaver.save(data, TEMP_PATH)
	if err != OK:
		_end()
		_notice("Save failed", "Could not write the save file (error %d)." % err, 3.0)
		return
	_replace_save_file()
	_set_progress(1.0, "Saved")
	cancel_button.visible = false
	await get_tree().create_timer(0.6).timeout
	_end()

func _capture_buildings(b: Builder, data: SaveData) -> void:
	for id in b.placed_structures:
		var entry: Dictionary = b.placed_structures[id]
		if entry.has("node"):
			continue # free-standing objects (trees) aren't saved yet
		var index: int = entry["structure_index"]
		if index < 0 or index >= b.structures.size() or b.structures[index].item_name == "":
			continue
		data.structure_names.append(b.structures[index].item_name)
		data.structure_positions.append(entry["position"])
		data.structure_yaws.append(entry["rotation_y"])

## Loose logs / fruit, a chunk per frame. Returns false if the player cancelled.
func _capture_props(data: SaveData) -> bool:
	var props := get_tree().get_nodes_in_group("resource_prop")
	for i in props.size():
		var prop := props[i] as ResourceProp
		if prop != null and not prop.collected and not prop.is_queued_for_deletion():
			data.prop_types.append(String(prop.get_meta("resource_type", "")))
			data.prop_positions.append(prop.global_position)
			data.prop_rotations.append(prop.global_rotation)
			data.prop_amounts.append(int(prop.get_meta("amount", 1)))
		if i % CHUNK == CHUNK - 1:
			if await _step(0.2 + 0.65 * float(i) / props.size(), "Logs and food... (%d / %d)" % [i + 1, props.size()]):
				return false
	return true

func _replace_save_file() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		if FileAccess.file_exists(BACKUP_PATH):
			DirAccess.remove_absolute(BACKUP_PATH)
		DirAccess.rename_absolute(SAVE_PATH, BACKUP_PATH)
	DirAccess.rename_absolute(TEMP_PATH, SAVE_PATH)

# --- Load ----------------------------------------------------------------------

func load_game() -> void:
	if _busy or Globals.online_client:
		return
	if not FileAccess.file_exists(SAVE_PATH) and not FileAccess.file_exists(BACKUP_PATH):
		_notice("Load game", "No saved game found.")
		return
	_load_pending = true
	get_tree().reload_current_scene()

func _read_save() -> SaveData:
	for path in [SAVE_PATH, BACKUP_PATH]:
		if not FileAccess.file_exists(path):
			continue
		var data := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as SaveData
		if data != null:
			return _migrate(data)
	return null

## Upgrades an older save to the current layout. Nothing to do yet: when a field changes meaning, bump
## SaveData.CURRENT_VERSION and convert it here (new fields just take their defaults).
func _migrate(data: SaveData) -> SaveData:
	if data.save_version > SaveData.CURRENT_VERSION:
		push_warning("SaveManager: save was written by a newer build (v%d, this build reads v%d); loading what we can." % [data.save_version, SaveData.CURRENT_VERSION])
	return data

func _apply_saved_game() -> void:
	_begin("Loading game", "Starting the world...", "Skip")
	var data := _read_save()
	if data == null:
		_end()
		_notice("Load failed", "The save file is missing or damaged.", 3.0)
		return
	# Let the Builder finish its start-up (starter citizens, tree scan, stockpile) before changing things
	for i in 8:
		await get_tree().physics_frame
	var b := Globals.builder as Builder
	if b == null:
		_end()
		return

	if await _step(0.1, "Buildings..."):
		_end()
		return
	if not await _apply_buildings(b, data):
		_end()
		return
	if not await _apply_props(b, data):
		_end()
		return
	_set_progress(1.0, "Loaded")
	cancel_button.visible = false
	await get_tree().create_timer(0.6).timeout
	_end()

func _apply_buildings(b: Builder, data: SaveData) -> bool:
	b.clear_placed_structures()
	var total := data.structure_names.size()
	var missing := 0
	for i in total:
		var index := b.structure_index_for_name(data.structure_names[i])
		if index < 0:
			missing += 1 # a structure that no longer exists in this build
			continue
		b.restore_structure(index, data.structure_positions[i], data.structure_yaws[i])
		if i % CHUNK == CHUNK - 1:
			if await _step(0.1 + 0.3 * float(i) / total, "Buildings... (%d / %d)" % [i + 1, total]):
				return false
	if missing > 0:
		push_warning("SaveManager: %d saved buildings no longer exist in this build and were skipped." % missing)
	return true

func _apply_props(b: Builder, data: SaveData) -> bool:
	var total := data.prop_types.size()
	for i in total:
		b.restore_prop(data.prop_types[i], data.prop_amounts[i], data.prop_positions[i], data.prop_rotations[i])
		if i % CHUNK == CHUNK - 1:
			if await _step(0.4 + 0.55 * float(i) / total, "Logs and food... (%d / %d)" % [i + 1, total]):
				return false
	return true
