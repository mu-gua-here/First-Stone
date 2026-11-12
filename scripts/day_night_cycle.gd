extends Node3D
class_name DayNightCycle

## Lightweight day/night cycle. No shaders, no post-process — just rotates the
## sun light and lerps a couple of colors on the WorldEnvironment. Cheap enough
## for web export.
##
## time_of_day is 0..1: 0.0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset.

@export var enabled := true

@export_group("General")
## How many real-world seconds a full in-game day takes.
@export var day_length_seconds: float = 600.0
@export_range(0.0, 1.0) var time_of_day: float = 0.25
## Where the cycle starts, 0..1
@export_range(0.0, 1.0) var start_time: float = 0.25

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment

@export_group("Light")
@export var noon_light_color: Color = Color(1.0, 0.97, 0.9)
@export var noon_light_energy: float = 1.1
@export var horizon_light_color: Color = Color(1.0, 0.55, 0.35)
@export var horizon_light_energy: float = 0.6
@export var night_light_color: Color = Color(0.25, 0.3, 0.45)
@export var night_light_energy: float = 0.05

@export_group("Moon")
## Second DirectionalLight3D kept exactly opposite the sun, so whatever the sun leaves in
## shadow (e.g. the back of the player) still gets light -- and it's what lights the night.
## Created automatically if left empty.
@export var moon: DirectionalLight3D
@export var moon_light_color: Color = Color(0.55, 0.65, 1.0)
@export var moon_light_energy: float = 0.4
## Energy of the opposite-side light while the sun is up (0 = moon only shines at night).
## A small value acts as a fill light from behind/below during the day.
@export var moon_day_fill_energy: float = 0.2
@export var moon_shadows := false  # extra shadow pass; keep off for web

@export_group("Ambient")
@export var noon_ambient_color: Color = Color(0.662745, 0.694118, 0.772549)
@export var night_ambient_color: Color = Color(0.16, 0.19, 0.30)
## Multipliers on the ambient energy authored in the Environment resource (read once per environment,
## so native and compat each keep their own base). Day > 1 brightens daytime, night < 1 darkens the night.
@export var noon_ambient_energy_mult: float = 0.6
@export var night_ambient_energy_mult: float = 0.3
## Extra ambient while the sun is near the horizon (dawn/dusk), when the sun alone leaves a lot dark.
## Added on top of the day/night multiplier, so ambient is strongest when the sun is weakest.
@export var horizon_ambient_energy_bonus: float = 0.5
## Extra brightness per renderer, multiplied onto all ambient. The web (Compatibility) build renders darker, so it gets more.
@export var native_ambient_boost: float = 1.0
@export var compat_ambient_boost: float = 1.8
@export var noon_bg_color: Color = Color(0.560784, 0.592157, 0.670588)
@export var night_bg_color: Color = Color(0.02, 0.02, 0.05)

## Only matters if the WorldEnvironment's background_mode is Sky (BG_SKY) with a
## ProceduralSkyMaterial assigned -- see native-main-environment.tres. Ignored under
## background_mode Color, where noon_bg_color/night_bg_color above are what's visible instead.
@export_group("Sky")
@export var noon_sky_top_color: Color = Color(0.30, 0.45, 0.75)
@export var night_sky_top_color: Color = Color(0.01, 0.01, 0.04)
@export var noon_sky_horizon_color: Color = Color(0.68, 0.72, 0.78)
@export var night_sky_horizon_color: Color = Color(0.03, 0.03, 0.07)
@export var noon_sky_energy: float = 1.0
@export var night_sky_energy: float = 0.15

