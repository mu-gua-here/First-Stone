extends Node3D

# Object to track for camera
@export_category("Camera")
@export var target: Node3D
@export var follow_speed: float = 10.0

@onready var spring_arm := $SpringArm3D as SpringArm3D
@onready var copy_target := $SpringArm3D/CopyMe as Marker3D
@onready var camera := $Camera as Camera3D

# Zoom settings
@export_category("Zoom")
@export var max_zoom := 20.0
@export var min_zoom := 0.0 # low enough to reach first person by zooming in (see first_person_distance)
@export var scroll_zoom_speed := 5.0
var zoom: float = 6.0

# When the spring arm is pushed in by an obstacle (trees), the camera HOLDS that closer distance
# instead of springing back out the instant the obstacle is gone -- otherwise walking through a
# forest makes it bounce in and out. It only eases back out after the view has stayed clear for
# zoom_recover_delay seconds (set it huge to never recover), or at once when you zoom out yourself.
@export var zoom_recover_delay := 4.0
@export var zoom_recover_speed := 2.0 # m/s while easing back out
var _held_length := INF
var _clear_time := 0.0
var _last_zoom := 6.0

# Viewing settings
@export_category("Viewing")
@export var springarm_enabled := true
@export var view_angle_restricted := true

# Viewing / Sensitivity
@export_range(0.1, 5.0) var mouse_sensitivity = 0.5

# Keyboard orbit: arrow keys (camera_left/right/forward/back actions), degrees per second
@export var key_rotate_speed := 90.0

# Mouse drag orbit, degrees per pixel. Right / middle button always orbits. Left button orbits only when
# the press isn't doing something else: gathering/building (player is working), build mode, or a selected
# citizen waiting for an order. So left-dragging on a tree you are in reach of still chops it.
@export var drag_sensitivity := 0.25
enum DragState { NONE, PENDING, ROTATING, BLOCKED }
var _drag_state := DragState.NONE

# Anti-occlusion. Both the pivot (follow_speed) and the camera (CAMERA_FOLLOW) trail the player while it
# moves, so in a tight space (short spring arm) a running player catches up with the camera and fills the
# screen. 1) Lead the pivot by velocity * total lag so the trailing cancels out. 2) Hard floor: the camera
# is never allowed closer than min_camera_distance to the player's head.
const CAMERA_FOLLOW := 10.0
@export var lag_compensation := 1.0 # 0 = off, 1 = cancel the follow lag exactly
# The lead only matters when the camera is close (tight spaces). Full strength at/below lead_full_distance,
# fading to nothing at lead_off_distance, so a far-out camera isn't jerked around by velocity changes.
@export_category("First person")
@export var lead_full_distance := 3.0
@export var lead_off_distance := 6.0
@export var min_camera_distance := 1.5
@export var head_height := 1.0 # player's head above target origin, for the distance floor

# First person. The camera never gets closer than first_person_distance in third person: if the arm
# length (scroll zoom OR pushed in by trees/walls) drops below it, the camera cuts to the player's eyes
# and the player's body stops being drawn (it still casts a shadow). It goes back to third person once
# the arm is longer than first_person_distance + first_person_hysteresis. Done by distance, not by
# hiding the body when it happens to overlap the screen, so it keeps working with bigger models.
@export var first_person_distance := 1.5
@export var first_person_hysteresis := 0.5
@export var eye_height := 0.6 # eyes above the target origin
## How far in front of the player's centre the eyes sit (metres, along the view direction on the ground plane). Needs to be a
## little more than the body's radius so the camera is outside the player mesh and you still see your own body.
@export var eye_forward := 0.6
## Hide the player's body in first person (off: the body stays visible, the camera just sits in front of it)
@export var hide_body_in_first_person := false
## While the player's eyes are inside a tree's canopy (its "Springarm" collider), that tree no longer pushes the camera in.
@export_flags_3d_physics var canopy_collision_mask := 8
var _canopy_excluded: Array[RID] = []
## The player's visual (path relative to the target). Hidden in first person.
@export var player_visual_path := NodePath("MeshInstance3D")
## Seconds the camera takes to glide between third person and the eyes.
@export var first_person_transition := 0.3
var _first_person := false
var _fp_blend := 0.0 # 0 = third person, 1 = fully first person
var _visual_hidden := false
var _tp_pos := Vector3.ZERO # smoothed third-person camera position (state for the lerp)
var _tp_pos_valid := false

