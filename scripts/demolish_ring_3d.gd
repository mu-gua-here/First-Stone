extends Node3D
class_name DemolishRing3D

## A circular timer floating over a building that is being taken apart: the arc fills clockwise as the
## player's labour (enter with Command+B, then click and hold the structure) damages it, and the structure only disappears once
## the circle is complete. Same idea as ProgressIndicator3D, but a ring instead of a bar.

@onready var _ring: TextureProgressBar = $Sprite3D/SubViewport/Ring


func set_progress(progress01: float) -> void:
	_ring.value = clampf(progress01, 0.0, 1.0)
