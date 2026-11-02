shader_type canvas_item;

uniform vec4 mist_color = vec4(1.0, 1.0, 1.0, .25);
uniform sampler2D flowmap;
uniform float radius = 0.45;
uniform float smoothness = 0.6;
uniform float speed = 125;
uniform float noise_scale = 128;
uniform float time_scale = 1.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(128.6, 360.3))) * 133711.1997);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float frac_time_stretched(float x){
	return clamp(fract(x), 0. , .3333) * 3.;
}

float fade_out(float x, float t){
	return 1. - frac_time_stretched(x + t * .1);
}

float base_c(float x, float t){
	return 1. - (fade_out(x, t) + fade_out(-x, -1. * t));
}

float animated_noise(float x, float t) {
    float f1 = base_c(x, t);
	float f2 = base_c(x + .3333, t);
	float f3 = base_c(x + .66667, t);
	return abs(f1-f2-f3);
}


void fragment() {
    float v = (UV.y - .5) / (1. - .5);
	
    vec2 bottom_uv = vec2(UV.x, v);
    vec4 flow = texture(flowmap, bottom_uv);
	
	v *= mod(TIME, flow.b*radius);

    float t = TIME * time_scale;
	float l_speed = speed * flow.z;
    vec2 scroll_offset = vec2(flow.x * l_speed, flow.y * l_speed);
    vec2 distorted_uv = bottom_uv * noise_scale + scroll_offset;

    float n = animated_noise(noise(distorted_uv), t);
    float mist = .0;

    // Bottom-left corner
    float dist_bl = distance(bottom_uv, vec2(0.0, 1.0));
    mist += smoothstep(radius, radius - smoothness, abs(dist_bl + pow(n, .5)));

    // Bottom-right corner
    float dist_br = distance(bottom_uv, vec2(1.0, 1.0));
    mist += smoothstep(radius, radius - smoothness, abs(dist_br + pow(n, .5)));
	
    mist = clamp(mist, 0.0, 1.0);
    COLOR = mist * flow.b * mist_color;
}
