// See-through holes: occluders get a round, soft-edged opening wherever they stand between
// the camera and a tracked unit (SeeThrough writes these every frame). The opening is
// dithered, so occluders stay opaque: no sorting problems, shadows unchanged.

global uniform sampler2D see_through_units : filter_nearest, repeat_disable;  // xyz: unit center (world), w: hole radius (m)
global uniform int see_through_count;
global uniform vec3 see_through_camera;  // the game camera; other passes (shadows) get no holes

// 1 keeps the pixel, 0 removes it. `view_vertex` is the fragment in view space (VERTEX).
// `scale` widens every hole on this occluder (e.g. roofs over interiors).
float see_through_keep(vec3 view_vertex, mat4 view_matrix, vec3 camera_world, float softness, float scale) {
	if (see_through_count <= 0 || distance(camera_world, see_through_camera) > 0.05) {
		return 1.0;
	}
	float keep = 1.0;
	for (int i = 0; i < see_through_count; i++) {
		vec4 unit = texelFetch(see_through_units, ivec2(i, 0), 0);
		vec3 center = (view_matrix * vec4(unit.xyz, 1.0)).xyz;
		// Only what is nearer to the camera than the unit (minus half its radius) opens up
		if (view_vertex.z < center.z + unit.w * 0.5 || center.z >= 0.0) {
			continue;
		}
		// Where the pixel's view ray crosses the unit's depth, and how far that is from it
		vec2 across = view_vertex.xy * (center.z / view_vertex.z) - center.xy;
		float radius = unit.w * scale;
		float open = 1.0 - smoothstep(radius * (1.0 - softness), radius, length(across));
		keep = min(keep, 1.0 - open);
	}
	return keep;
}

// Ordered 4x4 dither threshold for screen-door transparency.
float see_through_dither(vec2 frag_coord) {
	const float bayer[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 p = ivec2(frag_coord) % 4;
	return (bayer[p.y * 4 + p.x] + 0.5) / 16.0;
}