@export_group("Fog")
@export var noon_fog_color: Color = Color(0.860812, 0.8745884, 0.897545)
@export var night_fog_color: Color = Color(0.05, 0.06, 0.1)
@export var noon_fog_density: float = 0.8
@export var night_fog_density: float = 0.5
## The environments use DEPTH fog (fog_mode = 1). In depth mode fog_density is the fog's MAXIMUM opacity (1.0 = fully hides
## the scene at fog_depth_end, 0.0 = no fog at all) and begin/end set how far away it ramps in. A low noon density is
## what made the fog look absent in daylight.
@export var noon_fog_depth_begin: float = 20.0
@export var noon_fog_depth_end: float = 200.0
@export var night_fog_depth_begin: float = 2.0
@export var night_fog_depth_end: float = 45.0
## Per-renderer fog strength. Higher = thicker fog (fog starts and ends closer: begin/end above are divided by it).
## Depth fog's curve is authored in each environment resource.
@export var native_fog_distance_mult: float = 1.0
@export var compat_fog_distance_mult: float = 1.0
## The ocean's ShaderMaterial (the one on WaterSurface). The ocean is transparent, so engine fog can't fade it out; the
## water shader does its own fog instead, fed from the active Environment's fog values here.
@export var ocean_material: ShaderMaterial

# Set by other scripts (view.gd) to stop this script's own fog lerp from
# fighting theirs -- e.g. while the camera is underwater.
var suppress_fog := false

# Writing to ProceduralSkyMaterial properties forces Godot to re-bake the sky
# radiance/reflection map that frame -- very expensive (measured ~23% of CPU
# frame time on web export)
var _last_sky_day_pct: float = -1.0
# Ambient energy authored in whichever Environment is active (main.gd swaps it for compat after our _ready)
var _ambient_env: Environment
var _base_ambient_energy := 1.0
# Change update time interval based on renderer, since web is weaker
var SKY_UPDATE_THRESHOLD := 0.01 if OS.has_feature("web") else 0.001
var _fog_mult: float = 1.0
var _ambient_boost: float = 1.0

# Sky-only twins of the sun/moon. The procedural sky multiplies the whole sky (discs included) by
# sky_energy_multiplier, which is ~0.15 at dawn/dusk/night, so the real lights draw near-black discs.
# These extra lights shine ONLY on the sky (no scene lighting) and are boosted to cancel that dimming.
# The real sun/moon are switched to Light Only so each disc is drawn once.
const SUN_DISC_BRIGHTNESS := 3.0
const MOON_DISC_BRIGHTNESS := 2.0
var _sun_disc: DirectionalLight3D
var _moon_disc: DirectionalLight3D

func _ready() -> void:
	if moon == null:
		moon = DirectionalLight3D.new()
		moon.name = "Moon"
		add_child(moon)
	_sun_disc = _make_sky_disc("SunDisc")
	_moon_disc = _make_sky_disc("MoonDisc")
	if sun:
		sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	time_of_day = start_time
	_fog_mult = maxf(compat_fog_distance_mult if RenderingServer.get_current_rendering_method() == "gl_compatibility" else native_fog_distance_mult, 0.01)
	_ambient_boost = compat_ambient_boost if RenderingServer.get_current_rendering_method() == "gl_compatibility" else native_ambient_boost
	_apply(time_of_day)


func _make_sky_disc(disc_name: String) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = disc_name
	l.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
	l.shadow_enabled = false
	add_child(l)
	return l


func _process(delta: float) -> void:
	# NOTE: `enabled` used to only gate whether time_of_day advances, while
	# _apply() ran every frame regardless
	if not enabled:
		_apply(time_of_day)
		return
	if day_length_seconds <= 0.0:
		day_length_seconds = 1.0
	time_of_day = fposmod(time_of_day + delta / day_length_seconds, 1.0)
	_apply(time_of_day)


