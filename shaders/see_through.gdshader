shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// The material SeeThrough gives occluders (props, buildings): the common StandardMaterial3D
// channels, plus holes around the units behind them (see_through.gdshaderinc).

#include "res://shaders/see_through.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_vertex_color = false;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D roughness_texture : hint_roughness_g, filter_linear_mipmap, repeat_enable;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D metallic_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_texture = false;
uniform float normal_scale = 1.0;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
uniform float hole_softness : hint_range(0.05, 1.0) = 0.45;  // share of the radius that fades
instance uniform float hole_scale = 1.0;  // MapProp.see_through_scale

void vertex() {
	UV = UV * uv_scale.xy + uv_offset.xy;
}

void fragment() {
	float keep = see_through_keep(VERTEX, VIEW_MATRIX, CAMERA_POSITION_WORLD, hole_softness, hole_scale);
	if (keep < 1.0 && keep < see_through_dither(FRAGCOORD.xy)) {
		discard;
	}
	vec4 base = albedo_color * texture(albedo_texture, UV);
	if (use_vertex_color) {
		base *= COLOR;
	}
	ALBEDO = base.rgb;
	ROUGHNESS = roughness * texture(roughness_texture, UV).g;
	METALLIC = metallic * texture(metallic_texture, UV).b;
	if (use_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	EMISSION = emission.rgb * emission_energy;
}
