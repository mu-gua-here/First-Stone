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

@export var bar_color: Color = Color(0.4, 0.8, 0.3, 1): # matches citizen HappinessBar fill green
	set(value):
		bar_color = value
		if _fill_style != null:
			_fill_style.bg_color = value
@export var bg_color: Color = Color(0.05, 0.05, 0.07, 0.65) # background tint; the scene's background style by default

var _fill_style: StyleBoxFlat
var _bg_style: StyleBoxFlat

func _ready() -> void:
	# The LOOK (rounded corners, border) is authored in the scene: theme overrides on the ProgressBar,
	# exactly like the HUD bars. Don't build new StyleBoxes here -- a fresh StyleBoxFlat has square corners
	# and would replace the rounded ones. Those StyleBoxes are shared by every instance of this scene, so
	# each instance takes a private copy (keeping the corners) to recolour without tinting all the others.
	_fill_style = _private_copy("fill")
	_bg_style = _private_copy("background")
	_fill_style.bg_color = bar_color
	_bg_style.bg_color = bg_color

func _private_copy(style_name: String) -> StyleBoxFlat:
	var original := bar.get_theme_stylebox(style_name) as StyleBoxFlat
	var copy: StyleBoxFlat = original.duplicate() if original != null else StyleBoxFlat.new()
	bar.add_theme_stylebox_override(style_name, copy)
	return copy

func set_progress(value01: float) -> void:
	bar.value = clamp(value01, 0.0, 1.0)

# Changes the fill color after the fact -- used by construction sites to
# flag "stalled, missing resources" (e.g. a red/orange tint) without needing
# a second bar node.
func set_bar_color(new_color: Color) -> void:
	bar_color = new_color
	if _fill_style != null:
		_fill_style.bg_color = new_color

func set_visible_in_range(in_range: bool) -> void:
	sprite.visible = in_range
	viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if in_range else SubViewport.UPDATE_DISABLED
	)
