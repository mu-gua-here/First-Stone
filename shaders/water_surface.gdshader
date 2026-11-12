shader_type spatial;
// Pairs with scripts/water_surface.gd. Waves are PLAIN SINES evaluated from a single set of
// parameters that WaterSurface pushes in and also uses for height_at() on the CPU, so the
// rendered surface and the physics surface are the same function.
//
// Why this matches between vertices: the mesh is a world-aligned lattice (vertices sit on
// multiples of cell_size), the wave is only ever evaluated AT vertices, and the rasteriser
// interpolates linearly inside each triangle. height_at() does the same barycentric blend with
// the same triangulation, so there is no floor()/stepping anywhere -- the low-poly look comes
// from coarse cells + flat normals only.
// depth_prepass_alpha: the ocean is one transparent mesh with no draw sorting, so at grazing angles a far wave tile can be
// drawn before a nearer one and blend underneath it, doubling its opacity (the pale squares in the distance). The prepass
// lays the nearest surface's depth first so every pixel blends exactly once. If the whole ocean ever turns foam-white after
// this, remove it: it would mean the prepass is leaking into depth_texture.
render_mode blend_mix, depth_draw_always, depth_prepass_alpha, diffuse_lambert, specular_schlick_ggx, cull_disabled, fog_disabled;

// Environment fog is applied by the engine as a colour tint only: it never raises ALPHA, so a half-transparent ocean stays
// half see-through however thick the fog is (that's why it looked unfogged). fog_disabled turns the engine fog off for this
// shader and the same depth fog is done below in fragment(), fading the alpha too. DayNightCycle writes these uniforms from the
// active Environment every frame, so native and compat each get their own fog.
group_uniforms Env_Fog;
uniform vec3 env_fog_color : source_color = vec3(0.86, 0.87, 0.9);
uniform float env_fog_begin = 20.0;
uniform float env_fog_end = 200.0;
uniform float env_fog_curve = 0.5;
uniform float env_fog_density = 0.0; // 0 = off until DayNightCycle sets it

