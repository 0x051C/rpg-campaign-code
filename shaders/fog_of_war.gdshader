shader_type spatial;
render_mode unshaded, blend_mul, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

// FogOfWar's full-screen pass (noh vid_gl2/c_fogofwar.cpp). Finds the world point behind
// every pixel from the depth buffer and multiplies the pixel by how much the player's team
// sees there: fully lit where it sees, `shade` in the fog. The visibility texture of the
// previous update fades into the latest one, like noh's two dynamic textures.

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D fog_previous : filter_linear, repeat_disable;
uniform sampler2D fog_current : filter_linear, repeat_disable;
uniform float fog_blend = 1.0;  // 0 shows the previous update, 1 the latest
uniform vec4 fog_rect;  // world XZ origin and size the textures cover
uniform vec4 map_rect;  // the map; everything outside it is fog
uniform float shade = 0.22;  // linear brightness in the fog

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Four bilinear taps around the point: a soft edge a couple of cells wide, like noh's
// blurred fog render target.
float sight(sampler2D fog, vec2 uv, vec2 texel) {
	return 0.25 * (texture(fog, uv + texel * vec2(-0.75, -0.75)).r
			+ texture(fog, uv + texel * vec2(0.75, -0.75)).r
			+ texture(fog, uv + texel * vec2(-0.75, 0.75)).r
			+ texture(fog, uv + texel * vec2(0.75, 0.75)).r);
}

void fragment() {
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	view.xyz /= view.w;
	vec2 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xz;

	vec2 uv = (world - fog_rect.xy) / fog_rect.zw;
	vec2 texel = 1.0 / vec2(textureSize(fog_current, 0));
	float seen = mix(sight(fog_previous, uv, texel), sight(fog_current, uv, texel), fog_blend);
	vec2 inside = step(map_rect.xy, world) * step(world, map_rect.xy + map_rect.zw);
	seen *= inside.x * inside.y;
	ALBEDO = vec3(mix(shade, 1.0, seen));
}
