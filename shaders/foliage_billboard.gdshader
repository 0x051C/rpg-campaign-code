shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_disabled;

// Foliage sprites scattered on the terrain: upright quads that turn around Y to face the
// camera, sway in the wind from the top, and are lit like the ground they stand on.
// The quad's origin is its bottom center (QuadMesh center_offset y = 0.5).

uniform sampler2D albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
uniform float wind_strength = 0.06;  // meters of sway at the top
uniform float wind_speed = 1.6;
uniform bool instance_color = true;  // MultiMesh colors tint each sprite (sRGB)

void vertex() {
	vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 back = normalize(cross(right, up));
	float width = length(MODEL_MATRIX[0].xyz);
	float height = length(MODEL_MATRIX[1].xyz);
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = dot(origin.xz, vec2(0.7, 1.3));
	VERTEX.x += sin(TIME * wind_speed + phase) * wind_strength * VERTEX.y;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * width, 0.0), vec4(up * height, 0.0), vec4(back * width, 0.0), vec4(origin, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 texel = texture(albedo, UV);
	vec3 tint = vec3(1.0);
	if (instance_color) {
		tint = mix(pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), COLOR.rgb / 12.92, lessThan(COLOR.rgb, vec3(0.04045)));
	}
	ALBEDO = texel.rgb * tint;
	ALPHA = texel.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);  // lit like the ground
	ROUGHNESS = 1.0;
}
