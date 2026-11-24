extends Node

## Pause menu (Esc or P): resume, save / load, quit, plus settings for audio, graphics and the interface.
## The UI itself is the PauseMenu node in main.tscn (edit it in the editor); this script only wires it up and applies the
## settings. Settings are saved to user://settings.cfg and re-applied every time the scene starts.
##
## Clicking the dimmed area outside the panel goes back one page (settings -> main page -> resume).
## Online the world keeps running on the server, so the menu doesn't pause the tree there.

const SETTINGS_PATH := "user://settings.cfg"
const PAUSE_ACTION := &"pause_menu" # project.godot input map

enum Quality { LOW, MEDIUM, HIGH, ULTRA }

const QUALITY_NAMES := ["Low", "Medium", "High", "Ultra"]
const DEFAULT_QUALITY := Quality.HIGH
const DEFAULT_FPS := 60
const FAR_MARGIN := 1.15 # the low preset puts the camera far plane this much past the end of the fog
const PREVIEW_SOUND := "sounds/toggle.ogg" # played when you let go of a volume slider
const PREVIEW_VOLUME_DB := -20.0
## The UI is always drawn at this fraction of the window's base size; the UI scale setting multiplies on top of it, so the
## slider reads 1.00x at the default look (applied content_scale_factor = slider * UI_BASE_SCALE)
const UI_BASE_SCALE := 1.0

# Auto quality: after every change it waits AUTO_SETTLE (shaders / buffers hitch), then averages the frame rate over
# AUTO_WINDOW seconds; below AUTO_LOW_RATIO of the FPS cap it drops one preset. It never goes back up on its own (that would
# oscillate), so picking Auto again re-runs the search from the best preset.
const AUTO_SETTLE := 1.5
const AUTO_WINDOW := 3.0
const AUTO_LOW_RATIO := 0.85

## shadows: sun shadows on/off. scale: 3D render resolution. shadow_mode: PSSM splits (left alone when shadows are off).
## lod: Viewport.mesh_lod_threshold (higher = simpler meshes sooner). fog_scale: < 1 pulls the fog in and the camera far plane
## with it, so the shorter view distance is hidden by fog. fog_density: minimum fog opacity (1 = fully opaque at the fog's far
## end). msaa: anti-aliasing of 3D geometry. atlas: directional shadow atlas size (0 = the project setting). soft: shadow filter
## quality (-1 = the project setting). fancy: SSAO + volumetric fog instead of depth fog, reflective ocean (Forward+ only).
## glow: bloom/glow in the Environment. clouds: the cloud layer in the sky and mirrored in the ocean (cheap, so High has them too).
const PRESETS := {
	Quality.LOW: {
		"shadows": false, "scale": 0.5, "lod": 4.0, "fog_scale": 0.5, "fog_density": 1.0,
		"msaa": Viewport.MSAA_DISABLED, "atlas": 0, "soft": -1, "fancy": false, "glow": false, "clouds": false,
	},
	Quality.MEDIUM: {
		"shadows": true, "scale": 0.75, "shadow_mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "lod": 1.0,
		"fog_scale": 1.0, "fog_density": 0.0, "msaa": Viewport.MSAA_DISABLED, "atlas": 0, "soft": -1, "fancy": false, "glow": false, "clouds": false,
	},
	Quality.HIGH: {
		"shadows": true, "scale": 1.0, "shadow_mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "lod": 1.0,
		"fog_scale": 1.0, "fog_density": 0.0, "msaa": Viewport.MSAA_2X, "atlas": 0, "soft": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, "fancy": false, "glow": true, "clouds": true,
	},
	Quality.ULTRA: {
		"shadows": true, "scale": 1.0, "shadow_mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "lod": 1.0,
		"fog_scale": 1.0, "fog_density": 0.0, "msaa": Viewport.MSAA_2X, "atlas": 4096,
		"soft": RenderingServer.SHADOW_QUALITY_SOFT_HIGH, "fancy": true, "glow": true, "clouds": true,
	},
}