# Browsers never send InputEventPanGesture/MagnifyGesture, so on web both the mouse wheel and a trackpad's
# two-finger swipe arrive as mouse-wheel button events carrying a 'factor'. Dragging orbits now, so on web:
# scroll up/down = zoom, scroll sideways = orbit, pinch (browser sends it as Ctrl+wheel) = zoom, +/- keys zoom.
# (Off = web uses the zoom_in / zoom_out actions like desktop: one fixed step per wheel event.)
@export var web_wheel_handling := true
@export var wheel_zoom_speed := 0.5  # metres per unit of wheel 'factor' -- tune on web
@export var wheel_rotate_sensitivity := 0.7  # degrees per unit of wheel 'factor' (sideways scroll) -- tune on web
@export var pinch_zoom_speed := 0.5
## Web, mouse/trackpad: the first click locks the pointer so moving the mouse alone turns the camera (like most web games)
@export var web_auto_pointer_lock := true
const POINTER_LOCK_PENDING_MSEC := 1000
var _pointer_lock_pending_until_msec := 0

# Shift lock (toggle with the shift_lock action, Ctrl by default): the mouse is captured and simply turns the camera,
# and the camera sits slightly over the player's shoulder. Clicks then act at the screen centre (crosshair),
# see Globals.aim_position(). Press Ctrl again to get the cursor back.
@export_group("Shift lock")
@export var shift_lock_sensitivity := 0.15 # degrees per pixel of mouse movement
@export var shift_lock_shoulder := 0.7 # metres the camera slides to the right while locked
@export var crosshair: Control
var shift_locked := false
@export_group("")

# Intro fly-in, played once the player confirms their name (Network calls play_intro()). IntroStart is a Marker3D in
# main.tscn: the camera opens there (above and behind the spawn, looking over the starting huts) and the
# IntroCamTransition AnimationPlayer animates intro_blend 0 -> 1, which glides the camera from that pose into the
# normal follow camera. Move/rotate IntroStart, or edit the animation's length/easing, to retune the shot.
@export_group("Intro")
@export var intro_enabled := true
@export var intro_start: Node3D
@export var intro_player: AnimationPlayer
@export var intro_animation := &"intro"
## 0 = camera sits on intro_start, 1 = normal gameplay camera. Driven by the intro animation, don't set it by hand.
@export_range(0.0, 1.0) var intro_blend := 1.0
## Seconds into the intro before a key press / click skips it (so the Enter that confirmed the name doesn't)
@export var intro_skip_delay := 0.75
## Seconds the quick zoom into the player takes when the intro is skipped
@export var intro_skip_duration := 0.6
@export_group("")
var intro_playing := false
var _intro_time := 0.0
var _intro_skipping := false
var _intro_tween: Tween

# Prevent hitting exact 0.0° and -90.0° singularities
@export_range(-89.9, 89.9) var max_tilt_limit := 44.9
@export_range(-179.9, 0.1) var min_tilt_limit := -89.9

# Mouse/Camera Euler angles
var camera_rotation: Vector3
# Store current interpolated rotation in script memory
var current_rotation: Vector3

var zoom_speed: float = 0.0
const ZOOM_MAX_SPEED := 40.0
const ZOOM_ACCEL := 40.0
const ZOOM_DECEL := 80.0