func _apply(t: float) -> void:
	var angle := t * TAU
	# -1 at midnight, 1 at noon, 0 right at sunrise/sunset.
	var height := sin(angle - PI / 2.0)
	var day_pct: float = clamp(height, 0.0, 1.0)
	var horizon_pct: float = clamp(1.0 - abs(height) * 4.0, 0.0, 1.0)
	
	# NOTE: ambient energy is written once, below (as a multiplier on the environment's authored base).
	# A second write here used to corrupt that base, so ambient/tonemap never behaved predictably.

	if sun:
		sun.rotation.x = angle + PI / 2.0

		var color := night_light_color.lerp(noon_light_color, day_pct)
		sun.light_color = color.lerp(horizon_light_color, horizon_pct)

		var energy: float = lerp(night_light_energy, noon_light_energy, day_pct)
		sun.light_energy = lerp(energy, horizon_light_energy, horizon_pct)

		sun.shadow_enabled = day_pct > 0.02 or horizon_pct > 0.3

		# Moon: always the exact opposite direction of the sun (flip 180 deg about its
		# local Y so -Z, the light direction, reverses). Fades in as the sun sets.
		if moon and moon.is_inside_tree() and sun.is_inside_tree():
			moon.global_basis = sun.global_basis * Basis(Vector3.UP, PI)
			var night_pct := 1.0 - smoothstep(0.0, 0.35, day_pct)
			moon.light_color = moon_light_color
			moon.light_energy = lerp(moon_day_fill_energy, moon_light_energy, night_pct)
			moon.shadow_enabled = moon_shadows and night_pct > 0.5
			moon.visible = moon.light_energy > 0.001

		# Boosted sky-only discs: brightness / sky multiplier cancels the sky dimming.
		var sky_mult := maxf(lerp(night_sky_energy, noon_sky_energy, day_pct), 0.01)
		_sun_disc.global_basis = sun.global_basis
		_sun_disc.light_color = sun.light_color
		_sun_disc.light_energy = SUN_DISC_BRIGHTNESS / sky_mult
		if moon and moon.is_inside_tree():
			_moon_disc.global_basis = moon.global_basis
			_moon_disc.light_color = moon_light_color
			_moon_disc.light_energy = MOON_DISC_BRIGHTNESS / sky_mult
	if world_environment and world_environment.environment:
		var env := world_environment.environment
		if env != _ambient_env:
			_ambient_env = env
			_base_ambient_energy = env.ambient_light_energy
		env.ambient_light_color = night_ambient_color.lerp(noon_ambient_color, day_pct)
		env.ambient_light_energy = _base_ambient_energy * _ambient_boost * (lerp(night_ambient_energy_mult, noon_ambient_energy_mult, day_pct) + horizon_ambient_energy_bonus * horizon_pct)
		env.background_color = night_bg_color.lerp(noon_bg_color, day_pct)

		# Sky reactivity -- only does anything when background_mode is Sky with a
		# ProceduralSkyMaterial assigned
		# Gated behind SKY_UPDATE_THRESHOLD
		if env.sky and env.sky.sky_material is ProceduralSkyMaterial \
				and absf(day_pct - _last_sky_day_pct) >= SKY_UPDATE_THRESHOLD:
			var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
			sky_mat.sky_top_color = night_sky_top_color.lerp(noon_sky_top_color, day_pct)
			sky_mat.sky_horizon_color = night_sky_horizon_color.lerp(noon_sky_horizon_color, day_pct)
			sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
			sky_mat.sky_energy_multiplier = lerp(night_sky_energy, noon_sky_energy, day_pct)
			_last_sky_day_pct = day_pct

		# Fog reactivity -- thicker and bluer at night, thin and warm at noon.
		# Skipped while view.gd while the camera is underwater
		if not suppress_fog:
			env.fog_light_color = night_fog_color.lerp(noon_fog_color, day_pct)
			env.fog_density = lerp(night_fog_density, noon_fog_density, day_pct)
			env.fog_depth_begin = lerp(night_fog_depth_begin, noon_fog_depth_begin, day_pct) / _fog_mult
			env.fog_depth_end = lerp(night_fog_depth_end, noon_fog_depth_end, day_pct) / _fog_mult
			if ocean_material != null:
				ocean_material.set_shader_parameter("env_fog_color", env.fog_light_color)
				ocean_material.set_shader_parameter("env_fog_begin", env.fog_depth_begin)
				ocean_material.set_shader_parameter("env_fog_end", env.fog_depth_end)
				ocean_material.set_shader_parameter("env_fog_curve", env.fog_depth_curve)
				ocean_material.set_shader_parameter("env_fog_density", env.fog_density if env.fog_enabled else 0.0)
