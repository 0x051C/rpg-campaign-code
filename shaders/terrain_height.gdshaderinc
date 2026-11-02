// The active Terrain's heights, for materials that hug the ground (selection rings, targeting
// indicators, decals, scatter). Set by Terrain; terrain_grid.w is 0 when the map has none.

global uniform sampler2D terrain_heightmap : filter_linear, repeat_disable;
global uniform vec4 terrain_grid;  // xy: world XZ of vertex (0, 0); z: vertices per meter; w: 1 with a terrain

float terrain_height(vec2 world_xz) {
	if (terrain_grid.w < 0.5) {
		return 0.0;
	}
	vec2 texels = vec2(textureSize(terrain_heightmap, 0));
	vec2 uv = ((world_xz - terrain_grid.xy) * terrain_grid.z + 0.5) / texels;
	return texture(terrain_heightmap, uv).r;
}
