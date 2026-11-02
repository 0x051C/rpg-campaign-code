shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled;

// Spell particles: camera-facing quads whose texture says, per texel, how to mix:
//   A in [0, 0.5): additive glow, strength 1 at A = 0 falling to 0 at A = 0.5
//                  (so a black A = 0 background adds nothing; brightness lives in RGB)
//   A in [0.5, 1]: alpha blended, opacity 0 at A = 0.5 rising to 1 at A = 1
// Both reach zero at A = 0.5, so filtering between the two kinds leaves no seam. One
// premultiplied-alpha pass does both: out = src.rgb + dst * (1 - src.a).
// The particle color (process material color / ramp) tints both kinds; its alpha fades
// the whole particle.

uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_disable;
uniform float glow_energy = 1.0;  // scales the additive part
uniform bool color_is_srgb = true;  // particle colors are picked in sRGB
uniform int frames_h = 1;  // flipbook columns, driven by the process material's animation
uniform int frames_v = 1;
uniform bool frames_loop = false;
uniform float soft_distance = 0.4;  // meters over which particles fade where they meet geometry
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;

void vertex() {
	// As BaseMaterial3D's BILLBOARD_PARTICLES: face the camera, keep each particle's spin and size
	mat4 face = mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	face = face * mat4(vec4(cos(INSTANCE_CUSTOM.x), -sin(INSTANCE_CUSTOM.x), 0.0, 0.0),
			vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * face;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);

	if (frames_h * frames_v > 1) {
		float total = float(frames_h * frames_v);
		float frame = floor(INSTANCE_CUSTOM.z * total);
		frame = frames_loop ? mod(frame, total) : clamp(frame, 0.0, total - 1.0);
		UV /= vec2(float(frames_h), float(frames_v));
		UV += vec2(mod(frame, float(frames_h)) / float(frames_h), floor((frame + 0.5) / float(frames_h)) / float(frames_v));
	}
}

void fragment() {
	vec4 texel = texture(texture_albedo, UV);
	float add = clamp(1.0 - 2.0 * texel.a, 0.0, 1.0);
	float opacity = clamp(2.0 * texel.a - 1.0, 0.0, 1.0);

	vec3 tint = COLOR.rgb;
	if (color_is_srgb) {
		tint = mix(pow((tint + 0.055) / 1.055, vec3(2.4)), tint / 12.92, lessThan(tint, vec3(0.04045)));
	}
	float fade = COLOR.a;
	if (soft_distance > 0.0) {
		float depth = texture(depth_texture, SCREEN_UV).r;
		vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		fade *= clamp((VERTEX.z - scene.z / scene.w) / soft_distance, 0.0, 1.0);
	}
	ALBEDO = texel.rgb * tint * (add * glow_energy + opacity) * fade;
	ALPHA = opacity * fade;
}