const QUALITY_INFO := {
	Quality.LOW: "No shadows, 0.5x resolution, low model detail and a short view distance hidden by fog.",
	Quality.MEDIUM: "Shadows with 2 splits, 0.75x resolution, default model detail and view distance.",
	Quality.HIGH: "Shadows with 4 splits, full resolution, anti-aliasing on scene geometry, and clouds in the sky and on the water.",
	Quality.ULTRA: "Everything in High, plus sharper high-resolution shadows, water reflections, ambient occlusion and volumetric fog with light shafts instead of depth fog. Native builds only.",
}
const AUTO_INFO := "Starts at the best preset this device supports and steps down whenever the frame rate stays below %d%% of the FPS cap. Right now: %s."

## Controls tab: label -> input actions (the key names are read from the InputMap, so rebinding in the project keeps this right)
const CONTROL_ROWS := [
	["Move", ["ui_up", "ui_left", "ui_down", "ui_right"]],
	["Jump / swim up", ["player_jump"]],
	["Swim down", ["descend"]],
	["Run", ["run"]],
	["Lock / free the pointer", ["shift_lock"]],
	["Orbit camera (keys)", ["camera_left", "camera_right", "camera_forward", "camera_back"]],
	["Zoom camera", ["zoom_in", "zoom_out", "zoom_in_hold", "zoom_out_hold"]],
	["Drop carried item", ["drop"]],
	["Build mode", ["build_mode"]],
	["Demolish mode", ["demolish"]],
	["Rotate building", ["rotate"]],
	["Select hotbar slot", [
		"selection_0", "selection_1", "selection_2", "selection_3", "selection_4",
		"selection_5", "selection_6", "selection_7", "selection_8", "selection_9",
	]],
	["Change hotbar page", ["hotbar_page_prev", "hotbar_page_next"]],
	["Open policy editor", ["open_policy_editor"]],
	["Show / hide clock", ["toggle_clock"]],
	["Game speed (slower / normal / faster)", ["time_slower", "time_normal", "time_faster"]],
	["Quick save", ["save"]],
	["Quick load", ["load"]],
]

const CONTROL_NOTES := [
	"Left-click selects citizens and picks up loose items or fruit. Hold left-click to chop trees or help build. Select a citizen, then click a tree, fruit bush or construction site to assign them.",
	"Build mode: click to place. Press Z to enter / leave zone painting; use 1-5 to choose a brush and click-drag to paint.",
	"Drag with the right or middle mouse button to orbit the camera; left-drag empty ground also orbits. Scroll to zoom. Right-click rotates the selected building.",
	"Offline / host: hold F to eat carried fruit. Press X to sleep or wake.",
]

@export var sun: DirectionalLight3D
@export var camera: Camera3D
@export var view: Node3D
@export var save_manager: Node
## Dialogs that must not be covered by this menu (the pause key does nothing while one is showing)
@export var name_dialog: CanvasLayer
@export var save_dialog: CanvasLayer

@onready var _menu := %MenuLayer as CanvasLayer
@onready var _center := %Center as Control
@onready var _main_page := %MainPage as Control
@onready var _settings_page := %SettingsPage as Control
@onready var _fps_label := %FpsLabel as Label
@onready var _load_button := %LoadButton as Button
@onready var _save_button := %SaveButton as Button
@onready var _quit_button := %QuitButton as Button
@onready var _quality_info := %QualityInfo as Label
@onready var _quality_auto := %QualityAuto as Button

# Settings (defaults here; overwritten by user://settings.cfg)
var _quality: int = DEFAULT_QUALITY # with Auto on, the preset Auto is currently running
var _auto := false
var _fps: int = DEFAULT_FPS
var _vsync := true
var _fullscreen := false
var _fov := 75.0
var _ui_scale := 1.0 # relative to UI_BASE_SCALE (what the slider shows)
var _sensitivity := 1.0
var _show_fps := false
var _volume := {&"Master": 1.0, &"Effects": 1.0, &"Music": 1.0} # bus name -> 0..1

# What the scene / project authored, so lower presets can be undone and the sensitivity slider scales from it
var _default_far := 4000.0
var _default_atlas := 4096
var _default_soft := 2
var _base_look_sens := 0.15
var _base_drag_sens := 0.25

