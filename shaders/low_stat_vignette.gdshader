shader_type canvas_item;
// Red edge-of-screen warning for the player HUD (scripts/player_hud.gd). Drawn on a full-screen
// ColorRect: transparent in the middle, fading up to `vignette_color` at the screen edges.
// `intensity` is driven by the script (0 = invisible).

uniform vec4 vignette_color : source_color = vec4(0.85, 0.02, 0.02, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// Where the gradient starts, as a fraction of the way from the screen centre to the edge.
uniform float inner_radius : hint_range(0.0, 0.99) = 0.4;
// Slow heartbeat so the warning is noticeable without being a hard strobe.
uniform float pulse_speed = 3.0;
uniform float pulse_amount : hint_range(0.0, 0.5) = 0.15;

void fragment() {
	vec2 d = abs(UV - vec2(0.5)) * 2.0; // 0 at the centre, 1 on the edge midpoints
	// Mostly a rectangular falloff (so the sides and the top/bottom all glow), with a touch of
	// radial so the corners are strongest.
	float edge = mix(max(d.x, d.y), length(d) * 0.7071, 0.35);
	float a = smoothstep(inner_radius, 1.0, edge);
	float pulse = 1.0 - pulse_amount * 0.5 * (1.0 + sin(TIME * pulse_speed));
	COLOR = vec4(vignette_color.rgb, a * a * intensity * pulse * vignette_color.a);
}
