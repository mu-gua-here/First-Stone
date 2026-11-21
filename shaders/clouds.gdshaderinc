// Shared by cloud_layer.gdshader (the clouds you see) and water_surface.gdshader (the same clouds mirrored in the sea).
// Both materials get the same uniform values from DayNightCycle every frame, so the reflection always matches the sky.
// The clouds live on one imaginary flat layer `cloud_height` metres up; a point on it is found from its world XZ.

uniform float cloud_height = 320.0;
uniform vec2 cloud_offset = vec2(0.0); // wind drift in metres, accumulated on the CPU (no TIME here: it wraps every hour)
uniform float cloud_scale = 0.0016; // noise frequency per metre
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_softness : hint_range(0.01, 0.5) = 0.18;
uniform vec3 cloud_color : source_color = vec3(1.0);
uniform vec3 cloud_shade_color : source_color = vec3(0.62, 0.68, 0.78);
uniform vec2 cloud_sun_dir = vec2(0.6, 0.8); // horizontal direction toward the sun / moon (normalised)
uniform float cloud_fade_start = 1200.0; // horizontal distance from the camera where clouds start to dissolve at the horizon
uniform float cloud_fade_end = 3000.0;

float cl_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float cl_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(cl_hash(i), cl_hash(i + vec2(1.0, 0.0)), u.x),
			mix(cl_hash(i + vec2(0.0, 1.0)), cl_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float cl_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * cl_noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

// 0..1: how much cloud there is above the world position xz
float cloud_density(vec2 xz) {
	float n = cl_fbm((xz + cloud_offset) * cloud_scale);
	return smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + cloud_softness, n);
}

// Cheap lighting: look a little toward the sun; if there is more cloud that way this spot is in its shade.
vec3 cloud_shaded(vec2 xz, float density) {
	float toward_sun = cloud_density(xz + cloud_sun_dir * 90.0);
	return mix(cloud_color, cloud_shade_color, clamp(toward_sun - density * 0.5, 0.0, 1.0));
}

float cloud_distance_fade(vec2 xz, vec2 camera_xz) {
	return 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, length(xz - camera_xz));
}
