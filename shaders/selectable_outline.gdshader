shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_mix;

// Yellow highlight for objects the player can pick as an assignment target (trees, logs).
// Used as a material_overlay by CitizenSelector. A fresnel rim (bright where the surface turns away
// from the camera) plus a faint fill, so it reads as an outline on any mesh -- low-poly flat normals,
// scaled glb instances, thin logs -- without needing extra geometry.

uniform vec4 outline_color : source_color = vec4(1.0, 0.85, 0.1, 1.0);
uniform float rim_power : hint_range(0.5, 6.0) = 1.6;
uniform float fill_strength : hint_range(0.0, 1.0) = 0.22;

void fragment() {
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);
	ALBEDO = outline_color.rgb;
	ALPHA = clamp(fill_strength + rim, 0.0, 1.0);
}
