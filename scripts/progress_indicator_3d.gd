extends Node3D
class_name ProgressIndicator3D

## A single floating progress bar, billboarded toward the camera. Same construction sites and
## gathering trees can reuse it without duplicating the SubViewport setup.
##
## Usage: instantiate, add_child it, set bar_color if you want something
## other than the default green, then call set_progress(0..1) each tick.
## Distance-to-player gating (visibility + render pause) is the caller's
## job via set_visible_in_range(), same as citizen.gd's BAR_VISIBLE_DISTANCE pattern

@onready var sprite: Sprite3D = $Sprite3D
@onready var viewport: SubViewport = $Sprite3D/SubViewport
@onready var bar: ProgressBar = $Sprite3D/SubViewport/ProgressBar
@onready var value_label: Label3D = $Label3D

## Show the number (0-100) over the bar. Off by default (construction sites / trees); the nameplate's health and energy bars turn it on.
@export var show_value := false:
	set(value):
		show_value = value
		_apply_value_visibility()

@export var bar_color: Color = Color(0.4, 0.8, 0.3, 1): # matches citizen HappinessBar fill green
	set(value):
		bar_color = value
		if _fill_style != null:
			_fill_style.bg_color = value
@export var bg_color: Color = Color(0.05, 0.05, 0.07, 0.65) # background tint; the scene's background style by default

var _fill_style: StyleBoxFlat
var _bg_style: StyleBoxFlat
var _status_text := "" # when non-empty, shown over the bar instead of the percentage (e.g. construction sites: "2/5 logs")

func _ready() -> void:
	# The viewport texture is hooked up here, not in the scene: a ViewportTexture saved in the .tscn resolves its
	# "Sprite3D/SubViewport" path when the scene is instanced, which logs "Path to node is invalid" whenever the
	# indicator is created and parented from code before it is in the tree.
	sprite.texture = viewport.get_texture()
	# The LOOK (rounded corners, border) is authored in the scene: theme overrides on the ProgressBar,
	# exactly like the HUD bars. Don't build new StyleBoxes here -- a fresh StyleBoxFlat has square corners
	# and would replace the rounded ones. Those StyleBoxes are shared by every instance of this scene, so
	# each instance takes a private copy (keeping the corners) to recolour without tinting all the others.
	_fill_style = _private_copy("fill")
	_bg_style = _private_copy("background")
	_fill_style.bg_color = bar_color
	_bg_style.bg_color = bg_color
	_apply_value_visibility()

func _private_copy(style_name: String) -> StyleBoxFlat:
	var original := bar.get_theme_stylebox(style_name) as StyleBoxFlat
	var copy: StyleBoxFlat = original.duplicate() if original != null else StyleBoxFlat.new()
	bar.add_theme_stylebox_override(style_name, copy)
	return copy

func set_progress(value01: float) -> void:
	bar.value = clamp(value01, 0.0, 1.0)
	_refresh_label()

# Overrides the number over the bar with custom text ("" goes back to the percentage / hidden)
func set_status_text(text: String) -> void:
	if text == _status_text:
		return
	_status_text = text
	_refresh_label()

func _refresh_label() -> void:
	if not is_node_ready():
		return
	value_label.text = _status_text if _status_text != "" else str(roundi(bar.value * 100.0))
	_apply_value_visibility()

func _apply_value_visibility() -> void:
	if is_node_ready():
		value_label.visible = (show_value or _status_text != "") and sprite.visible

# Changes the fill color after the fact -- used by construction sites to
# flag "stalled, missing resources" (e.g. a red/orange tint) without needing
# a second bar node.
func set_bar_color(new_color: Color) -> void:
	bar_color = new_color
	if _fill_style != null:
		_fill_style.bg_color = new_color

func set_visible_in_range(in_range: bool) -> void:
	sprite.visible = in_range
	_apply_value_visibility()
	viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if in_range else SubViewport.UPDATE_DISABLED
	)
