shader_type canvas_item;

// Low-energy "exhaustion" effect: the screen drains of colour, gets darker and blurrier toward the
// edges (tunnel vision), so it is genuinely harder to see what is going on.
// Put it on a full-screen ColorRect (mouse_filter = Ignore) and drive `intensity` (0..1) from script.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// How much of the original colour is left at full intensity (0 = fully grey)
uniform float min_saturation : hint_range(0.0, 1.0) = 0.1;
// Overall dimming, plus extra dimming toward the screen edges
uniform float darkness : hint_range(0.0, 1.0) = 0.3;
uniform float tunnel : hint_range(0.0, 1.0) = 0.55;
// Blur strength (mip level) at the edges at full intensity. The centre only gets a third of it.
uniform float max_blur : hint_range(0.0, 6.0) = 3.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	float d = distance(uv, vec2(0.5)) * 1.4142; // 0 in the centre, ~1 in the corners
	float edge = smoothstep(0.15, 1.0, d);

	float lod = intensity * max_blur * (0.33 + 0.67 * edge);
	vec3 c = textureLod(screen_tex, uv, lod).rgb;

	float grey = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(grey), intensity * (1.0 - min_saturation));
	c *= 1.0 - intensity * (darkness + tunnel * edge);

	COLOR = vec4(c, 1.0);
}
