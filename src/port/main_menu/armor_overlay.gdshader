shader_type canvas_item;

uniform float opacity : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec4 armor_color = texture(TEXTURE, UV);
	COLOR = vec4(armor_color.rgb, armor_color.a * opacity);
}
