shader_type canvas_item;

uniform vec4 mist_color = vec4(.3, .3, .3, .75);
uniform float radius = 0.95;
uniform float smoothness = 0.9;
uniform float speed = 125;
uniform float noise_scale = 128;
uniform float time_scale = 1;

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

void fragment() {
    vec2 uv = UV + dFdx(UV);
    // Animate UV optical illusion of spinning
    float t = fract(TIME) * noise_scale / time_scale;
    vec2 scroll_offset = vec2(t * speed / 3., t * speed * 0.3); // diagonal motion
    vec2 distorted_uv = uv * noise_scale + scroll_offset;

    // Add noise-based turbulence
    float n = noise(distorted_uv);

    float mist = 0.0;

    // Bottom-left corner
    float dist_bl = distance(uv, vec2(.5, .5));
    mist += smoothstep(radius, radius - smoothness, dist_bl + n * 0.05);

    mist = clamp(mist, 0.0, 1.0);
    COLOR = mist_color * mist;
}