var _quit_armed := false
var _dirty := false
var _syncing := false # true while the widgets are being set from the settings, so they don't write back

# Auto quality bookkeeping (msec timestamps, so the game-speed control can't skew it)
var _auto_window_start := 0
var _auto_frames := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("gameplay_input_blocker")
	_center.resized.connect(_update_pause_menu_scale_pivot)
	call_deferred("_update_pause_menu_scale_pivot")
	_menu.visible = false
	if camera != null:
		_default_far = camera.far
		_fov = camera.fov
	if view != null:
		_base_look_sens = view.get("shift_lock_sensitivity")
		_base_drag_sens = view.get("drag_sensitivity")
	_default_atlas = int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096))
	_default_soft = int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2))
	_load_settings()
	_connect_widgets()
	_build_controls_text()
	var web := OS.has_feature("web")
	_quit_button.visible = not web # a browser tab can't be quit from inside
	%VsyncCheck.visible = not web # the browser owns vsync
	%QualityUltra.visible = _ultra_supported()
	_sync_widgets()
	_apply_all()
	if _fullscreen and not web: # a browser only allows fullscreen from a click, so there it starts windowed
		_apply_fullscreen()
	_auto_reset()

func _notification(what: int) -> void:
	if OS.has_feature("web") and what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		open()

func _process(_delta: float) -> void:
	if _show_fps:
		_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	if _auto:
		if _menu.visible or not get_window().has_focus():
			_auto_reset() # a paused / backgrounded game says nothing about performance
		else:
			_auto_tick()

# --- Auto quality ---------------------------------------------------------------

func _auto_reset() -> void:
	_auto_window_start = Time.get_ticks_msec() + int(AUTO_SETTLE * 1000.0)
	_auto_frames = 0

func _auto_tick() -> void:
	var now := Time.get_ticks_msec()
	if now < _auto_window_start:
		return # still settling after a change
	_auto_frames += 1
	var elapsed := (now - _auto_window_start) / 1000.0
	if elapsed < AUTO_WINDOW:
		return
	var average := _auto_frames / elapsed
	_auto_reset()
	if average < float(_fps) * AUTO_LOW_RATIO and _quality > Quality.LOW:
		_quality -= 1
		_dirty = true
		_apply_graphics()
		_refresh_quality_ui()

func _ultra_supported() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus" and not OS.has_feature("web")

func _max_quality() -> int:
	return Quality.ULTRA if _ultra_supported() else Quality.HIGH

# --- Opening and closing -------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _menu.visible or not event is InputEventKey:
		return
	# Input is disabled while paused: keys never reach the game (some nodes keep running while paused, e.g. quick save)
	if event.is_action_pressed(PAUSE_ACTION, false, true):
		close()
	get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if Globals.is_gameplay_input_blocked():
		return
	if event.is_action_pressed(PAUSE_ACTION) and not _menu.visible and not _dialog_showing():
		open()
		get_viewport().set_input_as_handled()

func _dialog_showing() -> bool:
	return (name_dialog != null and name_dialog.visible) or (save_dialog != null and save_dialog.visible)

func open() -> void:
	if _menu.visible or _dialog_showing():
		return
	for blocker in get_tree().get_nodes_in_group("gameplay_input_blocker"):
		if blocker != self and blocker.has_method("is_open") and bool(blocker.call("is_open")):
			return
	Globals.cancel_gameplay_input()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var offline := not Globals.online_client
	_save_button.visible = offline
	_load_button.visible = offline
	_load_button.disabled = not (FileAccess.file_exists(SaveManager.SAVE_PATH) or FileAccess.file_exists(SaveManager.BACKUP_PATH))
	_show_page(_main_page)
	_menu.visible = true
	_set_paused(true)

func is_open() -> bool:
	return _menu.visible

func close() -> void:
	_save_settings()
	_menu.visible = false
	_set_paused(false)
	_auto_reset()

## One step back: settings -> main page -> resume
func _back() -> void:
	if _settings_page.visible:
		_show_page(_main_page)
	else:
		close()

