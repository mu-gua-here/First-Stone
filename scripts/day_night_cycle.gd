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
@export var day_length_seconds: float = 1200.0
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

## Ultra graphics preset (pause_menu.gd, Forward+ only): SSAO and volumetric fog (with light shafts from the sun) replace the
## depth fog, and the ocean shader gets sharper sky reflections. Screen-space reflections can't touch a transparent surface,
## so the water's reflections come from its own shader (reflection_boost).
var fancy_lighting := false
## Bloom/glow, kept independent of fancy SSAO/volumetric lighting so the graphics preset can disable it on Low/Medium.
var glow_enabled := true
## Cloud layer (High and Ultra, set by pause_menu.gd): the visible clouds and their reflection in the ocean
var clouds_enabled := false

@export_group("Ultra lighting")
@export var noon_volumetric_density := 0.01
@export var night_volumetric_density := 0.025
## The volumetric fog glows in the fog's own time-of-day colour (the same one the depth fog uses) at this strength, so it
## is bright and pale at noon and a faint blue at night instead of being lit by the sun alone.
@export var noon_volumetric_emission_strength := 0.35
@export var night_volumetric_emission_strength := 0.06

@export_group("Clouds")
## Cloud layer + the same clouds in the ocean's reflections (shaders/clouds.gdshaderinc). Shown on High and Ultra (clouds_enabled).
## cloud_layer is a big plane that follows the camera with shaders/cloud_layer.gdshader on it.
@export var cloud_layer: MeshInstance3D
@export var cloud_height := 320.0
@export var cloud_wind := Vector2(6.0, 2.0) # m/s
@export_range(0.0, 1.0) var cloud_coverage := 0.5
@export var noon_cloud_color := Color(1.0, 1.0, 1.0)
@export var night_cloud_color := Color(0.1, 0.12, 0.2)
@export var noon_cloud_shade_color := Color(0.62, 0.68, 0.78)
@export var night_cloud_shade_color := Color(0.03, 0.04, 0.08)
var _cloud_offset := Vector2.ZERO
var _fancy_applied := false

func _update_clouds(delta: float) -> void:
	if cloud_layer == null:
		return
	cloud_layer.visible = clouds_enabled
	if ocean_material != null:
		ocean_material.set_shader_parameter("cloud_reflection", 1.0 if clouds_enabled else 0.0)
	if not clouds_enabled:
		return
	var day_pct := clampf(sin(time_of_day * TAU - PI / 2.0), 0.0, 1.0)
	_cloud_offset += cloud_wind * delta
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		cloud_layer.global_position = Vector3(camera.global_position.x, cloud_height, camera.global_position.z)
	var to_sun := Vector2(sun.global_transform.basis.z.x, sun.global_transform.basis.z.z) if sun != null else Vector2.ZERO
	for material in [cloud_layer.material_override as ShaderMaterial, ocean_material]:
		if material == null:
			continue
		material.set_shader_parameter("cloud_height", cloud_height)
		material.set_shader_parameter("cloud_offset", _cloud_offset)
		material.set_shader_parameter("cloud_coverage", cloud_coverage)
		material.set_shader_parameter("cloud_color", night_cloud_color.lerp(noon_cloud_color, day_pct))
		material.set_shader_parameter("cloud_shade_color", night_cloud_shade_color.lerp(noon_cloud_shade_color, day_pct))
		if to_sun.length() > 0.001:
			material.set_shader_parameter("cloud_sun_dir", to_sun.normalized())

func _apply_fancy_lighting(env: Environment, day_pct: float) -> void:
	var supports_fancy_lighting := RenderingServer.get_current_rendering_method() == "forward_plus" and not OS.has_feature("web")
	env.glow_enabled = glow_enabled
	if fancy_lighting and supports_fancy_lighting:
		_fancy_applied = true
		env.fog_enabled = false
		if not env.ssao_enabled:
			env.ssao_enabled = true
		if not env.volumetric_fog_enabled:
			env.volumetric_fog_enabled = true
		env.volumetric_fog_density = lerpf(night_volumetric_density, noon_volumetric_density, day_pct)
		env.volumetric_fog_albedo = env.fog_light_color
		var glow := lerpf(night_volumetric_emission_strength, noon_volumetric_emission_strength, day_pct)
		env.volumetric_fog_emission = Color(env.fog_light_color.r * glow, env.fog_light_color.g * glow, env.fog_light_color.b * glow)
		env.volumetric_fog_length = maxf(noon_fog_depth_end * fog_distance_scale / _fog_mult, 64.0)
	else:
		_fancy_applied = false # back to the authored depth fog
		env.fog_enabled = true
		env.ssao_enabled = false
		if supports_fancy_lighting:
			env.volumetric_fog_enabled = false

# Set by the pause menu's graphics presets (pause_menu.gd). They live here because _apply() rewrites the sun's shadow flag
# and the fog every frame, so setting them on the sun / environment directly would be overwritten straight away.
var shadows_enabled := true # false = the sun never casts shadows
var fog_distance_scale := 1.0 # below 1 pulls the fog in, so a shorter camera far plane stays hidden inside it
var fog_min_density := 0.0 # raises the fog's maximum opacity (0 = leave the authored curve alone)

## Farthest distance the fog still lets you see (any time of day). The low graphics preset sets the camera's far plane just past it.
func max_fog_end() -> float:
	return maxf(noon_fog_depth_end, night_fog_depth_end) * fog_distance_scale / _fog_mult

## In-game days elapsed since the game started (fraction included). The clock for everything that takes days: regrowth, births.
## It only advances while `enabled`, so stopping the cycle stops the world's slow processes too.
var total_days := 0.0

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
	Globals.register_day_night(self)
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
	_update_clouds(delta)
	# NOTE: `enabled` used to only gate whether time_of_day advances, while
	# _apply() ran every frame regardless
	if not enabled:
		_apply(time_of_day)
		return
	if day_length_seconds <= 0.0:
		day_length_seconds = 1.0
	time_of_day = fposmod(time_of_day + delta / day_length_seconds, 1.0)
	total_days += delta / day_length_seconds
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

		sun.shadow_enabled = shadows_enabled and (day_pct > 0.02 or horizon_pct > 0.3)

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
			env.fog_density = maxf(lerp(night_fog_density, noon_fog_density, day_pct), fog_min_density)
			env.fog_depth_begin = lerp(night_fog_depth_begin, noon_fog_depth_begin, day_pct) * fog_distance_scale / _fog_mult
			env.fog_depth_end = lerp(night_fog_depth_end, noon_fog_depth_end, day_pct) * fog_distance_scale / _fog_mult
			if ocean_material != null:
				ocean_material.set_shader_parameter("env_fog_color", env.fog_light_color)
				ocean_material.set_shader_parameter("env_fog_begin", env.fog_depth_begin)
				ocean_material.set_shader_parameter("env_fog_end", env.fog_depth_end)
				ocean_material.set_shader_parameter("env_fog_curve", env.fog_depth_curve)
				# (with fancy lighting the engine fog is off, but the transparent ocean still fades out with the same depth fog)
				ocean_material.set_shader_parameter("env_fog_density", env.fog_density if (env.fog_enabled or fancy_lighting) else 0.0)
				ocean_material.set_shader_parameter("reflection_boost", 1.0 if fancy_lighting else 0.0)
			_apply_fancy_lighting(env, day_pct)