func _ready():
	camera_rotation = rotation_degrees
	current_rotation = rotation_degrees
	add_to_group("view")
	add_to_group("gameplay_input_blocker") # see is_open(): no orbit / zoom / clicks while the intro plays
	camera.make_current()
	if intro_player != null:
		intro_player.animation_finished.connect(_on_intro_finished)
	if intro_enabled and intro_start != null and intro_player != null and intro_player.has_animation(intro_animation):
		# Hold the opening shot behind the name dialog until play_intro() starts the fly-in
		intro_blend = 0.0
		camera.global_transform = intro_start.global_transform

func _physics_process(delta: float) -> void:
	if not target:
		return
		
	# Smoothly follow the target's location, leading it by its horizontal velocity so the rig doesn't
	# trail behind a running player (see lag_compensation)
	var goal := target.global_position
	var vel = target.get("velocity")
	if vel is Vector3:
		var lag := 1.0 / follow_speed + 1.0 / CAMERA_FOLLOW
		# Fade the lead out as the camera gets further from the player (uses the arm's actual length,
		# so it also applies when trees push the camera in)
		var closeness := 1.0 - smoothstep(lead_full_distance, lead_off_distance, spring_arm.spring_length)
		# Only the part of the velocity along the view direction: that is what changes the camera's
		# distance to the player (zoom in/out). Sideways motion is left alone, otherwise the view
		# would slide left/right of the player and feel confusing.
		var view_forward := -camera.global_basis.z
		view_forward.y = 0.0
		if view_forward.length_squared() > 0.0001:
			view_forward = view_forward.normalized()
			var forward_speed := Vector3(vel.x, 0.0, vel.z).dot(view_forward)
			goal += view_forward * forward_speed * lag * lag_compensation * closeness
	global_position = global_position.lerp(goal, follow_speed * delta)
	_update_canopy()

# Trees stop obstructing the camera while the player stands inside their canopy; first person inside leaves backs out
func _update_canopy() -> void:
	var params := PhysicsPointQueryParameters3D.new()
	params.position = target.global_position + Vector3.UP * eye_height
	params.collision_mask = canopy_collision_mask
	params.collide_with_bodies = true
	var inside: Array[RID] = []
	for hit in get_world_3d().direct_space_state.intersect_point(params, 8):
		var body := hit.get("collider") as Node
		if body != null and body.get_parent() is Gatherable:
			inside.append(hit["rid"])
	for rid in _canopy_excluded:
		if not inside.has(rid):
			spring_arm.remove_excluded_object(rid)
	var entered := false
	for rid in inside:
		if not _canopy_excluded.has(rid):
			spring_arm.add_excluded_object(rid)
			entered = true
	_canopy_excluded = inside
	if entered:
		_held_length = INF # forget the short length the canopy had forced on the arm
		_clear_time = 0.0

func _process(delta: float) -> void:
	if intro_playing:
		_intro_time += delta
	# A browser gives the mouse back on Esc without telling us: follow it
	_sync_shift_lock_state()
	camera.h_offset = lerpf(camera.h_offset, shift_lock_shoulder * (1.0 - smoothstep(0.0, 1.0, _fp_blend)) if shift_locked else 0.0, minf(delta * 10.0, 1.0)) # no over-the-shoulder slide in first person: it pushed the view off the body
	# Lerp pure script variables using lerp_angle (NEVER read rotation_degrees!)
	var lerp_weight = delta * 12.0
	
	current_rotation.x = rad_to_deg(lerp_angle(deg_to_rad(current_rotation.x), deg_to_rad(camera_rotation.x), lerp_weight))
	current_rotation.y = rad_to_deg(lerp_angle(deg_to_rad(current_rotation.y), deg_to_rad(camera_rotation.y), lerp_weight))
	
	# Apply memory vector to node transform
	rotation_degrees = current_rotation
	
	# Handle SpringArm and Camera Zooming
	_update_spring_length(delta)
	
	# Separate Camera smooth positioning relative to SpringArm Marker
	_update_first_person()
	_fp_blend = move_toward(_fp_blend, 1.0 if _first_person else 0.0, delta / maxf(first_person_transition, 0.01))
	camera.global_rotation = copy_target.global_rotation
	if not _tp_pos_valid:
		# During the intro the camera is sitting on the opening shot, so start the follow camera at its gameplay spot instead
		_tp_pos = copy_target.global_position if intro_playing else camera.global_position
		_tp_pos_valid = true
	_tp_pos = _tp_pos.lerp(copy_target.global_position, delta * CAMERA_FOLLOW)
	_tp_pos = _clear_of_player(_tp_pos)
	var cam_pos := _tp_pos
	if _fp_blend > 0.0 and target != null:
		# Glide between the third-person spot and the eyes instead of cutting. The eyes are a little in front of the body.
		var look := -camera.global_basis.z
		look.y = 0.0
		look = look.normalized() if look.length_squared() > 0.0001 else Vector3.ZERO
		var eyes := target.global_position + Vector3.UP * eye_height + look * eye_forward
		cam_pos = _tp_pos.lerp(eyes, smoothstep(0.0, 1.0, _fp_blend))
	camera.global_position = cam_pos
	_apply_intro_blend()
	_set_player_visual_hidden(hide_body_in_first_person and _fp_blend > 0.85)
	
	handle_input(delta)

