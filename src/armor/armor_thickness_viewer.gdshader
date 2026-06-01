shader_type spatial;
render_mode depth_draw_always, cull_disabled, unshaded, shadows_disabled, fog_disabled;

// Armor thickness is encoded in vertex COLOR as a 16-bit integer:
//   COLOR.r * 255 = low byte  (armor_mm & 0xFF)
//   COLOR.g * 255 = high byte ((armor_mm >> 8) & 0xFF)
// ArmorMeshBuilder writes this encoding; this shader decodes and maps to a gradient.

// Breakpoint colors — exposed so they can be tweaked in the material inspector.
uniform vec4 color_0mm   : source_color = vec4(0.53, 0.81, 0.98, 1.0);  // light blue
uniform vec4 color_19mm  : source_color = vec4(0.53, 0.81, 0.98, 1.0);  // light blue
uniform vec4 color_27mm  : source_color = vec4(0.00, 0.50, 0.50, 1.0);  // teal
uniform vec4 color_30mm  : source_color = vec4(0.00, 0.65, 0.58, 1.0);  // blue-green
uniform vec4 color_36mm  : source_color = vec4(0.18, 0.80, 0.18, 1.0);  // green
uniform vec4 color_50mm  : source_color = vec4(1.00, 0.84, 0.00, 1.0);  // yellow
uniform vec4 color_80mm  : source_color = vec4(1.00, 0.55, 0.00, 1.0);  // orange
uniform vec4 color_200mm : source_color = vec4(0.86, 0.08, 0.24, 1.0);  // red
uniform vec4 color_600mm : source_color = vec4(0.25, 0.00, 0.00, 1.0);  // very dark red

vec3 armor_gradient(float mm) {
	if (mm <= 19.0)  return mix(color_0mm.rgb,   color_19mm.rgb,  clamp(mm / 19.0, 0.0, 1.0));
	if (mm <= 27.0)  return mix(color_19mm.rgb,  color_27mm.rgb,  (mm - 19.0)  /   8.0);
	if (mm <= 30.0)  return mix(color_27mm.rgb,  color_30mm.rgb,  (mm - 27.0)  /   3.0);
	if (mm <= 36.0)  return mix(color_30mm.rgb,  color_36mm.rgb,  (mm - 30.0)  /   6.0);
	if (mm <= 50.0)  return mix(color_36mm.rgb,  color_50mm.rgb,  (mm - 36.0)  /  14.0);
	if (mm <= 80.0)  return mix(color_50mm.rgb,  color_80mm.rgb,  (mm - 50.0)  /  30.0);
	if (mm <= 200.0) return mix(color_80mm.rgb,  color_200mm.rgb, (mm - 80.0)  / 120.0);
	return mix(color_200mm.rgb, color_600mm.rgb, clamp((mm - 200.0) / 400.0, 0.0, 1.0));
}

void fragment() {
	float lo = round(COLOR.r * 255.0);
	float hi = round(COLOR.g * 255.0);
	float armor_mm = lo + hi * 256.0;
	if (armor_mm == 0.0) discard;
	ALBEDO = armor_gradient(armor_mm);
	ALPHA = 1.0;
}
