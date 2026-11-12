extends CanvasLayer
class_name PlayerHUD

## Player vitals, always on screen: health bottom-left, energy bottom-right, plus red / yellow gradients
## on the screen edges (red: low health + hits) and a grey/blurry tunnel-vision effect for low energy AND low health.
## The grey effect stacks: being low on both is stronger than either alone (mirrors the player's movement slowdown).
## All the UI nodes live in main.tscn under PlayerHUD -- restyle/move them in the 2D editor.
## This script only feeds them numbers. It reads the Player's health_changed / energy_changed
## signals: the Player owns those stats, nothing is duplicated here.

@export_group("Nodes")
@export var vignette: ColorRect ## full-screen quad with the low_stat_vignette shader material (red: health / hits)
@export var energy_vignette: ColorRect ## full-screen quad with the low_energy_grey shader: drains colour, darkens + blurs the edges (low energy and/or low health). Drawn under the red one
@export var health_bar: ProgressBar
@export var health_label: Label
@export var energy_bar: ProgressBar
@export var energy_label: Label
@export var clock_label: Label ## top-left in-game clock (12h). Show/hide it with the toggle_clock action (G)
@export var day_night: DayNightCycle ## where the in-game time of day is read from

@export_group("Low-health warning (red)")
## Below this much health (in HP) the red edge stays on screen permanently.
@export var low_health_threshold := 30.0
## Intensity (as a fraction of warning_max_intensity) right at the threshold. It rises linearly
## to full at 0 HP, so the closer to death, the stronger the vignette.
@export_range(0.0, 1.0) var low_health_floor := 0.25
@export_range(0.0, 1.0) var warning_max_intensity := 0.85

@export_group("Hit flash")
## Peak intensity of a full-strength flash.
@export_range(0.0, 1.0) var hit_flash_intensity := 1.0
## Damage (summed over hits that land while a flash is still showing) that gives the strongest and
## longest flash. Anything less scales linearly between the min and max values below.
@export var damage_for_full_flash := 30.0
## Flash strength (0-1) of a tiny hit, rising linearly to 1 at damage_for_full_flash.
@export_range(0.0, 1.0) var hit_flash_min_strength := 0.25
## How long the flash lasts, in seconds: a tiny hit vs. damage_for_full_flash or more.
@export var hit_flash_min_duration := 0.5
@export var hit_flash_max_duration := 4.0
## Smaller drops than this (hunger chip damage ticking every frame) do not flash.
@export var hit_flash_min_damage := 1.0
## How fast the low-health vignette eases DOWN as health recovers (hits always show instantly).
@export var smoothing := 6.0

@export_group("Low-energy / low-health effect (grey)")
## Below this fraction of energy OR health the grey effect starts fading in (full at 0).
@export_range(0.05, 0.9) var low_threshold := 0.3
## Peak strength of the grey effect when only ONE of energy / health is low (1 = nearly black-and-white,
## dark and blurry at the edges). It shows together with the red health warning.
@export_range(0.0, 1.0) var energy_warning_max_intensity := 0.7
## Peak strength when BOTH energy and health are low. Should be higher than the single-stat peak.
@export_range(0.0, 1.0) var combined_warning_max_intensity := 0.95

var _player = null # the Player (untyped: its signals/stats live on player.gd)
var _vignette_mat: ShaderMaterial
var _energy_vignette_mat: ShaderMaterial

var _health_hp := 100.0
var _health_frac := 1.0
var _energy_frac := 1.0
var _last_health := -1.0
var _flash := 0.0
var _flash_decay_rate := 1.0 # flash strength lost per second (set per hit from its duration)
var _burst_damage := 0.0 # damage summed over hits while a flash is still showing
var _low_intensity := 0.0 # smoothed persistent low-health vignette
var _intensity := 0.0
var _energy_intensity := 0.0
var _last_clock_minute := -1


func _ready() -> void:
	_vignette_mat = vignette.material as ShaderMaterial
	vignette.visible = false
	_energy_vignette_mat = energy_vignette.material as ShaderMaterial
	energy_vignette.visible = false
	_try_bind_player()


