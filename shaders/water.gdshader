shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Water and tar surfaces (WaterSurface): see-through, fading out where the ground under them comes
// near the surface, so the shore follows the terrain instead of the surface's own edges.

uniform vec4 color : source_color = vec4(0.18, 0.38, 0.42, 0.55);
uniform float fade_meters = 0.6;  // depth over which the shore fades in
uniform float roughness : hint_range(0.0, 1.0) = 0.06;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float below = VERTEX.z - behind.z / behind.w;  // meters of view depth between the surface and the ground
	ALBEDO = color.rgb;
	ALPHA = color.a * smoothstep(0.0, fade_meters, below);
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
