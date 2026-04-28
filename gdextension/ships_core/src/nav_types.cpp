#include "nav_types.h"

#include <queue>
#include <utility>

namespace godot {

void BlockedGrid::build(const std::vector<ThreatArc>& arcs, float p_cell_size) {
	blocked.clear();
	grid_w = grid_h = 0;
	if (arcs.empty() || p_cell_size <= 0.0f) return;

	cell_size = p_cell_size;

	// World-space bbox of every arc — three extreme points (origin and
	// both terminal wedge corners) form the convex hull, padded by one
	// cell to keep the spine-walk stamps in bounds.
	float mn_x =  std::numeric_limits<float>::infinity();
	float mn_z =  std::numeric_limits<float>::infinity();
	float mx_x = -std::numeric_limits<float>::infinity();
	float mx_z = -std::numeric_limits<float>::infinity();
	for (const auto& a : arcs) {
		float c0 = std::cos(a.bearing - a.half_angle);
		float s0 = std::sin(a.bearing - a.half_angle);
		float c1 = std::cos(a.bearing + a.half_angle);
		float s1 = std::sin(a.bearing + a.half_angle);
		Vector2 p0(a.origin.x + a.length * c0, a.origin.y + a.length * s0);
		Vector2 p1(a.origin.x + a.length * c1, a.origin.y + a.length * s1);
		mn_x = std::min({mn_x, a.origin.x, p0.x, p1.x});
		mx_x = std::max({mx_x, a.origin.x, p0.x, p1.x});
		mn_z = std::min({mn_z, a.origin.y, p0.y, p1.y});
		mx_z = std::max({mx_z, a.origin.y, p0.y, p1.y});
	}

	origin_x = mn_x - cell_size;
	origin_z = mn_z - cell_size;
	grid_w = (int)std::ceil((mx_x - mn_x) / cell_size) + 3;
	grid_h = (int)std::ceil((mx_z - mn_z) / cell_size) + 3;
	if (grid_w <= 0 || grid_h <= 0) {
		blocked.clear();
		grid_w = grid_h = 0;
		return;
	}
	blocked.assign((size_t)grid_w * grid_h, 0);

	// Spine-walk rasterization.  For each arc we step radially from the
	// origin in cell_size/2 increments and at each radius walk a chord
	// across the wedge, stamping the touched cell.  Cost per arc is
	// O(L * chord_at_L / cell_size^2) — for a 6 km arc at 30 deg with
	// 400 m cells, ~120 stamps versus ~900 cell tests for the prior AABB
	// scan.
	float inv_cs = 1.0f / cell_size;
	for (const auto& a : arcs) {
		float cos_b = std::cos(a.bearing);
		float sin_b = std::sin(a.bearing);
		float tan_h = std::tan(a.half_angle);
		float L = a.length;
		if (L <= 0.0f) continue;

		float radial_step = cell_size * 0.5f;
		int n_radial = (int)std::ceil(L / radial_step);
		if (n_radial < 1) n_radial = 1;

		// Perpendicular axis for chord traversal at each radius.
		float perp_x = -sin_b;
		float perp_z =  cos_b;

		for (int ri = 0; ri <= n_radial; ++ri) {
			float r = std::min((float)ri * radial_step, L);
			float bx = a.origin.x + r * cos_b;
			float bz = a.origin.y + r * sin_b;
			float chord_half = r * tan_h;          // wedge half-width at radius r
			int n_chord = (int)std::ceil(2.0f * chord_half / cell_size);
			if (n_chord < 1) n_chord = 1;
			for (int ci = 0; ci <= n_chord; ++ci) {
				float t = (n_chord > 0) ?
					(-chord_half + (2.0f * chord_half) * ((float)ci / (float)n_chord)) :
					0.0f;
				float wx = bx + t * perp_x;
				float wz = bz + t * perp_z;
				int ix = (int)std::floor((wx - origin_x) * inv_cs);
				int iz = (int)std::floor((wz - origin_z) * inv_cs);
				if (ix < 0 || ix >= grid_w || iz < 0 || iz >= grid_h) continue;
				blocked[(size_t)iz * grid_w + ix] = 1;
			}
		}
	}
}

bool BlockedGrid::find_nearest_unblocked(Vector2 pos, int max_radius_cells, Vector2& out) const {
	if (blocked.empty()) {
		out = pos;
		return true;
	}
	int sx = cx(pos.x), sz = cz(pos.y);
	auto cell_to_world = [&](int ix, int iz) -> Vector2 {
		return Vector2(origin_x + ((float)ix + 0.5f) * cell_size,
		               origin_z + ((float)iz + 0.5f) * cell_size);
	};

	// If start is outside the grid, the cell is already "open" (no arc reaches it).
	if (sx < 0 || sx >= grid_w || sz < 0 || sz >= grid_h) {
		out = pos;
		return true;
	}
	if (blocked[(size_t)sz * grid_w + sx] == 0) {
		out = pos;
		return true;
	}

	// 4-connected BFS.  Visited-bit reuses a local bitmap sized w*h.
	std::vector<uint8_t> seen((size_t)grid_w * grid_h, 0);
	std::queue<std::pair<int,int>> q;
	q.push({sx, sz});
	seen[(size_t)sz * grid_w + sx] = 1;

	const int dirs[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
	int max_steps = (int)seen.size();
	if (max_radius_cells > 0) {
		int budget = (2 * max_radius_cells + 1);
		max_steps = std::min(max_steps, budget * budget);
	}
	int visited = 0;
	while (!q.empty()) {
		auto [ix, iz] = q.front(); q.pop();
		visited++;
		if (visited > max_steps) break;
		for (auto& d : dirs) {
			int nx = ix + d[0], nz = iz + d[1];
			if (nx < 0 || nx >= grid_w || nz < 0 || nz >= grid_h) continue;
			size_t nidx = (size_t)nz * grid_w + nx;
			if (seen[nidx]) continue;
			seen[nidx] = 1;
			if (blocked[nidx] == 0) {
				out = cell_to_world(nx, nz);
				return true;
			}
			q.push({nx, nz});
		}
	}
	return false;
}

} // namespace godot