func _process(delta: float) -> void:
	_update_clock()
	if _player == null:
		_try_bind_player() # the Player registers itself with Globals in its own _ready()

	var health_severity := _health_severity()
	if _flash > 0.0:
		_flash = maxf(_flash - _flash_decay_rate * delta, 0.0)
		if _flash <= 0.0:
			_burst_damage = 0.0
	var low_target := health_severity * warning_max_intensity
	if low_target > _low_intensity:
		_low_intensity = low_target
	else:
		_low_intensity = lerpf(_low_intensity, low_target, clampf(smoothing * delta, 0.0, 1.0))
	# The flash is applied directly (no smoothing) so its strength and duration are exactly the damage-based ones
	_intensity = maxf(_low_intensity, _flash * hit_flash_intensity)

	vignette.visible = _intensity > 0.004 # skip the full-screen draw entirely when healthy
	if vignette.visible:
		_vignette_mat.set_shader_parameter("intensity", _intensity)
	
	# Grey low-energy / low-health effect. Either stat being low brings it in; when both are low the
	# two stack so it gets stronger than with just one (red is drawn on top and shows independently).
	var energy_low := _low_amount(_energy_frac)
	var health_low := _low_amount(_health_frac)
	var energy_target := maxf(energy_low, health_low) * energy_warning_max_intensity \
			+ minf(energy_low, health_low) * maxf(combined_warning_max_intensity - energy_warning_max_intensity, 0.0)
	_energy_intensity = lerpf(_energy_intensity, energy_target, clampf(smoothing * delta, 0.0, 1.0))
	energy_vignette.visible = _energy_intensity > 0.004
	if energy_vignette.visible:
		_energy_vignette_mat.set_shader_parameter("intensity", _energy_intensity)


func _unhandled_input(event: InputEvent) -> void:
	if clock_label and event.is_action_pressed("toggle_clock"):
		clock_label.visible = not clock_label.visible
		_last_clock_minute = -1 # refresh the text right away when it comes back


# In-game time as 12h text. DayNightCycle.time_of_day is 0..1 with 0 = midnight, so 0.25 = 6:00 AM, 0.5 = 12:00 PM.
# Only touches the label when the displayed minute changes.
func _update_clock() -> void:
	if clock_label == null or day_night == null or not clock_label.visible:
		return
	var minute_of_day := int(day_night.time_of_day * 1440.0) % 1440
	if minute_of_day == _last_clock_minute:
		return
	_last_clock_minute = minute_of_day
	var hour_24 := floori(minute_of_day / 60.0)
	var hour_12 := hour_24 % 12
	if hour_12 == 0:
		hour_12 = 12
	clock_label.text = "%d:%02d %s" % [hour_12, minute_of_day % 60, "AM" if hour_24 < 12 else "PM"]


# 0 at/above low_health_threshold; below it, always at least low_health_floor, rising linearly to 1 at 0 HP.
func _health_severity() -> float:
	if _health_hp >= low_health_threshold:
		return 0.0
	var closeness := 1.0 - clampf(_health_hp / maxf(low_health_threshold, 0.001), 0.0, 1.0)
	return lerpf(low_health_floor, 1.0, closeness)


# 0 when the stat is above the threshold, rising smoothly to 1 as it empties.
func _low_amount(fraction: float) -> float:
	return smoothstep(0.0, 1.0, clampf(1.0 - fraction / low_threshold, 0.0, 1.0))


func _try_bind_player() -> void:
	if Globals.player == null:
		return
	_player = Globals.player
	_player.health_changed.connect(_on_health_changed)
	_player.energy_changed.connect(_on_energy_changed)
	_last_health = _player.health
	_on_health_changed(_player.health, _player.max_health)
	_on_energy_changed(_player.energy, 100.0)
	_last_health = _player.health


func _on_health_changed(current: float, maximum: float) -> void:
	var damage := _last_health - current
	if _last_health >= 0.0 and damage >= hit_flash_min_damage:
		_burst_damage += damage
		var fraction := clampf(_burst_damage / maxf(damage_for_full_flash, 0.001), 0.0, 1.0)
		_flash = maxf(_flash, lerpf(hit_flash_min_strength, 1.0, fraction))
		# Bigger damage: stronger AND longer. Fade linearly to zero over the damage-based duration.
		_flash_decay_rate = _flash / lerpf(hit_flash_min_duration, hit_flash_max_duration, fraction)
	_last_health = current
	_health_hp = current
	_health_frac = current / maxf(maximum, 1.0)
	_set_bar(health_bar, health_label, "Health", current, maximum)


func _on_energy_changed(current: float, maximum: float) -> void:
	_energy_frac = current / maxf(maximum, 1.0)
	_set_bar(energy_bar, energy_label, "Energy", current, maximum)


func _set_bar(bar: ProgressBar, label: Label, title: String, current: float, maximum: float) -> void:
	bar.max_value = maxf(maximum, 1.0)
	bar.value = clampf(current, 0.0, bar.max_value)
	label.text = "%s  %d" % [title, roundi(current)]
