extends Node3D
class_name Nameplate

## Floating name with an optional health bar and energy bar under it. Used above other players' avatars
## (see net_player.gd) and, with the bars switched off, above your own head (Player.nameplate).
## Each bar is a ProgressIndicator3D (billboarded, the same one construction sites use), scaled down in the scene.

@export var name_label: Label3D
@export var health_bar: ProgressIndicator3D
@export var energy_bar: ProgressIndicator3D
## Off = name only (your own plate: your bars are in the HUD).
@export var show_bars := true:
	set(value):
		show_bars = value
		_apply_bar_visibility()


func _ready() -> void:
	_apply_bar_visibility()


func set_player_name(text: String) -> void:
	name_label.text = text


## Both values 0..100.
func set_stats(health: float, energy: float) -> void:
	health_bar.set_progress(health / 100.0)
	energy_bar.set_progress(energy / 100.0)


func _apply_bar_visibility() -> void:
	if not is_node_ready():
		return
	health_bar.set_visible_in_range(show_bars) # also stops its viewport rendering while hidden
	energy_bar.set_visible_in_range(show_bars)