func _on_dim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_back() # a click on the dimmed area outside the panel

func _set_paused(on: bool) -> void:
	if Globals.online_client or Globals.hosting_world:
		return # the world runs on the server; pausing here would only stall the network
	get_tree().paused = on

func _show_page(page: Control) -> void:
	if _settings_page.visible and page != _settings_page:
		_save_settings()
	_main_page.visible = page == _main_page
	_settings_page.visible = page == _settings_page
	_quit_armed = false
	_quit_button.text = "Quit game"
	if page == _settings_page:
		_sync_widgets(true) # e.g. fullscreen can change outside the menu

# --- Wiring --------------------------------------------------------------------

func _connect_widgets() -> void:
	%Dim.gui_input.connect(_on_dim_gui_input)
	%ResumeButton.pressed.connect(close)
	%SettingsButton.pressed.connect(_show_page.bind(_settings_page))
	%BackButton.pressed.connect(_show_page.bind(_main_page))
	_save_button.pressed.connect(_on_save_pressed)
	_load_button.pressed.connect(_on_load_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)

	for bus in _volume:
		var slider := get_node("%%%sSlider" % bus) as HSlider
		slider.value_changed.connect(_on_volume_changed.bind(bus))
		slider.drag_ended.connect(_on_volume_released)

	_quality_auto.pressed.connect(_set_auto)
	%QualityLow.pressed.connect(_set_quality.bind(Quality.LOW))
	%QualityMedium.pressed.connect(_set_quality.bind(Quality.MEDIUM))
	%QualityHigh.pressed.connect(_set_quality.bind(Quality.HIGH))
	%QualityUltra.pressed.connect(_set_quality.bind(Quality.ULTRA))
	%Fps30.pressed.connect(_set_fps.bind(30))
	%Fps60.pressed.connect(_set_fps.bind(60))
	%VsyncCheck.toggled.connect(func(on: bool): _change(func(): _vsync = on, _apply_display))
	%FovSlider.value_changed.connect(func(v: float): _change(func(): _fov = v, _apply_interface))
	%UiScaleSlider.value_changed.connect(func(v: float): _change(func(): _ui_scale = v, _apply_interface))
	%SensitivitySlider.value_changed.connect(func(v: float): _change(func(): _sensitivity = v, _apply_interface))
	%FpsCheck.toggled.connect(func(on: bool): _change(func(): _show_fps = on, _apply_interface))
	%FullscreenCheck.toggled.connect(_on_fullscreen_toggled)

## Runs a settings change (a lambda that sets the variable), then applies everything and refreshes the labels
func _change(setter: Callable, apply: Callable) -> void:
	if _syncing:
		return
	setter.call()
	_dirty = true
	apply.call()
	_update_value_labels()

func _set_quality(quality: int) -> void:
	if _syncing:
		return
	_auto = false
	_change(func(): _quality = quality, _apply_graphics)
	_refresh_quality_ui()

func _set_auto() -> void:
	if _syncing:
		return
	_auto = true
	_auto_reset()
	_change(func(): _quality = _max_quality(), _apply_graphics)
	_refresh_quality_ui()

func _set_fps(fps: int) -> void:
	_change(func(): _fps = fps, _apply_display)
	_auto_reset()

func _refresh_quality_ui() -> void:
	_quality_auto.text = "Auto (%s)" % QUALITY_NAMES[_quality] if _auto else "Auto"
	_quality_info.text = (AUTO_INFO % [roundi(AUTO_LOW_RATIO * 100.0), QUALITY_NAMES[_quality]]) if _auto else QUALITY_INFO[_quality]

func _on_volume_changed(value: float, bus: StringName) -> void:
	_change(func(): _volume[bus] = value, _apply_audio)

func _on_volume_released(_value_changed: bool) -> void:
	Audio.play(PREVIEW_SOUND, PREVIEW_VOLUME_DB)

func _on_fullscreen_toggled(on: bool) -> void:
	if _syncing:
		return
	_change(func(): _fullscreen = on, _apply_fullscreen)

# --- Buttons -------------------------------------------------------------------