func _update_spring_length(delta: float) -> void:
	# The arm only updates in physics, so its hit length belongs to the length applied LAST frame --
	# compare against that, not the new zoom, or zooming out always looks like an obstruction.
	var applied_last := spring_arm.spring_length
	var hit := spring_arm.get_hit_length()
	if zoom > _last_zoom + 0.001:
		# Zooming out on purpose cancels the hold
		_held_length = INF
		_clear_time = 0.0
	elif hit < applied_last - 0.05:
		# Something is in the way: pull in to it and stay there
		_held_length = hit
		_clear_time = 0.0
	else:
		_clear_time += delta
		if _held_length < zoom and _clear_time > zoom_recover_delay:
			_held_length += zoom_recover_speed * delta
			if _held_length >= zoom:
				_held_length = INF
	_last_zoom = zoom
	spring_arm.spring_length = minf(zoom, _held_length)

# Switch between third and first person based on the arm's current length (with hysteresis)
func _update_first_person() -> void:
	var dist := spring_arm.spring_length
	var want := _first_person
	if not _first_person and dist < first_person_distance:
		want = true
	elif _first_person and dist > first_person_distance + first_person_hysteresis:
		want = false
	if want != _first_person:
		_first_person = want

func _set_player_visual_hidden(hidden: bool) -> void:
	if target == null or hidden == _visual_hidden:
		return
	_visual_hidden = hidden
	var node := target.get_node_or_null(player_visual_path)
	if node is GeometryInstance3D:
		# Keep the shadow so the player still casts one while you look out of their eyes
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if hidden else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	elif node is Node3D:
		node.visible = not hidden

func _exit_tree() -> void:
	if _visual_hidden:
		_set_player_visual_hidden(false)

# Push a camera position out along the player->camera line if it is closer than min_camera_distance
func _clear_of_player(pos: Vector3) -> Vector3:
	if target == null or min_camera_distance <= 0.0:
		return pos
	var head := target.global_position + Vector3.UP * head_height
	var offset := pos - head
	if offset.length() >= min_camera_distance:
		return pos
	# Degenerate (camera on the head): use where the arm wants the camera to be
	var dir := offset.normalized() if offset.length() > 0.01 else (copy_target.global_position - head).normalized()
	if dir == Vector3.ZERO:
		dir = global_basis.z
	return head + dir * min_camera_distance

# --- Intro fly-in ---

# Member of the "gameplay_input_blocker" group (see Globals.is_gameplay_input_blocked)
func is_open() -> bool:
	return intro_playing

func play_intro() -> void:
	if not intro_enabled or intro_start == null or intro_player == null or not intro_player.has_animation(intro_animation):
		intro_blend = 1.0
		return
	intro_playing = true
	_intro_time = 0.0
	_intro_skipping = false
	_tp_pos_valid = false # restart the smoothed camera at its gameplay spot; the blend hides it
	intro_blend = 0.0
	cancel_gameplay_input()
	intro_player.play(intro_animation)

