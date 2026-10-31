// A clay hand drawn as one smooth surface: rounded segments for the finger bones and palm, blended with a
// smooth minimum, found by ray marching inside a box around the hand (preview_hand.gd fills the segments).
// Normals and depth are written so Godot lights it like the head and the head can hide it.
shader_type spatial;
render_mode cull_back;

const int MAX_SEGMENTS = 32;
// a: start (xyz) and radius there (w), b: end and radius there, in the box's own space (metres)
uniform vec4 seg_a[MAX_SEGMENTS];
uniform vec4 seg_b[MAX_SEGMENTS];
uniform int segment_count = 0;
// the first finger_count segments are fingers, the rest the palm
uniform int finger_count = 0;
// how far blends reach: fingers barely (they must not stick together), the palm's parts into one mass,
// and the fingers into the palm
uniform float finger_blend = 0.003;
uniform float palm_blend = 0.012;
uniform float join_blend = 0.006;
uniform vec3 half_size = vec3(0.1);
uniform vec3 clay : source_color = vec3(0.93, 0.88, 0.90);

varying vec3 local_vertex;

void vertex() {
	local_vertex = VERTEX;
}

float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

// a segment whose radius runs from a.w to b.w
float segment(vec3 p, vec4 a, vec4 b) {
	vec3 pa = p - a.xyz;
	vec3 ba = b.xyz - a.xyz;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9), 0.0, 1.0);
	return length(pa - ba * h) - mix(a.w, b.w, h);
}

float hand(vec3 p) {
	float fingers = 1e9;
	float palm = 1e9;
	for (int i = 0; i < MAX_SEGMENTS; i++) {
		if (i >= segment_count) {
			break;
		}
		float d = segment(p, seg_a[i], seg_b[i]);
		if (i < finger_count) {
			fingers = smin(fingers, d, finger_blend);
		} else {
			palm = smin(palm, d, palm_blend);
		}
	}
	return smin(fingers, palm, join_blend);
}

vec3 hand_normal(vec3 p) {
	vec2 e = vec2(0.0005, 0.0);
	return normalize(vec3(
		hand(p + e.xyy) - hand(p - e.xyy),
		hand(p + e.yxy) - hand(p - e.yxy),
		hand(p + e.yyx) - hand(p - e.yyx)));
}

void fragment() {
	mat4 to_local = inverse(MODEL_MATRIX);
	vec3 eye = (to_local * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 dir = normalize(local_vertex - eye);
	vec3 p = local_vertex;  // the box's front face
	bool hit = false;
	for (int i = 0; i < 96; i++) {
		float d = hand(p);
		if (d < 0.0002) {
			hit = true;
			break;
		}
		p += dir * d;
		if (any(greaterThan(abs(p), half_size + 0.001))) {
			break;
		}
	}
	if (!hit) {
		discard;
	}
	vec3 n = hand_normal(p);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n, 0.0)).xyz);
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(p, 1.0);
	DEPTH = clip.z / clip.w;
	ALBEDO = clay;
	ROUGHNESS = 0.7;
	RIM = 0.25;
}
