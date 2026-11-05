extends Node3D
class_name StockpileSign

## A wooden board standing at the edge of the stockpile area (the yellow disc), so it is obvious what the disc is.
## It also carries the live count (both faces), and bounces whenever a log is added to the pile.
## Builder positions it (Builder.stockpile_sign) and feeds it the text.

@export var front_count: Label3D
@export var back_count: Label3D

var _bounce_tween: Tween


func set_counts(text: String) -> void:
	front_count.text = text
	back_count.text = text


func bounce() -> void:
	if _bounce_tween != null:
		_bounce_tween.kill()
	scale = Vector3.ONE
	_bounce_tween = create_tween()
	_bounce_tween.tween_property(self, "scale", Vector3.ONE * 1.12, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_bounce_tween.tween_property(self, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