func _on_save_pressed() -> void:
	if save_manager == null:
		return
	# Stay paused while it saves so the snapshot can't change under the progress bar
	_menu.visible = false
	await save_manager.save_game()
	if get_tree().current_scene != null: # still here (a save never reloads the scene)
		_show_page(_main_page)
		_menu.visible = true

func _on_load_pressed() -> void:
	if save_manager == null:
		return
	# Loading reloads the scene, and a paused tree would stay paused through that
	close()
	save_manager.load_game()

func _on_quit_pressed() -> void:
	if not _quit_armed:
		_quit_armed = true
		_quit_button.text = "Unsaved progress is lost. Quit?"
		return
	_save_settings()
	get_tree().quit()

# --- Applying ------------------------------------------------------------------

func _apply_all() -> void:
	_apply_audio()
	_apply_graphics()
	_apply_display()
	_apply_interface()

func _apply_audio() -> void:
	for bus in _volume:
		var index := AudioServer.get_bus_index(bus)
		if index == -1:
			continue
		var linear: float = _volume[bus]
		AudioServer.set_bus_mute(index, linear <= 0.001)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, 0.001)))

func _apply_graphics() -> void:
	var preset: Dictionary = PRESETS[_quality]
	var vp := get_viewport()
	vp.scaling_3d_scale = preset["scale"]
	vp.mesh_lod_threshold = preset["lod"]
	vp.msaa_3d = preset["msaa"]
	RenderingServer.directional_shadow_atlas_set_size(preset["atlas"] if preset["atlas"] > 0 else _default_atlas, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(preset["soft"] if preset["soft"] >= 0 else _default_soft)
	if sun != null and preset.has("shadow_mode"):
		sun.directional_shadow_mode = preset["shadow_mode"]
	var day_night := Globals.day_night as DayNightCycle
	if day_night != null:
		# The day/night cycle rewrites the sun's shadow flag and the fog every frame, so the preset goes through it
		day_night.shadows_enabled = preset["shadows"]
		day_night.fog_distance_scale = preset["fog_scale"]
		day_night.fog_min_density = preset["fog_density"]
		day_night.fancy_lighting = preset["fancy"] and _ultra_supported()
		day_night.glow_enabled = preset["glow"]
		day_night.clouds_enabled = preset["clouds"]
	elif sun != null:
		sun.shadow_enabled = preset["shadows"]
	if camera != null:
		var shortened: bool = preset["fog_scale"] < 1.0
		camera.far = day_night.max_fog_end() * FAR_MARGIN if shortened and day_night != null else _default_far

func _apply_display() -> void:
	Engine.max_fps = _fps
	if not OS.has_feature("web"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if _vsync else DisplayServer.VSYNC_DISABLED)

## Only called when fullscreen is toggled (and once at start-up): setting the window mode on every change would un-maximise the window
func _apply_fullscreen() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if _fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)

func _apply_interface() -> void:
	if camera != null:
		camera.fov = _fov
	if view != null:
		view.set("shift_lock_sensitivity", _base_look_sens * _sensitivity)
		view.set("drag_sensitivity", _base_drag_sens * _sensitivity)
	get_window().content_scale_factor = _ui_scale * UI_BASE_SCALE
	_fps_label.visible = _show_fps

func _update_pause_menu_scale_pivot() -> void:
	_center.pivot_offset = _center.size * 0.5

# --- Widgets <-> settings ------------------------------------------------------

func _sync_widgets(refresh_fullscreen := false) -> void:
	_syncing = true
	for bus in _volume:
		(get_node("%%%sSlider" % bus) as HSlider).value = _volume[bus]
	_quality_auto.button_pressed = _auto
	%QualityLow.button_pressed = not _auto and _quality == Quality.LOW
	%QualityMedium.button_pressed = not _auto and _quality == Quality.MEDIUM
	%QualityHigh.button_pressed = not _auto and _quality == Quality.HIGH
	%QualityUltra.button_pressed = not _auto and _quality == Quality.ULTRA
	%Fps30.button_pressed = _fps == 30
	%Fps60.button_pressed = _fps == 60
	%VsyncCheck.button_pressed = _vsync
	%FovSlider.value = _fov
	%UiScaleSlider.value = _ui_scale
	%SensitivitySlider.value = _sensitivity
	%FpsCheck.button_pressed = _show_fps
	if refresh_fullscreen:
		var mode := DisplayServer.window_get_mode()
		_fullscreen = mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	%FullscreenCheck.button_pressed = _fullscreen
	_syncing = false
	_refresh_quality_ui()
	_update_value_labels()

