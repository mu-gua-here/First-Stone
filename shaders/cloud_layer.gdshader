shader_type spatial;
// The visible cloud layer (Ultra graphics): one big flat plane that follows the camera (DayNightCycle moves it), with the
// clouds drawn by noise in world space, so they stay put while the plane moves. The sea mirrors the same clouds in
// water_surface.gdshader via the shared include.
// Drawn before the other transparent things (render_priority on the material) so the ocean always covers it.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

#include "res://shaders/clouds.gdshaderinc"

uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.95;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = v_world.xz;
	float density = cloud_density(xz);
	ALBEDO = cloud_shaded(xz, density);
	ALPHA = density * cloud_distance_fade(xz, CAMERA_POSITION_WORLD.xz) * cloud_opacity;
}
