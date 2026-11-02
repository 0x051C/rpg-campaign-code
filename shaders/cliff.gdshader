shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Cliff pieces of imported HoN maps: their tops lie flush with the high ground, where HoN's cliff
// shader paints the terrain's texture. Here the upward faces are left out, so the terrain itself
// shows there; the sides keep the cliff's own texture.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float top_cutoff : hint_range(0.0, 1.0) = 0.8;  // faces whose normal points up more than this

void fragment() {
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	if (world_normal.y > top_cutoff) {
		discard;
	}
	vec4 color = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = color.rgb;
	ROUGHNESS = roughness;
}