group_uniforms Water_Colors;
uniform vec3 deep_water_color : source_color = vec3(0.0, 0.6, 0.9);
uniform vec3 shallow_water_color : source_color = vec3(0.0, 0.6, 0.7);
uniform vec3 foam_color : source_color = vec3(0.9, 0.95, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float water_alpha : hint_range(0.0, 1.0) = 0.3;
uniform float underwater_alpha : hint_range(0.0, 1.0) = 0.8; // surface opacity when viewed from below

// Set by WaterSurface -- do not edit by hand.
// wave_a[i] = (direction.x, direction.y, wavenumber k, amplitude); wave_phase[i] = radians,
// already wrapped on the CPU in double precision (so there is no TIME in this shader at all).
group_uniforms Waves_Driven_By_Script;
uniform vec4 wave_a[4];
uniform vec4 wave_phase;

group_uniforms Depth_Settings;
uniform float foam_distance : hint_range(0.001, 1.0, 0.001) = 0.05;
uniform float foam_stepping : hint_range(2.0, 100.0) = 100.0;
uniform float depth_distance : hint_range(0.1, 10.0) = 4.0;

// The grid follows the camera, so its far edge must dissolve into the sky colour.
// Radii are measured from the camera in XZ; WaterSurface sets them from the grid size.
group_uniforms Horizon_Fade;
uniform vec3 edge_fog_color : source_color = vec3(0.65, 0.78, 0.92);
uniform float fade_start = 100.0;
uniform float fade_end = 150.0;
uniform float edge_fog_max_strength : hint_range(0.0, 1.0) = 1.0;

// Set by WaterSurface (its cell_size, which should equal the GridMap cell size so ocean quads = tiles).
group_uniforms Quads;
uniform float quad_size = 4.0;
// 0 = every tile is one hard flat facet; 1 = fully smooth (normals point straight up). The low-poly
// look wants a little of this so adjacent tiles blend softly instead of reading as sharp shards.
uniform float facet_softness : hint_range(0.0, 1.0) = 0.35;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3 v_world_pos;
varying vec3 v_normal; // world-space flat QUAD normal, identical on all 6 vertices of a tile

float wave_height(vec2 p) {
	float h = 0.0;
	for (int i = 0; i < 4; i++) {
		h += wave_a[i].w * sin(wave_a[i].z * dot(wave_a[i].xy, p) + wave_phase[i]);
	}
	return h;
}

void vertex() {
	// The WaterSurface mesh node is translation-only (top_level, no rotation/scale), so
	// MODEL_MATRIX only shifts the lattice and world XZ here is exactly what the CPU uses.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = wave_height(world_pos.xz);
	VERTEX.y += h;
	v_world_pos = world_pos + vec3(0.0, h, 0.0);

	// One flat normal PER QUAD (grid tile), computed ANALYTICALLY. The mesh is un-indexed and every
	// vertex carries UV = the XZ offset from itself to its tile's (col,row) corner `a`, so all six
	// vertices of a tile evaluate the same four corner heights and output the same normal (still no
	// dFdx/dFdy, which lit triangle-edge pixels white at high amplitude). The normal is the cross of
	// the tile's two diagonals -- the best-fit plane of the four corners -- so the two triangles that
	// make the tile shade as a single quad.
	vec2 a = world_pos.xz + UV;
	float ha = wave_height(a);
	float hb = wave_height(a + vec2(quad_size, 0.0));
	float hc = wave_height(a + vec2(0.0, quad_size));
	float hd = wave_height(a + vec2(quad_size, quad_size));
	vec3 diag_ad = vec3(quad_size, hd - ha, quad_size);
	vec3 diag_bc = vec3(-quad_size, hc - hb, quad_size);
	vec3 n = normalize(cross(diag_bc, diag_ad));
	if (n.y < 0.0) {
		n = -n; // the surface is a heightfield: the face normal always points up
	}
	v_normal = normalize(mix(n, vec3(0.0, 1.0, 0.0), facet_softness));
}

void fragment() {
	// Flat face normal from the vertex stage (world space -> view space). Same for both faces:
	// seen from below it is deliberately the upward surface normal, so the underside is lit
	// like the top.
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(v_normal), 0.0)).xyz);

	// Depth -> shallow/deep blend and foam. NDC depth range differs per backend.
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	float water_depth = depth_distance;
	if (depth > 0.0 && depth < 1.0) {
		vec4 upos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		vec3 pixel_position = upos.xyz / upos.w;
		water_depth = abs(pixel_position.z - VERTEX.z);
	}
	// NaN/inf guard. !(x < y) is true for NaN, which a plain comparison would miss.
	if (!((water_depth < 1e4) || isnan(water_depth) || isinf(water_depth))) {
		water_depth = depth_distance;
	}

	float depth_blend = clamp(water_depth / depth_distance, 0.0, 1.0);
	vec3 water_base = mix(shallow_water_color, deep_water_color, depth_blend);
	float dynamic_alpha = mix(water_alpha, water_alpha, depth_blend);

	// Seen from below: keep it mostly clear so the sky / world above stays visible. (The normal
	// is already the upward one, so it is lit like the top -- no flip needed.)
	bool underside = !FRONT_FACING;
	if (underside) {
		dynamic_alpha = water_alpha * underwater_alpha;
	}

	// Stepped foam at intersections (depth-based aesthetic, unrelated to wave motion)
	float stepped_depth = floor(water_depth * foam_stepping) / foam_stepping;
	float foam_mask = underside ? 0.0 : step(stepped_depth, foam_distance);
	vec3 result = mix(water_base, foam_color, foam_mask);
	float alpha = mix(dynamic_alpha, 1.0, foam_mask);

	// Horizon fade, radial from the camera
	float dist = length(v_world_pos.xz - CAMERA_POSITION_WORLD.xz);
	float fade = smoothstep(fade_start, fade_end, dist) * edge_fog_max_strength;
	result = mix(result, edge_fog_color, fade);
	alpha = mix(alpha, 1.0, fade);

	// Depth fog like the Environment's (smoothstep between begin/end, shaped by the curve, capped by density), but it also
	// pushes alpha up so the far ocean actually dissolves into the fog. Not applied from below (the underwater tint owns that).
	if (!underside) {
		float fog_t = smoothstep(env_fog_begin, max(env_fog_end, env_fog_begin + 0.01), length(VERTEX));
		float fog_amount = pow(fog_t, env_fog_curve) * env_fog_density;
		result = mix(result, env_fog_color, fog_amount);
		alpha = mix(alpha, 1.0, fog_amount);
	}

	ALBEDO = result;
	ALPHA = alpha;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
}
