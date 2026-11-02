shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Terrain: a flat grid displaced by per-vertex heights, painted with per-vertex tile ids.
// Each pixel blends the tiles of its cell's four corners, weighted by distance and by the
// tiles' height textures, so the taller texels (stones, tufts) win at the borders.

uniform sampler2D heightmap : filter_nearest, repeat_disable;  // meters per vertex (RF)
uniform sampler2D tilemap : filter_nearest, repeat_disable;  // tile id / 255 per vertex (R8)
uniform sampler2DArray albedo_array : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray height_array : filter_linear_mipmap, repeat_enable;
uniform float tile_meters[16];
uniform float cell_size = 1.0;
uniform float blend_depth : hint_range(0.01, 1.0) = 0.2;  // how far below the top texel others still show
uniform float height_influence : hint_range(0.0, 2.0) = 0.6;  // texture height vs. distance to the corner
uniform float roughness : hint_range(0.0, 1.0) = 0.92;
uniform sampler2D edge_noise : filter_linear_mipmap, repeat_enable;  // seamless, breaks up grid-straight borders
uniform float edge_noise_meters = 5.0;
uniform float edge_warp : hint_range(0.0, 1.0) = 0.8;  // in cells
uniform sampler2D tintmap : source_color, filter_linear, repeat_disable;  // color per vertex (RGB8), or 1x1 white

varying vec2 v_local;  // terrain-local XZ, meters: texture coordinates
varying vec2 v_cell;  // position in vertex-grid units

float vertex_height(ivec2 at, ivec2 last) {
	return texelFetch(heightmap, clamp(at, ivec2(0), last), 0).r;
}

void vertex() {
	ivec2 last = textureSize(heightmap, 0) - 1;
	ivec2 at = ivec2(round(UV * vec2(last)));
	VERTEX.y = vertex_height(at, last);
	float left = vertex_height(at - ivec2(1, 0), last);
	float right = vertex_height(at + ivec2(1, 0), last);
	float north = vertex_height(at - ivec2(0, 1), last);
	float south = vertex_height(at + ivec2(0, 1), last);
	NORMAL = normalize(vec3(left - right, 2.0 * cell_size, north - south));
	TANGENT = normalize(vec3(2.0 * cell_size, right - left, 0.0));
	BINORMAL = normalize(cross(TANGENT, NORMAL));
	v_local = VERTEX.xz;
	v_cell = UV * vec2(last);
}

int tile_at(ivec2 at) {
	return int(texelFetch(tilemap, at, 0).r * 255.0 + 0.5);
}

void fragment() {
	ivec2 last = textureSize(tilemap, 0) - 1;
	vec2 cell = clamp(v_cell, vec2(0.0), vec2(last) - 0.001);
	ivec2 base = ivec2(floor(cell));
	vec2 f = cell - vec2(base);
	vec2 dx = dFdx(v_local);
	vec2 dy = dFdy(v_local);
	// Warp the corner weights inside the cell (not at its edges, so neighbours still match)
	vec2 noise_uv = v_local / edge_noise_meters;
	vec2 warp = vec2(textureGrad(edge_noise, noise_uv, dx / edge_noise_meters, dy / edge_noise_meters).r,
			textureGrad(edge_noise, noise_uv + vec2(0.37, 0.61), dx / edge_noise_meters, dy / edge_noise_meters).r) - 0.5;
	f = clamp(f + warp * edge_warp * 4.0 * f * (1.0 - f), 0.0, 1.0);

	int tile[4] = int[](tile_at(base), tile_at(base + ivec2(1, 0)), tile_at(base + ivec2(0, 1)), tile_at(base + ivec2(1, 1)));
	float weight[4] = float[]((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
	// Corners painted with the same tile count once, with their weights summed
	for (int k = 1; k < 4; k++) {
		for (int j = 0; j < k; j++) {
			if (tile[k] == tile[j] && weight[k] > 0.0) {
				weight[j] += weight[k];
				weight[k] = 0.0;
			}
		}
	}

	// The samples below sit behind branches, so they use the gradients taken above
	float score[4];
	float top = -1e9;
	for (int k = 0; k < 4; k++) {
		score[k] = -1e9;
		if (weight[k] > 0.0) {
			float meters = tile_meters[tile[k]];
			float h = textureGrad(height_array, vec3(v_local / meters, float(tile[k])), dx / meters, dy / meters).r;
			score[k] = h * height_influence + weight[k];
			top = max(top, score[k]);
		}
	}
	vec3 color = vec3(0.0);
	float total = 0.0;
	for (int k = 0; k < 4; k++) {
		float b = max(score[k] - top + blend_depth, 0.0);
		if (b > 0.0) {
			float meters = tile_meters[tile[k]];
			color += textureGrad(albedo_array, vec3(v_local / meters, float(tile[k])), dx / meters, dy / meters).rgb * b;
			total += b;
		}
	}
	vec2 tint_size = vec2(textureSize(tintmap, 0));
	vec3 tint = tint_size.x > 1.0 ? texture(tintmap, (v_cell + 0.5) / tint_size).rgb : vec3(1.0);
	ALBEDO = color / max(total, 1e-4) * tint;
	ROUGHNESS = roughness;
}