func _update_value_labels() -> void:
	for bus in _volume:
		(get_node("%%%sValue" % bus) as Label).text = "%d%%" % roundi(_volume[bus] * 100.0)
	%FovValue.text = "%d" % roundi(_fov)
	%UiScaleValue.text = "%.2fx" % _ui_scale
	%SensitivityValue.text = "%.2fx" % _sensitivity

func _build_controls_text() -> void:
	var text := ""
	for row in CONTROL_ROWS:
		var keys: PackedStringArray = []
		for action in row[1]:
			var key := _key_texts(action, true)
			if key != "":
				keys.append(key)
		if not keys.is_empty():
			text += "%s: [b]%s[/b]\n" % [row[0], " / ".join(keys)]
	for note in CONTROL_NOTES:
		text += "%s\n" % note
	text += "Pause menu: [b]%s[/b]" % _key_texts(PAUSE_ACTION, false)
	(%ControlsText as RichTextLabel).text = text

## Key names of an action as text (the keyboard and mouse bindings only); `first_only` stops at the first one
func _key_texts(action: StringName, first_only: bool) -> String:
	if not InputMap.has_action(action):
		return ""
	var names: PackedStringArray = []
	for event in InputMap.action_get_events(action):
		var key_name := ""
		if event is InputEventKey:
			key_name = event.as_text_physical_keycode() if event.physical_keycode != KEY_NONE else event.as_text_keycode()
			key_name = "`" if key_name == "QuoteLeft" else key_name
		elif event is InputEventMouseButton:
			key_name = event.as_text()
		if key_name != "":
			names.append(key_name)
			if first_only:
				break
	return " / ".join(names)

# --- Persistence ---------------------------------------------------------------

func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	for bus in _volume:
		_volume[bus] = clampf(config.get_value("audio", String(bus).to_lower(), _volume[bus]), 0.0, 1.0)
	_auto = config.get_value("graphics", "auto", _auto)
	_quality = clampi(config.get_value("graphics", "quality", _quality), Quality.LOW, _max_quality())
	if _auto:
		_quality = _max_quality() # Auto searches again from the top each launch
	_fps = 30 if int(config.get_value("graphics", "fps", _fps)) == 30 else 60
	_vsync = config.get_value("graphics", "vsync", _vsync)
	_fov = clampf(config.get_value("graphics", "fov", _fov), 50.0, 110.0)
	_fullscreen = config.get_value("interface", "fullscreen", _fullscreen)
	_ui_scale = clampf(config.get_value("interface", "ui_scale_rel", _ui_scale), 0.5, 2.0)
	_sensitivity = clampf(config.get_value("interface", "sensitivity", _sensitivity), 0.1, 3.0)
	_show_fps = config.get_value("interface", "show_fps", _show_fps)

func _save_settings() -> void:
	if not _dirty:
		return
	_dirty = false
	var config := ConfigFile.new()
	for bus in _volume:
		config.set_value("audio", String(bus).to_lower(), _volume[bus])
	config.set_value("graphics", "auto", _auto)
	config.set_value("graphics", "quality", _quality)
	config.set_value("graphics", "fps", _fps)
	config.set_value("graphics", "vsync", _vsync)
	config.set_value("graphics", "fov", _fov)
	config.set_value("interface", "fullscreen", _fullscreen)
	config.set_value("interface", "ui_scale_rel", _ui_scale)
	config.set_value("interface", "sensitivity", _sensitivity)
	config.set_value("interface", "show_fps", _show_fps)
	var err := config.save(SETTINGS_PATH)
	if err != OK:
		push_error("PauseMenu: failed to save settings (error %d)." % err)
		return
	_dirty = false
