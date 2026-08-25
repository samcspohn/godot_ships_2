shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled,
	shadows_disabled, fog_disabled;

// Paints the terrain dead zone for air-dropped ordnance (see DropShadow) onto
// whatever ground is on screen - the water, and the islands themselves.
//
// It is a decal, but a procedural one. Godot's Decal node projects a fixed
// texture, and the zone is not fixed: it swings around every island as the
// carrier moves, so it would have to be re-baked every frame at some
// compromise resolution over a 35 km map. Instead this draws as a full-screen
// quad, works out what each pixel is looking at, and evaluates the zone there.
// Same projection a deferred decal does, at full screen resolution, with
// nothing to bake.
//
// The sea is taken from where the view ray crosses the waterline, NOT from the
// depth buffer. The waterline is y = 0 by definition (Ocean.WATER_Y), so that
// is exact and free, and it keeps the zone on the water whatever the ocean mesh
// does - however the swell has lifted it, and whether or not it lands in the
// depth prepass ahead of this pass. The depth buffer is still read, but only
// for what is standing clear of the sea: terrain to drape the zone over, and
// the ships and aircraft that are not part of it.
//
// For each ground pixel it walks the NavigationMap height grid from that point
// back toward the carrier along a line climbing at `slope`, exactly as
// NavigationMap::terrain_shadow_depth does on the CPU, and shades where terrain
// breaks that line. The walk is bounded: a line rising at `slope` clears the
// tallest terrain that can reach the pixel after height/slope of run. Pixels
// outside every island's reach are discarded before the walk starts, so only
// ground actually near land pays for the march.

// Max terrain height per cell; 0 = open water.
uniform sampler2D height_tex : filter_linear, repeat_disable;
// Nearest, not linear: interpolating depth across a silhouette reconstructs
// world positions that lie on neither surface.
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec2 grid_min;        // world XZ of terrain grid cell (0, 0)
uniform vec2 grid_dims;       // terrain grid size in cells
uniform float cell_size;      // metres per cell
uniform vec2 carrier_xz;      // where the run-in comes from
uniform float slope;          // rise over run of the run-in
uniform float step_size;      // march step, metres

// Per-island cull discs: xy = centre, z = radius beyond which this island can
// cast no shadow, w = that island's tallest terrain. Filled by
// DropShadowOverlay from the NavigationMap islands.
const int MAX_CULL_DISCS = 64;
const int MAX_STEPS = 256;
uniform vec4 cull_discs[MAX_CULL_DISCS];
uniform int cull_count;

uniform vec4 zone_color : source_color = vec4(0.95, 0.15, 0.1, 0.18);
uniform vec4 edge_color : source_color = vec4(1.0, 0.35, 0.2, 0.55);
// How wide a band along the outer boundary of the zone gets the edge tint, in
// metres of drop point travel (see DropShadow.escape_distance).
uniform float edge_width = 250.0;
uniform float hatch_period = 120.0;
// How high a surface can stand and still be taken for the sea itself. Above it
// a pixel is either terrain, which the zone is painted onto, or a ship or an
// aircraft, which is not part of the zone and hides what is behind it. Sized to
// clear the swell with room to spare - too low and wave crests read as vessels.
uniform float sea_band = 12.0;

// Height with the cell-to-cell blend eased rather than straight. Hardware
// bilinear is only C0 - its gradient jumps at every cell boundary - and the edge
// of a shadow is a level set of this field, so straight bilinear draws it kinked
// on the 50 m lattice. Easing the fraction before the blend makes the field C1
// and the edge smooth, for a few ALU ops and the same single fetch.
// NavigationMap::sample_height_smooth does the identical thing on the CPU.
float sample_height(vec2 world_xz) {
	vec2 g = (world_xz - grid_min) / cell_size;
	vec2 i = floor(g);
	vec2 f = g - i;
	f = f * f * (3.0 - 2.0 * f);
	return texture(height_tex, (i + f + 0.5) / grid_dims).r;
}

