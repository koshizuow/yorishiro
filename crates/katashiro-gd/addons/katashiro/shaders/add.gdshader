shader_type canvas_item;
// Live2D additive: color (1, 1), alpha kept. Godot's add is (Sa, 1) for both, so the color comes out right
// when the shader sends rgb / k with alpha k; the alpha then gains k * k instead of nothing, and only shows
// where additive art lies over a transparent background. k is the largest premultiplied channel (the
// smallest k that keeps rgb / k within 0..1).
render_mode blend_add, unshaded;

#include "_draw.gdshaderinc"

void fragment() {
	if (discard_mask()) {
		discard;
	}
	
	vec4 color_tex = texture(TEXTURE, UV);
	float mask_val = sample_mask();
	
	if (color_tex.a == 0.0 || mask_val == 0.0) {
		discard;
	}
	
	vec4 color = artmesh_color(color_tex);
	color *= color_base;
	color *= modulate;
	color *= vec4(vec3(1.0), mask_val);
	
	vec3 premultiplied = color.rgb * color.a;
	float k = max(max(premultiplied.r, premultiplied.g), premultiplied.b);
	if (k <= 0.0) {
		discard;  // adds nothing
	}
	COLOR = vec4(premultiplied / k, k);
}