func skip_intro() -> void:
	if not intro_playing or _intro_skipping:
		return
	# Don't cut to the end: freeze the animation where it is and swoop the rest of the way to the player, fast
	_intro_skipping = true
	intro_player.pause()
	_intro_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_intro_tween.tween_property(self, "intro_blend", 1.0, intro_skip_duration)
	_intro_tween.finished.connect(_end_intro)

func _on_intro_finished(anim_name: StringName) -> void:
	if anim_name == intro_animation:
		_end_intro()

func _end_intro() -> void:
	if not intro_playing:
		return
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	_intro_tween = null
	_intro_skipping = false
	intro_playing = false
	intro_blend = 1.0
	cancel_gameplay_input()

# Slide the already-computed gameplay camera back towards the opening shot: position lerp + rotation slerp
func _apply_intro_blend() -> void:
	if intro_blend >= 1.0 or intro_start == null:
		return
	var from := intro_start.global_transform
	var to := camera.global_transform
	camera.global_position = from.origin.lerp(to.origin, intro_blend)
	camera.global_basis = Basis(from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), intro_blend))

func handle_input(_delta: float):
	if Globals.is_gameplay_input_blocked():
		zoom_speed = 0.0
		_drag_state = DragState.NONE
		return

	# CAMERA ZOOMING (Mouse Wheel)
	if not _web_wheel():
		if Input.is_action_just_pressed("zoom_in"):
			zoom = max(min_zoom, zoom - scroll_zoom_speed)
		if Input.is_action_just_pressed("zoom_out"):
			zoom = min(max_zoom, zoom + scroll_zoom_speed)
	
	# Continuous zoom (Keyboard +/-)
	var zoom_axis = Input.get_axis("zoom_in_hold", "zoom_out_hold")
	if zoom_axis != 0:
		zoom_speed = move_toward(zoom_speed, zoom_axis * ZOOM_MAX_SPEED, ZOOM_ACCEL * _delta)
	else:
		zoom_speed = move_toward(zoom_speed, 0.0, ZOOM_DECEL * _delta)
	
	zoom = clamp(zoom + _delta * zoom_speed, min_zoom, max_zoom)

	# Arrow-key orbit. Left arrow turns the view left / Up arrow tilts up, matching
	# what dragging the mouse left/up does in _input().
	var yaw_axis := Input.get_axis("camera_right", "camera_left")
	var pitch_axis := Input.get_axis("camera_back", "camera_forward")
	if yaw_axis != 0.0 or pitch_axis != 0.0:
		camera_rotation.y += yaw_axis * key_rotate_speed * _delta
		camera_rotation.x += pitch_axis * key_rotate_speed * _delta
		_clamp_pitch()

func _web_wheel() -> bool:
	return web_wheel_handling and OS.has_feature("web")

func _clamp_pitch() -> void:
	if view_angle_restricted:
		camera_rotation.x = clamp(camera_rotation.x, min_tilt_limit, max_tilt_limit)

# Click-and-drag orbit. Runs on UNHANDLED input so UI clicks never start a drag. Whether a left press is
# really a gather/build click is only known once the player has seen it, so the decision is deferred to the
# first mouse motion (the press has been fully dispatched by then, whatever the node order).
func set_shift_lock(on: bool) -> void:
	shift_locked = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	_pointer_lock_pending_until_msec = 0
	if on and OS.has_feature("web"):
		_pointer_lock_pending_until_msec = Time.get_ticks_msec() + POINTER_LOCK_PENDING_MSEC
	if crosshair != null:
		crosshair.visible = on
	_drag_state = DragState.NONE

func _sync_shift_lock_state() -> void:
	if not shift_locked:
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pointer_lock_pending_until_msec = 0
		return
	if Time.get_ticks_msec() >= _pointer_lock_pending_until_msec:
		set_shift_lock(false)

