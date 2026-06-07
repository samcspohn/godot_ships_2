shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, unshaded, shadows_disabled, fog_disabled;
stencil_mode write, compare_not_equal;

// Single-pass armor viewer shader.
// depth_test_disabled: draws over all scene geometry (hull, turrets, etc.)
// stencil write + compare_not_equal: the first armor fragment at each pixel
// writes stencil ref=1 and renders; subsequent armor fragments see stencil==1,
// fail the not_equal test, and are discarded. This prevents alpha stacking
// where armor pieces overlap.

uniform vec4 albedo_color : source_color = vec4(0.52, 0.52, 0.52, 0.44);

void fragment() {
    ALBEDO = COLOR.rgb * albedo_color.rgb;
    ALPHA = albedo_color.a;
}
