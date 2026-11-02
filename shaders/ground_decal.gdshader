shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords;

// Flat markings on the ground (selection rings, order markers). Place them on the gameplay
// plane; every vertex is raised by the terrain height under it, so a ring on a slope follows
// the slope instead of cutting into it.

#include "res://shaders/terrain_height.gdshaderinc"

uniform vec4 color : source_color = vec4(1.0);
uniform bool use_instance_color = false;  // MultiMesh colors, authored in sRGB

void vertex() {
	VERTEX.y += terrain_height(VERTEX.xz);
}

void fragment() {
	vec4 tint = color;
	if (use_instance_color) {
		tint = COLOR;
		tint.rgb = mix(pow((tint.rgb + 0.055) / 1.055, vec3(2.4)), tint.rgb / 12.92, lessThan(tint.rgb, vec3(0.04045)));
	}
	ALBEDO = tint.rgb;
	ALPHA = tint.a;
}