func cancel_gameplay_input() -> void:
	zoom_speed = 0.0
	_drag_state = DragState.NONE

func _unhandled_input(event: InputEvent) -> void:
	if Globals.is_gameplay_input_blocked():
		return
	_sync_shift_lock_state()
	# Ctrl toggles the pointer lock
	if event.is_action_pressed("shift_lock") and not event.is_echo():
		set_shift_lock(not shift_locked)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed:
		# Web with a mouse/trackpad: the first click on the game locks the pointer, so just moving the mouse looks around.
		# A finger on a touchscreen arrives as an emulated mouse and keeps plain one-finger drag-to-orbit.
		if web_auto_pointer_lock and OS.has_feature("web") and not shift_locked \
				and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
			set_shift_lock(true)
		match event.button_index:
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_drag_state = DragState.ROTATING
			MOUSE_BUTTON_LEFT:
				_drag_state = DragState.PENDING
	elif event is InputEventMouseMotion and _drag_state != DragState.NONE and not shift_locked:
		if _drag_state == DragState.PENDING:
			_drag_state = DragState.ROTATING if _left_drag_allowed() else DragState.BLOCKED
		if _drag_state == DragState.ROTATING:
			camera_rotation.y -= event.relative.x * drag_sensitivity
			camera_rotation.x -= event.relative.y * drag_sensitivity
			_clamp_pitch()

func _left_drag_allowed() -> bool:
	var player = Globals.player
	if player != null and player.has_method("is_working") and player.is_working():
		return false # holding on a tree / construction site
	var builder = Globals.builder
	if builder != null and builder.build_mode:
		return false # build mode: left click places things
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	if selector != null and selector.selected_citizen != null:
		return false # left click orders the selected citizen
	return true

func _input(event):
	if intro_playing:
		# Any key / click speeds the fly-in up into the player (Esc is left alone for the pause menu)
		if _intro_time > intro_skip_delay \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode != KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed)):
			skip_intro()
			get_viewport().set_input_as_handled()
		return
	if Globals.is_gameplay_input_blocked():
		return
	# Shift lock: moving the mouse turns the camera (the cursor is captured)
	if shift_locked and event is InputEventMouseMotion:
		camera_rotation.y -= event.relative.x * shift_lock_sensitivity
		camera_rotation.x -= event.relative.y * shift_lock_sensitivity
		_clamp_pitch()

	# Any drag ends when its button is released (even over UI)
	if event is InputEventMouseButton and not event.pressed \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		_drag_state = DragState.NONE
	
	# Trackpad gesture support
	if event is InputEventPanGesture:
		camera_rotation.y -= event.delta.x * mouse_sensitivity
		camera_rotation.x -= event.delta.y * mouse_sensitivity
	
	# Web: mouse wheel / trackpad swipe = wheel events. Up/down zooms, sideways orbits, Ctrl+wheel = pinch.
	elif event is InputEventMouseButton and event.pressed and _web_wheel() \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var amount: float = clampf(event.factor, 0.0, 10.0)
		var zoom_step := amount * (pinch_zoom_speed if (event.ctrl_pressed or event.meta_pressed) else wheel_zoom_speed)
		var orbit_step := amount * wheel_rotate_sensitivity
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: zoom = clamp(zoom - zoom_step, min_zoom, max_zoom)
			MOUSE_BUTTON_WHEEL_DOWN: zoom = clamp(zoom + zoom_step, min_zoom, max_zoom)
			MOUSE_BUTTON_WHEEL_LEFT: camera_rotation.y -= orbit_step
			MOUSE_BUTTON_WHEEL_RIGHT: camera_rotation.y += orbit_step
		get_viewport().set_input_as_handled()

	elif event is InputEventMagnifyGesture:
		zoom = clamp(zoom / event.factor, min_zoom, max_zoom)
	
	# Clamp Pitch (Up/Down angle)
	if view_angle_restricted:
		camera_rotation.x = clamp(camera_rotation.x, min_tilt_limit, max_tilt_limit)