// Tallest terrain that can shadow `p` at all: the highest peak among the islands
// whose reach covers it, or zero if none do. Doubles as the cull test and as the
// bound on how far the walk has to go - a point in reach of nothing but a low
// reef stops climbing long before one under a headland does.
float shadowing_height(vec2 p) {
	float tallest = 0.0;
	for (int i = 0; i < cull_count; i++) {
		vec2 d = p - cull_discs[i].xy;
		if (dot(d, d) <= cull_discs[i].z * cull_discs[i].z) {
			tallest = max(tallest, cull_discs[i].w);
		}
	}
	return tallest;
}

void vertex() {
	// Full-screen quad: the mesh is a 2x2 QuadMesh whose clip-space position is
	// written straight out, so it covers the viewport whatever the camera does.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	// The ray this pixel looks along, taken as two points on it so that it is
	// right under an orthographic projection as well as a perspective one -
	// under ortho every pixel has its own ray origin, and the camera position is
	// not on any of them. Depth is reversed, so ndc z = 1 is the near plane.
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec4 h_near = INV_PROJECTION_MATRIX * vec4(ndc, 1.0, 1.0);
	vec4 h_far = INV_PROJECTION_MATRIX * vec4(ndc, 0.0, 1.0);
	vec3 v_near = h_near.xyz / h_near.w;
	vec3 v_far = h_far.xyz / h_far.w;
	vec3 ro = (INV_VIEW_MATRIX * vec4(v_near, 1.0)).xyz;
	vec3 rd = normalize(mat3(INV_VIEW_MATRIX) * (v_far - v_near));

	// Whatever opaque surface was drawn here, if any.
	float d = texture(depth_tex, SCREEN_UV).r;
	bool has_surface = d > 0.0;
	vec3 surface = vec3(0.0);
	if (has_surface) {
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
		surface = (INV_VIEW_MATRIX * vec4(view.xyz / view.w, 1.0)).xyz;
	}

	// Where on the map this pixel is looking.
	vec2 p;
	if (has_surface && surface.y > sea_band) {
		// Standing clear of the sea. Terrain gets the zone draped onto it; a
		// ship or an aircraft is not part of the zone and hides what is behind
		// it. Told apart by whether the grid has any terrain in that cell at
		// all - the cell heights run a little PAST the true shore, so coastline
		// always reads as terrain. Asking the SDF which side of the shore the
		// pixel was on instead punched cell-shaped holes along every coast,
		// because that answer is only good to 50 m and the rendered mesh is not.
		if (sample_height(surface.xz) <= 0.0) {
			discard;
		}
		p = surface.xz;
	} else if (rd.y < -0.0001) {
		p = (ro + rd * (-ro.y / rd.y)).xz; // the sea, at the waterline
	} else {
		discard; // the horizon or above it
	}

	float reach_height = shadowing_height(p);
	if (reach_height <= 0.0) {
		discard;
	}

	// Metres of terrain standing above the run-in. Sea and land go through the
	// same walk, from the ground under the point - which is what makes the far
	// flank of an island and the water beyond it one continuous zone, and leaves
	// the near flank clear, since the run-in only ever descends across it.
	vec2 to_carrier = carrier_xz - p;
	float span = length(to_carrier);
	if (span < 1.0) {
		discard;
	}
	vec2 dir = to_carrier / span;
	float limit = min(span, reach_height / slope);
	float base = sample_height(p);
	// Only the depth inside the edge band is ever read back out (see below), so
	// the walk stops as soon as it has found more blocker than that band can
	// show. Deep inside a zone that is the first land sample; the walk only runs
	// its full length near the boundary, where the exact figure is what the edge
	// tint is drawn from.
	float depth_of_interest = edge_width * slope;
	float depth = 0.0;
	for (int i = 0; i < MAX_STEPS; i++) {
		float s = float(i) * step_size;
		if (s > limit || depth > depth_of_interest) {
			break;
		}
		depth = max(depth, sample_height(p + dir * s) - base - s * slope);
	}
	if (depth <= 0.0) {
		discard;
	}

	// Metres the drop point would have to move away from the carrier to come
	// clear - zero right on the boundary, growing inward.
	float escape = depth / slope;
	float edge = 1.0 - clamp(escape / edge_width, 0.0, 1.0);
	float hatch = step(0.5, fract((p.x + p.y) / hatch_period));

	ALBEDO = mix(zone_color.rgb, edge_color.rgb, edge);
	ALPHA = mix(zone_color.a * (0.6 + 0.4 * hatch), edge_color.a, edge);
}
