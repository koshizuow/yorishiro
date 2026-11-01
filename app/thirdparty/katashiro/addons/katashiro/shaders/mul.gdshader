shader_type canvas_item;
// Live2D multiply: color (Dst, 1 - Sa), alpha kept. Godot's mul is (Dst, 0) for color and (Da, 0) for alpha,
// so the shader sends rgb + (1 - a) with alpha 1: dst * (rgb + 1 - a) = Live2D's color, alpha stays dst's.
render_mode blend_mul, unshaded;

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
	
	COLOR = vec4(color.rgb * color.a + (1.0 - color.a), 1.0);
}