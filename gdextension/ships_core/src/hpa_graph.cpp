#include "hpa_graph.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>
#include <cstring>

namespace godot {

// True if segment (ax,az)-(bx,bz) clips any part of the AABB [x0,x1]×[z0,z1].
// Uses Liang-Barsky parametric clipping — exact, no sqrt required.
static bool segment_clips_aabb(
	float ax, float az, float bx, float bz,
	float x0, float z0, float x1, float z1)
{
	float dx = bx - ax, dz = bz - az;
	float t0 = 0.0f, t1 = 1.0f;
	auto clip = [&](float p, float q) -> bool {
		if (p == 0.0f) return q >= 0.0f;
		float r = q / p;
		if (p < 0.0f) { if (r > t1) return false; if (r > t0) t0 = r; }
		else          { if (r < t0) return false; if (r < t1) t1 = r; }
		return true;
	};
	return clip(-dx, ax - x0) && clip(dx, x1 - ax) &&
	       clip(-dz, az - z0) && clip(dz, z1 - az) &&
	       t0 <= t1;
}

// ============================================================================
// _bind_methods
// ============================================================================

void HpaGraph::_bind_methods() {
	ClassDB::bind_method(
		D_METHOD("build", "nav_map", "clearance", "cluster_size"),
		&HpaGraph::build, DEFVAL(DEFAULT_CLUSTER_SIZE));
	ClassDB::bind_method(D_METHOD("is_built"), &HpaGraph::is_built);
	ClassDB::bind_method(
		D_METHOD("find_path_packed", "from", "to", "query_clearance"),
		&HpaGraph::find_path_packed, DEFVAL(-1.0f));
	ClassDB::bind_method(
		D_METHOD("add_obstacle", "id", "pos", "radius"),
		&HpaGraph::add_obstacle);
	ClassDB::bind_method(D_METHOD("remove_obstacle", "id"), &HpaGraph::remove_obstacle);
	ClassDB::bind_method(D_METHOD("clear_obstacles"), &HpaGraph::clear_obstacles);
	ClassDB::bind_method(D_METHOD("get_node_count"), &HpaGraph::get_node_count);
	ClassDB::bind_method(D_METHOD("get_cluster_count"), &HpaGraph::get_cluster_count);
	ClassDB::bind_method(D_METHOD("get_sub_cluster_count"), &HpaGraph::get_sub_cluster_count);
	ClassDB::bind_method(D_METHOD("get_debug_nodes"), &HpaGraph::get_debug_nodes);
	ClassDB::bind_method(D_METHOD("get_debug_edges"), &HpaGraph::get_debug_edges);
	ClassDB::bind_method(D_METHOD("get_debug_clusters"), &HpaGraph::get_debug_clusters);
	ClassDB::bind_method(D_METHOD("get_debug_sub_clusters"), &HpaGraph::get_debug_sub_clusters);
	ClassDB::bind_method(D_METHOD("get_debug_threat_clusters"), &HpaGraph::get_debug_threat_clusters);
	ClassDB::bind_method(D_METHOD("get_perf_metrics"), &HpaGraph::get_perf_metrics);
	ClassDB::bind_method(D_METHOD("reset_perf_metrics"), &HpaGraph::reset_perf_metrics);
	ClassDB::bind_method(D_METHOD("set_perf_spike_threshold_us", "threshold_us"), &HpaGraph::set_perf_spike_threshold_us);
	ClassDB::bind_method(D_METHOD("get_perf_spike_threshold_us"), &HpaGraph::get_perf_spike_threshold_us);
	ClassDB::bind_method(D_METHOD("set_perf_tracking_enabled", "enabled"), &HpaGraph::set_perf_tracking_enabled);
	ClassDB::bind_method(D_METHOD("is_perf_tracking_enabled"), &HpaGraph::is_perf_tracking_enabled);
}

HpaGraph::HpaGraph() = default;
HpaGraph::~HpaGraph() = default;

// ============================================================================
// build
// ============================================================================

void HpaGraph::build(Ref<NavigationMap> map, float clearance, int cluster_size) {
	built_ = false;
	clusters_.clear();
	sub_clusters_.clear();
	cluster_block_count_.clear();
	cluster_threat_blocked_.clear();
	threat_blocked_cids_.clear();
	threat_blocked_count_ = 0;
	obstacles_.clear();

	if (!map.is_valid() || !map->is_built()) {
		UtilityFunctions::print("[HpaGraph] build: NavigationMap is not built");
		return;
	}

	nav_map_      = map;
	clearance_    = clearance;
	cluster_size_ = (cluster_size > 0) ? cluster_size : DEFAULT_CLUSTER_SIZE;
	grid_w_       = map->get_grid_width();
	grid_h_       = map->get_grid_height();
	cell_size_    = map->get_cell_size_value();
	min_x_        = map->get_min_x();
	min_z_        = map->get_min_z();

	ncx_ = (grid_w_ + cluster_size_ - 1) / cluster_size_;
	ncz_ = (grid_h_ + cluster_size_ - 1) / cluster_size_;

	// Sub-cluster sizing: keep sub_size_ tied to the default ratio.  Require
	// cluster_size_ to be a positive integer multiple of sub_size_ so each
	// macro contains a whole number of subs and indexing stays trivial.
	sub_size_ = DEFAULT_SUB_SIZE;
	if (sub_size_ <= 0 || cluster_size_ % sub_size_ != 0) {
		UtilityFunctions::print(
			"[HpaGraph] build: cluster_size (", cluster_size_,
			") must be a positive multiple of sub_size (", sub_size_,
			") \u2014 aborting build");
		return;
	}
	subs_per_macro_side_ = cluster_size_ / sub_size_;
	nsubx_ = ncx_ * subs_per_macro_side_;
	nsubz_ = ncz_ * subs_per_macro_side_;

	// Constant cluster A* step costs: every neighbour edge in the cluster
	// grid is exactly one cluster wide (cardinal) or one cluster diagonal.
	// No need to recompute sqrt for every expansion.
	cardinal_step_cost_ = static_cast<float>(cluster_size_) * cell_size_;
	diagonal_step_cost_ = cardinal_step_cost_ * 1.41421356237f;

	UtilityFunctions::print(
		"[HpaGraph] building ", ncx_, "x", ncz_,
		" clusters (", cluster_size_, " cells each) and ",
		nsubx_, "x", nsubz_, " sub-clusters (", sub_size_,
		" cells each) on grid ", grid_w_, "x", grid_h_);

	build_clusters();
	build_sub_clusters();

	int navigable_count = 0;
	for (const Cluster &c : clusters_)
		if (c.navigable) ++navigable_count;

	int sub_navigable_count = 0;
	for (const SubCluster &s : sub_clusters_)
		if (s.navigable) ++sub_navigable_count;

	UtilityFunctions::print(
		"[HpaGraph] built: ", (int)clusters_.size(), " clusters (",
		navigable_count, " navigable), ",
		(int)sub_clusters_.size(), " sub-clusters (",
		sub_navigable_count, " navigable)");

	built_ = true;
}

// ============================================================================
// build_clusters
// ============================================================================

void HpaGraph::build_clusters() {
	int total = ncx_ * ncz_;
	clusters_.resize(total);
	cluster_block_count_.assign(total, 0);
	cluster_threat_blocked_.assign(total, 0);

	const float NEG_INF = -std::numeric_limits<float>::infinity();
	const float POS_INF =  std::numeric_limits<float>::infinity();

	for (int cz = 0; cz < ncz_; ++cz) {
		for (int cx = 0; cx < ncx_; ++cx) {
			int id = cluster_id(cx, cz);
			Cluster &c = clusters_[id];
			c.id  = id;
			c.cx  = cx;
			c.cz  = cz;
			c.x0  = cx * cluster_size_;
			c.z0  = cz * cluster_size_;
			c.x1  = std::min(c.x0 + cluster_size_ - 1, grid_w_ - 1);
			c.z1  = std::min(c.z0 + cluster_size_ - 1, grid_h_ - 1);

			// Macro→sub range (always a full subs_per_macro_side_ × ... block;
			// out-of-grid subs are clamped/marked impassable in build_sub_clusters).
			c.sub_x0 = cx * subs_per_macro_side_;
			c.sub_z0 = cz * subs_per_macro_side_;
			c.sub_x1 = c.sub_x0 + subs_per_macro_side_ - 1;
			c.sub_z1 = c.sub_z0 + subs_per_macro_side_ - 1;

			// Cluster centre (world coords of the middle cell).
			grid_to_world((c.x0 + c.x1) / 2, (c.z0 + c.z1) / 2,
			              c.wx_center, c.wz_center);

			// Full SDF scan to get max_sdf and min_sdf.
			float max_sdf = NEG_INF;
			float min_sdf = POS_INF;
			for (int gz = c.z0; gz <= c.z1; ++gz) {
				for (int gx = c.x0; gx <= c.x1; ++gx) {
					float wx, wz;
					grid_to_world(gx, gz, wx, wz);
					float sdf = nav_map_->get_distance(wx, wz);
					if (sdf > max_sdf) max_sdf = sdf;
					if (sdf < min_sdf) min_sdf = sdf;
				}
			}
			c.max_sdf  = max_sdf;
			c.min_sdf  = min_sdf;
			c.navigable = (max_sdf >= clearance_);
		}
	}
}

// ============================================================================
// build_sub_clusters
// ============================================================================
//
// One sub-cluster per (sub_size_ × sub_size_) cell block.  The sub grid is
// always exactly ncx_*subs_per_macro_side_ × ncz_*subs_per_macro_side_, even
// if the underlying cell grid isn't a multiple of cluster_size_.  Subs that
// fall fully outside the cell grid are marked non-navigable; partial subs
// scan only their in-bounds cells.
//
void HpaGraph::build_sub_clusters() {
	int total = nsubx_ * nsubz_;
	sub_clusters_.assign(total, SubCluster{});

	const float NEG_INF = -std::numeric_limits<float>::infinity();
	const float POS_INF =  std::numeric_limits<float>::infinity();

	for (int scz = 0; scz < nsubz_; ++scz) {
		for (int scx = 0; scx < nsubx_; ++scx) {
			int sid = sub_id(scx, scz);
			SubCluster &s = sub_clusters_[sid];
			s.id  = sid;
			s.scx = scx;
			s.scz = scz;

			// Parent macro.
			int parent_cx = scx / subs_per_macro_side_;
			int parent_cz = scz / subs_per_macro_side_;
			s.parent_cid = cluster_id(parent_cx, parent_cz);

			// Cell range in the underlying SDF grid.
			int x0 = scx * sub_size_;
			int z0 = scz * sub_size_;
			int x1 = x0 + sub_size_ - 1;
			int z1 = z0 + sub_size_ - 1;

			// Wholly outside the cell grid — mark impassable, no SDF scan.
			if (x0 >= grid_w_ || z0 >= grid_h_) {
				s.x0 = x0; s.z0 = z0; s.x1 = x1; s.z1 = z1;
				s.max_sdf = NEG_INF;
				s.min_sdf = NEG_INF;
				s.navigable = false;
				// Centre still computed for debug/visualisation.
				grid_to_world((x0 + x1) / 2, (z0 + z1) / 2,
				              s.wx_center, s.wz_center);
				continue;
			}

			// Clamp to cell grid (last column/row of subs may be partial).
			s.x0 = x0;
			s.z0 = z0;
			s.x1 = std::min(x1, grid_w_ - 1);
			s.z1 = std::min(z1, grid_h_ - 1);

			grid_to_world((s.x0 + s.x1) / 2, (s.z0 + s.z1) / 2,
			              s.wx_center, s.wz_center);

			float max_sdf = NEG_INF;
			float min_sdf = POS_INF;
			for (int gz = s.z0; gz <= s.z1; ++gz) {
				for (int gx = s.x0; gx <= s.x1; ++gx) {
					float wx, wz;
					grid_to_world(gx, gz, wx, wz);
					float sdf = nav_map_->get_distance(wx, wz);
					if (sdf > max_sdf) max_sdf = sdf;
					if (sdf < min_sdf) min_sdf = sdf;
				}
			}
			s.max_sdf   = max_sdf;
			s.min_sdf   = min_sdf;
			s.navigable = (max_sdf >= clearance_);
		}
	}
}

// ============================================================================
// clusters_in_radius
// ============================================================================

std::vector<int> HpaGraph::clusters_in_radius(Vector2 pos, float radius) const {
	std::vector<int> result;
	if (clusters_.empty()) return result;

	float wx0 = pos.x - radius;
	float wx1 = pos.x + radius;
	float wz0 = pos.y - radius;
	float wz1 = pos.y + radius;

	float cluster_world = static_cast<float>(cluster_size_) * cell_size_;

	int cx0 = static_cast<int>((wx0 - min_x_) / cluster_world);
	int cx1 = static_cast<int>((wx1 - min_x_) / cluster_world);
	int cz0 = static_cast<int>((wz0 - min_z_) / cluster_world);
	int cz1 = static_cast<int>((wz1 - min_z_) / cluster_world);

	cx0 = std::max(0, cx0);  cx1 = std::min(ncx_ - 1, cx1);
	cz0 = std::max(0, cz0);  cz1 = std::min(ncz_ - 1, cz1);

	for (int cz = cz0; cz <= cz1; ++cz)
		for (int cx = cx0; cx <= cx1; ++cx)
			result.push_back(cluster_id(cx, cz));
	return result;
}

// ============================================================================
// add_obstacle / remove_obstacle / clear_obstacles
// ============================================================================

void HpaGraph::add_obstacle(int id, Vector2 pos, float radius) {
	remove_obstacle(id);
	HpaObstacle obs{ id, pos, radius };
	std::vector<int> cids = clusters_in_radius(pos, radius);
	for (int cid : cids) cluster_block_count_[cid]++;
	obstacles_[id] = obs;
}

void HpaGraph::remove_obstacle(int id) {
	auto it = obstacles_.find(id);
	if (it == obstacles_.end()) return;
	const HpaObstacle &obs = it->second;
	std::vector<int> cids = clusters_in_radius(obs.pos, obs.radius);
	for (int cid : cids)
		if (cid >= 0 && cid < (int)cluster_block_count_.size())
			cluster_block_count_[cid] = std::max(0, cluster_block_count_[cid] - 1);
	obstacles_.erase(it);
}

void HpaGraph::clear_obstacles() {
	std::fill(cluster_block_count_.begin(), cluster_block_count_.end(), 0);
	obstacles_.clear();
}

// ============================================================================
// cluster_astar
// A* on the cluster grid.  Returns ordered cluster IDs from_cid → to_cid.
// Clusters with max_sdf < q_cl are impassable for this ship.
// ============================================================================

std::vector<int> HpaGraph::cluster_astar(int from_cid, int to_cid, float q_cl) const {
	if (from_cid == to_cid) return { from_cid };
	if (from_cid < 0 || to_cid < 0 ||
		from_cid >= (int)clusters_.size() ||
		to_cid   >= (int)clusters_.size()) return {};

	const int N = static_cast<int>(clusters_.size());
	const float INF = std::numeric_limits<float>::infinity();

	std::vector<float> g(N, INF);
	std::vector<int>   parent(N, -1);
	std::vector<bool>  closed(N, false);

	const Cluster &goal_c = clusters_[to_cid];
	auto heur = [&](int cid) -> float {
		const Cluster &c = clusters_[cid];
		float dx = c.wx_center - goal_c.wx_center;
		float dz = c.wz_center - goal_c.wz_center;
		return std::sqrt(dx * dx + dz * dz);
	};

	using PQ = std::pair<float, int>;
	std::priority_queue<PQ, std::vector<PQ>, std::greater<PQ>> open;

	g[from_cid] = 0.0f;
	open.push({ heur(from_cid), from_cid });

	while (!open.empty()) {
		auto [f, cur] = open.top(); open.pop();
		if (closed[cur]) continue;
		closed[cur] = true;
		if (cur == to_cid) break;

		const Cluster &cc = clusters_[cur];

		for (int dz = -1; dz <= 1; ++dz) {
			for (int dx = -1; dx <= 1; ++dx) {
				if (dx == 0 && dz == 0) continue;

				int ncx = cc.cx + dx;
				int ncz = cc.cz + dz;
				if (ncx < 0 || ncx >= ncx_ || ncz < 0 || ncz >= ncz_) continue;

				int ncid = cluster_id(ncx, ncz);
				if (closed[ncid]) continue;

				// Impassable: no navigable cell for this ship's clearance.
				if (clusters_[ncid].max_sdf < q_cl) continue;

				// Blocked by obstacle / threat (allow reaching the goal cluster).
				if (ncid != to_cid && cluster_blocked(ncid)) continue;

				// Diagonal: both cardinal neighbours must also be passable
				// to prevent cutting through impassable corners.
				bool is_diag = (dx != 0 && dz != 0);
				if (is_diag) {
					int cid_x = cluster_id(cc.cx + dx, cc.cz);
					int cid_z = cluster_id(cc.cx,      cc.cz + dz);
					if (clusters_[cid_x].max_sdf < q_cl) continue;
					if (clusters_[cid_z].max_sdf < q_cl) continue;
				}

				float step_cost = is_diag ? diagonal_step_cost_ : cardinal_step_cost_;
				float ng = g[cur] + step_cost;

				if (ng < g[ncid]) {
					g[ncid] = ng;
					parent[ncid] = cur;
					open.push({ ng + heur(ncid), ncid });
				}
			}
		}
	}

	if (g[to_cid] == INF) return {};

	std::vector<int> path;
	for (int c = to_cid; c != -1; c = parent[c]) {
		path.push_back(c);
		if (c == from_cid) break;
	}
	std::reverse(path.begin(), path.end());
	return path;
}

// ============================================================================
// sub_cluster_astar
// A* on the sub-cluster grid.  Returns ordered sub-cluster IDs
// from_sid → to_sid.  Sub-clusters with max_sdf < q_cl are impassable.
// If allowed_macros is supplied, only sub-clusters whose parent macro is
// flagged are considered passable (corridor constraint).
// ============================================================================

std::vector<int> HpaGraph::sub_cluster_astar(
		int from_sid, int to_sid, float q_cl,
		const std::vector<uint8_t>* allowed_macros) const {
	if (from_sid == to_sid) return { from_sid };
	const int N = static_cast<int>(sub_clusters_.size());
	if (from_sid < 0 || to_sid < 0 || from_sid >= N || to_sid >= N) return {};

	const float INF = std::numeric_limits<float>::infinity();

	// Step costs at sub-cluster granularity — constant, no per-edge sqrt.
	const float sub_card = static_cast<float>(sub_size_) * cell_size_;
	const float sub_diag = sub_card * 1.41421356237f;

	std::vector<float> g(N, INF);
	std::vector<int>   parent(N, -1);
	std::vector<bool>  closed(N, false);

	const SubCluster &goal_s = sub_clusters_[to_sid];
	auto heur = [&](int sid) -> float {
		const SubCluster &s = sub_clusters_[sid];
		float dx = s.wx_center - goal_s.wx_center;
		float dz = s.wz_center - goal_s.wz_center;
		return std::sqrt(dx * dx + dz * dz);
	};

	auto macro_allowed = [&](int parent_cid) -> bool {
		if (!allowed_macros) return true;
		if (parent_cid < 0 || parent_cid >= static_cast<int>(allowed_macros->size())) return false;
		return (*allowed_macros)[parent_cid] != 0;
	};

	// The goal sub may legitimately lie in a non-allowed macro (e.g. start/goal
	// pinned to a coastal macro the abstract pass excluded); waive the corridor
	// rule for from_sid and to_sid only.
	auto sub_passable = [&](int sid) -> bool {
		const SubCluster &s = sub_clusters_[sid];
		if (s.max_sdf < q_cl) return false;
		if (sid == from_sid || sid == to_sid) return true;
		if (!macro_allowed(s.parent_cid)) return false;
		// Re-use macro-level obstacle/threat blocking.  A sub inside a blocked
		// macro is blocked too — except when it's the goal sub (mirror of the
		// macro A* rule that lets the path reach a blocked goal).
		if (cluster_blocked(s.parent_cid)) return false;
		return true;
	};

	if (!sub_passable(from_sid) && from_sid != to_sid) {
		// from_sid impassable on its own merits (max_sdf < q_cl) — caller must
		// have picked a bad start.  Bail rather than silently routing nowhere.
		return {};
	}

	using PQ = std::pair<float, int>;
	std::priority_queue<PQ, std::vector<PQ>, std::greater<PQ>> open;

	g[from_sid] = 0.0f;
	open.push({ heur(from_sid), from_sid });

	while (!open.empty()) {
		auto [f, cur] = open.top(); open.pop();
		if (closed[cur]) continue;
		closed[cur] = true;
		if (cur == to_sid) break;

		const SubCluster &cs = sub_clusters_[cur];

		for (int dz = -1; dz <= 1; ++dz) {
			for (int dx = -1; dx <= 1; ++dx) {
				if (dx == 0 && dz == 0) continue;

				int nscx = cs.scx + dx;
				int nscz = cs.scz + dz;
				if (nscx < 0 || nscx >= nsubx_ || nscz < 0 || nscz >= nsubz_) continue;

				int nsid = sub_id(nscx, nscz);
				if (closed[nsid]) continue;
				if (!sub_passable(nsid)) continue;

				// Diagonal corner-cutting rule: both cardinal neighbours must
				// also be passable, otherwise we'd slip through an impassable
				// corner that the ship physically cannot fit through.
				bool is_diag = (dx != 0 && dz != 0);
				if (is_diag) {
					int sid_x = sub_id(cs.scx + dx, cs.scz);
					int sid_z = sub_id(cs.scx,      cs.scz + dz);
					if (!sub_passable(sid_x)) continue;
					if (!sub_passable(sid_z)) continue;
				}

				float step_cost = is_diag ? sub_diag : sub_card;
				float ng = g[cur] + step_cost;

				if (ng < g[nsid]) {
					g[nsid] = ng;
					parent[nsid] = cur;
					open.push({ ng + heur(nsid), nsid });
				}
			}
		}
	}

	if (g[to_sid] == INF) return {};

	std::vector<int> path;
	for (int c = to_sid; c != -1; c = parent[c]) {
		path.push_back(c);
		if (c == from_sid) break;
	}
	std::reverse(path.begin(), path.end());
	return path;
}

// ============================================================================
// constrained_cell_astar
// ============================================================================

PathResult HpaGraph::constrained_cell_astar(
		Vector2 from, Vector2 to, float q_cl,
		const std::vector<uint8_t> &allowed_macros) const {
	PathResult result;
	result.valid = false;
	result.total_distance = 0.0f;

	if (!built_ || !nav_map_.is_valid()) return result;

	auto world_to_gx = [&](float wx) -> int {
		return std::max(0, std::min(static_cast<int>((wx - min_x_) / cell_size_), grid_w_ - 1));
	};
	auto world_to_gz = [&](float wz) -> int {
		return std::max(0, std::min(static_cast<int>((wz - min_z_) / cell_size_), grid_h_ - 1));
	};
	auto idx = [&](int gx, int gz) -> int { return gz * grid_w_ + gx; };

	int sx = world_to_gx(from.x), sz = world_to_gz(from.y);
	int ex = world_to_gx(to.x),   ez = world_to_gz(to.y);
	const int start_idx = idx(sx, sz);
	const int end_idx = idx(ex, ez);

	auto macro_allowed = [&](int cid) -> bool {
		return cid >= 0 && cid < static_cast<int>(allowed_macros.size()) && allowed_macros[cid] != 0;
	};
	auto cell_allowed = [&](int gx, int gz) -> bool {
		if (gx < 0 || gx >= grid_w_ || gz < 0 || gz >= grid_h_) return false;
		int cidx = idx(gx, gz);
		int cid = cluster_id(cell_cx(gx), cell_cz(gz));
		if (cidx != start_idx && cidx != end_idx) {
			if (!macro_allowed(cid)) return false;
			if (cluster_blocked(cid)) return false;
		}
		return nav_map_->get_distance(
			min_x_ + (static_cast<float>(gx) + 0.5f) * cell_size_,
			min_z_ + (static_cast<float>(gz) + 0.5f) * cell_size_) >= q_cl;
	};
	auto line_allowed = [&](int x0, int z0, int x1, int z1) -> bool {
		int dx = std::abs(x1 - x0);
		int dz = std::abs(z1 - z0);
		int step_x_dir = (x0 < x1) ? 1 : -1;
		int step_z_dir = (z0 < z1) ? 1 : -1;
		int cx = x0;
		int cz = z0;
		if (!cell_allowed(cx, cz)) return false;
		if (dx == 0 && dz == 0) return true;
		int err = dx - dz;
		while (!(cx == x1 && cz == z1)) {
			int e2 = 2 * err;
			bool step_x = (e2 > -dz) || (e2 == -dz && dx > 0);
			bool step_z = (e2 < dx)  || (e2 == dx  && dz > 0);
			if (step_x && step_z) {
				if (!cell_allowed(cx + step_x_dir, cz)) return false;
				if (!cell_allowed(cx, cz + step_z_dir)) return false;
				err -= dz;
				err += dx;
				cx += step_x_dir;
				cz += step_z_dir;
			} else if (step_x) {
				err -= dz;
				cx += step_x_dir;
			} else {
				err += dx;
				cz += step_z_dir;
			}
			if (!cell_allowed(cx, cz)) return false;
		}
		return true;
	};

	if (!cell_allowed(sx, sz) || !cell_allowed(ex, ez)) return result;

	if (sx == ex && sz == ez) {
		result.waypoints = { from, to };
		result.flags = { WP_NONE, WP_NONE };
		result.total_distance = from.distance_to(to);
		result.valid = true;
		return result;
	}

	if (line_allowed(sx, sz, ex, ez)) {
		result.waypoints = { from, to };
		result.flags = { WP_NONE, WP_NONE };
		result.total_distance = from.distance_to(to);
		result.valid = true;
		return result;
	}

	const int total = grid_w_ * grid_h_;
	const float INF = std::numeric_limits<float>::infinity();
	std::vector<float> g(total, INF);
	std::vector<int> parent(total, -1);
	std::vector<uint8_t> closed(total, 0);

	auto heur = [&](int gx, int gz) -> float {
		float dx = static_cast<float>(gx - ex);
		float dz = static_cast<float>(gz - ez);
		return std::sqrt(dx * dx + dz * dz);
	};

	using PQ = std::pair<float, int>;
	std::priority_queue<PQ, std::vector<PQ>, std::greater<PQ>> open;
	g[start_idx] = 0.0f;
	parent[start_idx] = start_idx;
	open.push({ heur(sx, sz), start_idx });

	const int dx8[] = {-1, 0, 1, -1, 1, -1, 0, 1};
	const int dz8[] = {-1, -1, -1, 0, 0, 1, 1, 1};

	while (!open.empty()) {
		auto [f, cur] = open.top(); open.pop();
		if (closed[cur]) continue;
		closed[cur] = 1;
		if (cur == end_idx) break;

		int cx = cur % grid_w_;
		int cz = cur / grid_w_;

		for (int d = 0; d < 8; ++d) {
			int nx = cx + dx8[d];
			int nz = cz + dz8[d];
			if (!cell_allowed(nx, nz)) continue;
			int nidx = idx(nx, nz);
			if (closed[nidx]) continue;

			bool is_diag = (dx8[d] != 0 && dz8[d] != 0);
			if (is_diag) {
				if (!cell_allowed(cx + dx8[d], cz)) continue;
				if (!cell_allowed(cx, cz + dz8[d])) continue;
			}

			float step_cost = is_diag ? 1.41421356237f : 1.0f;
			float ng = g[cur] + step_cost;
			if (ng < g[nidx]) {
				g[nidx] = ng;
				parent[nidx] = cur;
				open.push({ ng + heur(nx, nz), nidx });
			}
		}
	}

	if (parent[end_idx] < 0) return result;

	std::vector<Vector2> raw;
	for (int cur = end_idx; cur != start_idx; cur = parent[cur]) {
		int gx = cur % grid_w_;
		int gz = cur / grid_w_;
		float wx, wz;
		grid_to_world(gx, gz, wx, wz);
		raw.emplace_back(wx, wz);
		if (parent[cur] < 0 || parent[cur] == cur) return result;
	}
	raw.push_back(from);
	std::reverse(raw.begin(), raw.end());
	if (raw.size() >= 2) raw.back() = to;

	std::vector<Vector2> simplified;
	simplified.push_back(raw.front());
	size_t anchor = 0;
	while (anchor < raw.size() - 1) {
		size_t farthest = anchor + 1;
		for (size_t test = raw.size() - 1; test > anchor + 1; --test) {
			int ax = world_to_gx(raw[anchor].x), az = world_to_gz(raw[anchor].y);
			int bx = world_to_gx(raw[test].x),   bz = world_to_gz(raw[test].y);
			if (line_allowed(ax, az, bx, bz)) {
				farthest = test;
				break;
			}
		}
		simplified.push_back(raw[farthest]);
		anchor = farthest;
	}

	result.waypoints = simplified;
	result.flags.assign(simplified.size(), WP_NONE);
	for (size_t i = 0; i + 1 < simplified.size(); ++i)
		result.total_distance += simplified[i].distance_to(simplified[i + 1]);
	result.valid = (simplified.size() >= 2);
	return result;
}

// ============================================================================
// find_path
// ============================================================================

PathResult HpaGraph::find_path(Vector2 from, Vector2 to, float query_clearance) const {
	using Clock = std::chrono::steady_clock;
	auto query_t0 = Clock::now();

	// Timing buckets (kept for perf metrics compatibility).
	float connect_us   = 0.0f;   // guide-point LOS / local A* time
	float abstract_us  = 0.0f;   // cluster A* time
	float refine_us    = 0.0f;   // path assembly + string-pull time
	float start_connect_us = 0.0f;
	float goal_connect_us  = 0.0f;

	// Repurposed counters (names kept for GDScript perf-metrics compat).
	int connector_los_attempts      = 0;  // total LOS checks
	int connector_los_hits          = 0;  // LOS checks that passed
	int connector_local_search_runs = 0;  // local A* calls
	int connector_local_expansions  = 0;  // unused
	int connector_portal_candidates = 0;  // unused

	PathResult no_path;
	no_path.valid          = false;
	no_path.total_distance = 0.0f;

	// ── Performance tracking lambda (unchanged from original) ──────────────
	auto finalize_query = [&](PathResult r) -> PathResult {
		if (!perf_tracking_enabled_) return r;

		auto query_t1 = Clock::now();
		float total_us = std::chrono::duration<float, std::micro>(query_t1 - query_t0).count();

		perf_.query_count++;
		if (r.valid) perf_.success_count++;
		else         perf_.failure_count++;

		perf_.last_total_us         = total_us;
		perf_.last_connect_us       = connect_us;
		perf_.last_abstract_us      = abstract_us;
		perf_.last_refine_us        = refine_us;
		perf_.last_start_connect_us = start_connect_us;
		perf_.last_goal_connect_us  = goal_connect_us;

		perf_.last_connector_los_attempts      = connector_los_attempts;
		perf_.last_connector_los_hits          = connector_los_hits;
		perf_.last_connector_local_search_runs = connector_local_search_runs;
		perf_.last_connector_local_expansions  = connector_local_expansions;
		perf_.last_connector_portal_candidates = connector_portal_candidates;

		auto update_ema = [&](float &ema, float sample) {
			if (perf_.query_count <= 1) ema = sample;
			else ema = ema * 0.9f + sample * 0.1f;
		};
		update_ema(perf_.avg_total_us,    total_us);
		update_ema(perf_.avg_connect_us,  connect_us);
		update_ema(perf_.avg_abstract_us, abstract_us);
		update_ema(perf_.avg_refine_us,   refine_us);
		update_ema(perf_.avg_connector_los_attempts,      static_cast<float>(connector_los_attempts));
		update_ema(perf_.avg_connector_los_hits,          static_cast<float>(connector_los_hits));
		update_ema(perf_.avg_connector_local_search_runs, static_cast<float>(connector_local_search_runs));
		update_ema(perf_.avg_connector_local_expansions,  static_cast<float>(connector_local_expansions));
		update_ema(perf_.avg_connector_portal_candidates, static_cast<float>(connector_portal_candidates));

		perf_.max_total_us    = std::max(perf_.max_total_us,    total_us);
		perf_.max_connect_us  = std::max(perf_.max_connect_us,  connect_us);
		perf_.max_abstract_us = std::max(perf_.max_abstract_us, abstract_us);
		perf_.max_refine_us   = std::max(perf_.max_refine_us,   refine_us);

		perf_.window_queries++;
		perf_.window_total_sum_us   += total_us;
		perf_.window_connect_sum_us += connect_us;
		perf_.window_abstract_sum_us += abstract_us;
		perf_.window_refine_sum_us  += refine_us;

		if (total_us >= perf_.spike_threshold_us) {
			perf_.spike_count++;
			perf_.worst_spike_us = std::max(perf_.worst_spike_us, total_us);
			UtilityFunctions::print(
				"[HpaGraph][SPIKE] total_us=", total_us,
				" abstract_us=", abstract_us,
				" refine_us=", refine_us,
				" los=", connector_los_hits, "/", connector_los_attempts,
				" local_paths=", connector_local_search_runs,
				" spikes=", static_cast<int64_t>(perf_.spike_count));
		}

		uint64_t now_wall_us = static_cast<uint64_t>(
			std::chrono::duration_cast<std::chrono::microseconds>(
				query_t1.time_since_epoch()).count());
		if (perf_.last_report_wall_us == 0) perf_.last_report_wall_us = now_wall_us;

		uint64_t report_interval_us = static_cast<uint64_t>(perf_.report_interval_s * 1000000.0f);
		if (report_interval_us == 0) report_interval_us = 5000000;

		if (now_wall_us - perf_.last_report_wall_us >= report_interval_us) {
			float inv = (perf_.window_queries > 0)
				? (1.0f / static_cast<float>(perf_.window_queries)) : 0.0f;
			float elapsed_s = static_cast<float>(now_wall_us - perf_.last_report_wall_us) / 1000000.0f;
			if (elapsed_s <= 0.0f) elapsed_s = perf_.report_interval_s;
			float qps = static_cast<float>(perf_.window_queries) / elapsed_s;
			UtilityFunctions::print(
				"[HpaGraph][AVG 5s] queries=", static_cast<int64_t>(perf_.window_queries),
				" qps=", qps,
				" avg_total_us=",    perf_.window_total_sum_us   * inv,
				" avg_abstract_us=", perf_.window_abstract_sum_us * inv,
				" avg_refine_us=",   perf_.window_refine_sum_us  * inv,
				" max_total_us=", perf_.max_total_us,
				" spike_count=", static_cast<int64_t>(perf_.spike_count));
			perf_.window_queries         = 0;
			perf_.window_total_sum_us    = 0.0f;
			perf_.window_connect_sum_us  = 0.0f;
			perf_.window_abstract_sum_us = 0.0f;
			perf_.window_refine_sum_us   = 0.0f;
			perf_.last_report_wall_us    = now_wall_us;
		}
		return r;
	};

	if (!built_) return finalize_query(no_path);

	// ── Query clearance ────────────────────────────────────────────────────
	// Use the ship's actual clearance (ship_length/2 + ship_beam) when
	// provided; fall back to the build-time default otherwise.
	float q_cl = (query_clearance > 0.0f) ? query_clearance : clearance_;

	// ── Grid coordinate helpers ────────────────────────────────────────────
	auto world_to_gx = [&](float wx) -> int {
		return std::max(0, std::min(static_cast<int>((wx - min_x_) / cell_size_), grid_w_ - 1));
	};
	auto world_to_gz = [&](float wz) -> int {
		return std::max(0, std::min(static_cast<int>((wz - min_z_) / cell_size_), grid_h_ - 1));
	};

	int from_gx = world_to_gx(from.x), from_gz = world_to_gz(from.y);
	int to_gx   = world_to_gx(to.x),   to_gz   = world_to_gz(to.y);

	int from_cid = cluster_id(cell_cx(from_gx), cell_cz(from_gz));
	int to_cid   = cluster_id(cell_cx(to_gx),   cell_cz(to_gz));

	// ── Threat layer ───────────────────────────────────────────────────────
	bool threat_layer_active = (threat_blocked_count_ > 0);

	// Reject a LOS segment that clips any threat-blocked cluster AABB.
	// Iterates the compact threat_blocked_cids_ list rather than every cluster.
	auto threat_clear = [&](const Vector2 &a, const Vector2 &b) -> bool {
		if (!threat_layer_active) return true;
		const float hc = cell_size_ * 0.5f;
		for (int cid : threat_blocked_cids_) {
			const Cluster &cl = clusters_[cid];
			float wx0, wz0, wx1, wz1;
			grid_to_world(cl.x0, cl.z0, wx0, wz0);
			grid_to_world(cl.x1, cl.z1, wx1, wz1);
			if (segment_clips_aabb(a.x, a.y, b.x, b.y,
			                       wx0 - hc, wz0 - hc, wx1 + hc, wz1 + hc))
				return false;
		}
		return true;
	};

	// ── Step 1: Direct LOS shortcut ────────────────────────────────────────
	connector_los_attempts++;
	if (nav_map_->line_of_sight(from_gx, from_gz, to_gx, to_gz, q_cl) &&
		threat_clear(from, to)) {
		connector_los_hits++;
		PathResult r;
		r.waypoints      = { from, to };
		r.flags          = { WP_NONE, WP_NONE };
		r.total_distance = from.distance_to(to);
		r.valid          = true;
		return finalize_query(r);
	}

	// ── Step 2: Build guide-point sequence ─────────────────────────────────────
	// Two cases:
	//   (a) Same macro      → sub A* within from_cid produces the guide.
	//   (b) Cross macro     → macro A* produces a corridor; per-macro sub
	//                         picking refines the guide.
	// Either way the result is a `guide` vector ending in `to`, fed to a
	// unified Step 5 connector below.
	//
	// Open-cell rule (mirrors macro behaviour for subs):
	//   is_sub_open(sid)  := sub_clusters_[sid].min_sdf >= q_cl   (fully safe)
	//   is_cluster_open   := analogous, at macro layer
	// Only "open" intermediate centres are emitted as guides; coastal/terrain
	// stretches are bridged by LOS / sub A* / cell A* in the connector.

	auto is_cluster_open = [&](int cid) -> bool {
		return cid >= 0 &&
		       cid < static_cast<int>(clusters_.size()) &&
		       clusters_[cid].min_sdf >= q_cl;
	};
	auto is_sub_open = [&](int sid) -> bool {
		return sid >= 0 &&
		       sid < static_cast<int>(sub_clusters_.size()) &&
		       sub_clusters_[sid].min_sdf >= q_cl;
	};

	int from_sid = sub_id(cell_scx(from_gx), cell_scz(from_gz));
	int to_sid   = sub_id(cell_scx(to_gx),   cell_scz(to_gz));

	std::vector<Vector2> guide;
	guide.reserve(8);
	guide.push_back(from);

	// allowed_macros: per-macro 0/1 mask used by sub_cluster_astar() to
	// constrain corridor searches.  Sized once and shared between the
	// same-macro fast path and the per-pair connector below.
	std::vector<uint8_t> allowed_macros(clusters_.size(), 0);

	if (from_cid == to_cid) {
		// (a) Same macro — sub A* over this single macro, no corridor needed.
		allowed_macros[from_cid] = 1;

		if (from_sid != to_sid) {
			auto t_abs0 = Clock::now();
			std::vector<int> sub_path = sub_cluster_astar(
				from_sid, to_sid, q_cl, &allowed_macros);
			auto t_abs1 = Clock::now();
			abstract_us += std::chrono::duration<float, std::micro>(t_abs1 - t_abs0).count();

			if (sub_path.empty()) {
				auto t0 = Clock::now();
				PathResult local = constrained_cell_astar(from, to, q_cl, allowed_macros);
				auto t1 = Clock::now();
				refine_us = std::chrono::duration<float, std::micro>(t1 - t0).count();
				connector_local_search_runs++;
				return finalize_query(local);
			}

			for (int i = 1; i + 1 < static_cast<int>(sub_path.size()); ++i) {
				int sid = sub_path[i];
				if (is_sub_open(sid))
					guide.emplace_back(sub_clusters_[sid].wx_center,
					                   sub_clusters_[sid].wz_center);
			}
		}
		guide.push_back(to);
	} else {
		// (b) Cross macro — macro A* then sub-aware guide selection.
		auto t_abs0 = Clock::now();
		std::vector<int> cluster_path = cluster_astar(from_cid, to_cid, q_cl);
		auto t_abs1 = Clock::now();
		abstract_us = std::chrono::duration<float, std::micro>(t_abs1 - t_abs0).count();

		if (cluster_path.empty()) return finalize_query(no_path);

		// Corridor mask: every macro on the abstract path plus its 8 neighbours.
		// Gives the per-pair sub A* room to detour around in-corridor terrain
		// without ballooning into a global search.
		for (int cid : cluster_path) {
			const Cluster &cc = clusters_[cid];
			for (int dz = -1; dz <= 1; ++dz) {
				for (int dx = -1; dx <= 1; ++dx) {
					int nx = cc.cx + dx;
					int nz = cc.cz + dz;
					if (nx < 0 || nx >= ncx_ || nz < 0 || nz >= ncz_) continue;
					allowed_macros[cluster_id(nx, nz)] = 1;
				}
			}
		}

		// Pick the open sub-cluster inside `cid` whose centre is closest to
		// the chord prev_g → next_g.  Returns -1 if no open sub exists.
		auto best_open_sub_near_chord = [&](int cid,
		                                     const Vector2 &prev_g,
		                                     const Vector2 &next_g) -> int {
			const Cluster &c = clusters_[cid];
			int best = -1;
			float best_d2 = std::numeric_limits<float>::infinity();
			Vector2 dir = next_g - prev_g;
			float L2 = dir.x * dir.x + dir.y * dir.y;
			for (int scz = c.sub_z0; scz <= c.sub_z1; ++scz) {
				for (int scx = c.sub_x0; scx <= c.sub_x1; ++scx) {
					if (scx >= nsubx_ || scz >= nsubz_) continue;
					int sid = sub_id(scx, scz);
					if (!is_sub_open(sid)) continue;
					const SubCluster &s = sub_clusters_[sid];
					Vector2 p(s.wx_center, s.wz_center);
					float d2;
					if (L2 > 1e-6f) {
						Vector2 dp = p - prev_g;
						float t = (dp.x * dir.x + dp.y * dir.y) / L2;
						Vector2 proj = prev_g + dir * t;
						Vector2 e = p - proj;
						d2 = e.x * e.x + e.y * e.y;
					} else {
						Vector2 e = p - prev_g;
						d2 = e.x * e.x + e.y * e.y;
					}
					if (d2 < best_d2) { best_d2 = d2; best = sid; }
				}
			}
			return best;
		};

		for (int i = 1; i + 1 < static_cast<int>(cluster_path.size()); ++i) {
			int cid = cluster_path[i];
			if (is_cluster_open(cid)) {
				guide.emplace_back(clusters_[cid].wx_center, clusters_[cid].wz_center);
			} else {
				// Partly-coastal macro — promote its best open sub to a guide
				// rather than skipping it (current behaviour).  If no sub is
				// open, fall back to skipping; the connector will bridge it.
				Vector2 prev_g = guide.back();
				Vector2 next_g;
				if (i + 1 < static_cast<int>(cluster_path.size())) {
					int ncid = cluster_path[i + 1];
					next_g = Vector2(clusters_[ncid].wx_center, clusters_[ncid].wz_center);
				} else {
					next_g = to;
				}
				int best_sid = best_open_sub_near_chord(cid, prev_g, next_g);
				if (best_sid >= 0) {
					const SubCluster &s = sub_clusters_[best_sid];
					guide.emplace_back(s.wx_center, s.wz_center);
				}
			}
		}
		guide.push_back(to);
	}

	// ── Step 5: Connect guide points ─────────────────────────────────────────
	// Per consecutive (A,B) pair:
	//   1. LOS at q_cl (+ threat) — cheapest.
	//   2. Sub A* in the corridor; emit its open intermediate sub centres.
	//   3. Cell A* (NavigationMap::find_path_internal) — last resort, used
	//      mostly when the route threads near terrain.
	auto t_ref0 = Clock::now();

	std::vector<Vector2> waypoints;
	waypoints.reserve(guide.size() * 4);
	waypoints.push_back(guide[0]);

	const float merge_eps = cell_size_ * 0.1f;

	for (int i = 1; i < static_cast<int>(guide.size()); ++i) {
		const Vector2 &A = waypoints.back();
		const Vector2 &B = guide[i];

		int ax = world_to_gx(A.x), az = world_to_gz(A.y);
		int bx = world_to_gx(B.x), bz = world_to_gz(B.y);

		connector_los_attempts++;
		bool los_ok = nav_map_->line_of_sight(ax, az, bx, bz, q_cl);
		if (los_ok && threat_layer_active) los_ok = threat_clear(A, B);

		if (los_ok) {
			connector_los_hits++;
			waypoints.push_back(B);
			continue;
		}

		// LOS failed — try sub A* across the corridor.
		int a_sid = sub_id(cell_scx(ax), cell_scz(az));
		int b_sid = sub_id(cell_scx(bx), cell_scz(bz));
		bool sub_helped = false;

		if (a_sid != b_sid) {
			std::vector<int> sub_path =
				sub_cluster_astar(a_sid, b_sid, q_cl, &allowed_macros);

			// Count open intermediates — only worth using if the sub layer
			// produced at least one open detour point; otherwise the route
			// is genuinely terrain-threading and cell A* is the right tool.
			int open_intermediates = 0;
			for (int j = 1; j + 1 < static_cast<int>(sub_path.size()); ++j)
				if (is_sub_open(sub_path[j])) ++open_intermediates;

			if (!sub_path.empty() && open_intermediates > 0) {
				for (int j = 1; j + 1 < static_cast<int>(sub_path.size()); ++j) {
					int sid = sub_path[j];
					if (!is_sub_open(sid)) continue;
					const SubCluster &s = sub_clusters_[sid];
					Vector2 P(s.wx_center, s.wz_center);
					if (waypoints.back().distance_to(P) > merge_eps)
						waypoints.push_back(P);
				}
				if (waypoints.back().distance_to(B) > merge_eps)
					waypoints.push_back(B);
				sub_helped = true;
			}
		}

		if (sub_helped) continue;

		// Sub A* couldn't help — run cell A* constrained to the HPA corridor.
		connector_local_search_runs++;
		PathResult local = constrained_cell_astar(A, B, q_cl, allowed_macros);
		if (local.valid && local.waypoints.size() >= 2) {
			for (int j = 1; j < static_cast<int>(local.waypoints.size()); ++j) {
				if (waypoints.back().distance_to(local.waypoints[j]) > merge_eps)
					waypoints.push_back(local.waypoints[j]);
			}
		} else {
			return finalize_query(no_path);
		}
	}

	// Snap the exact destination.
	if (!waypoints.empty()) {
		if (waypoints.back().distance_to(to) < merge_eps)
			waypoints.back() = to;
		else if (waypoints.back().distance_to(to) > merge_eps)
			waypoints.push_back(to);
	}

	// ── Step 6: String pulling ─────────────────────────────────────────────
	// Greedy forward LOS simplification using the ship's actual clearance.
	std::vector<Vector2> pulled;
	pulled.push_back(waypoints.front());

	size_t anchor = 0;
	while (anchor < waypoints.size() - 1) {
		size_t farthest = anchor + 1;
		for (size_t test = waypoints.size() - 1; test > anchor + 1; --test) {
			int ax = world_to_gx(waypoints[anchor].x), az = world_to_gz(waypoints[anchor].y);
			int bx = world_to_gx(waypoints[test].x),   bz = world_to_gz(waypoints[test].y);
			if (nav_map_->line_of_sight(ax, az, bx, bz, q_cl) &&
				threat_clear(waypoints[anchor], waypoints[test])) {
				farthest = test;
				break;
			}
		}
		pulled.push_back(waypoints[farthest]);
		anchor = farthest;
	}

	auto t_ref1 = Clock::now();
	refine_us = std::chrono::duration<float, std::micro>(t_ref1 - t_ref0).count();

	connect_us = start_connect_us + goal_connect_us; // 0 in new design

	// ── Step 7: Package result ─────────────────────────────────────────────
	if (pulled.size() < 2) return finalize_query(no_path);

	PathResult result;
	result.waypoints = pulled;
	result.flags.assign(pulled.size(), WP_NONE);
	for (size_t i = 0; i + 1 < pulled.size(); ++i)
		result.total_distance += pulled[i].distance_to(pulled[i + 1]);
	result.valid = true;

	return finalize_query(result);
}

// ============================================================================
// find_path_packed
// ============================================================================

PackedVector2Array HpaGraph::find_path_packed(Vector2 from, Vector2 to,
                                               float query_clearance) const {
	PathResult pr = find_path(from, to, query_clearance);
	PackedVector2Array out;
	for (const Vector2 &wp : pr.waypoints)
		out.push_back(wp);
	return out;
}

// ============================================================================
// Debug helpers
// ============================================================================

// get_debug_nodes — returns cluster centres (the "nodes" in the new design).
TypedArray<Dictionary> HpaGraph::get_debug_nodes() const {
	TypedArray<Dictionary> out;
	for (const Cluster &c : clusters_) {
		Dictionary d;
		d["id"]         = c.id;
		d["cluster_id"] = c.id;
		d["position"]   = Vector2(c.wx_center, c.wz_center);
		d["max_sdf"]    = c.max_sdf;
		d["min_sdf"]    = c.min_sdf;
		out.push_back(d);
	}
	return out;
}

// get_debug_edges — returns cluster adjacency edges (4-cardinal only for clarity).
TypedArray<Dictionary> HpaGraph::get_debug_edges() const {
	TypedArray<Dictionary> out;
	for (const Cluster &c : clusters_) {
		// Right and down neighbours only to avoid duplicate pairs.
		const int dirs[2][2] = { {1, 0}, {0, 1} };
		for (auto &d : dirs) {
			int ncx = c.cx + d[0];
			int ncz = c.cz + d[1];
			if (ncx >= ncx_ || ncz >= ncz_) continue;
			int ncid = cluster_id(ncx, ncz);
			Dictionary entry;
			entry["from"]     = c.id;
			entry["to"]       = ncid;
			entry["from_pos"] = Vector2(c.wx_center, c.wz_center);
			entry["to_pos"]   = Vector2(clusters_[ncid].wx_center, clusters_[ncid].wz_center);
			entry["cost"]     = Vector2(c.wx_center, c.wz_center)
			                        .distance_to(Vector2(clusters_[ncid].wx_center,
			                                             clusters_[ncid].wz_center));
			out.push_back(entry);
		}
	}
	return out;
}

TypedArray<Dictionary> HpaGraph::get_debug_clusters() const {
	TypedArray<Dictionary> out;
	for (const Cluster &c : clusters_) {
		Dictionary d;
		float wx0, wz0, wx1, wz1;
		grid_to_world(c.x0, c.z0, wx0, wz0);
		grid_to_world(c.x1, c.z1, wx1, wz1);
		float hc = cell_size_ * 0.5f;
		d["id"]        = c.id;
		d["x0"]        = wx0 - hc;
		d["z0"]        = wz0 - hc;
		d["x1"]        = wx1 + hc;
		d["z1"]        = wz1 + hc;
		d["navigable"] = c.navigable;
		d["max_sdf"]   = c.max_sdf;
		d["min_sdf"]   = c.min_sdf;
		d["center"]    = Vector2(c.wx_center, c.wz_center);
		out.push_back(d);
	}
	return out;
}

TypedArray<Dictionary> HpaGraph::get_debug_sub_clusters() const {
	TypedArray<Dictionary> out;
	for (const SubCluster &s : sub_clusters_) {
		Dictionary d;
		float wx0, wz0, wx1, wz1;
		grid_to_world(s.x0, s.z0, wx0, wz0);
		grid_to_world(s.x1, s.z1, wx1, wz1);
		float hc = cell_size_ * 0.5f;
		d["id"]         = s.id;
		d["parent_cid"] = s.parent_cid;
		d["x0"]         = wx0 - hc;
		d["z0"]         = wz0 - hc;
		d["x1"]         = wx1 + hc;
		d["z1"]         = wz1 + hc;
		d["navigable"]  = s.navigable;
		d["max_sdf"]    = s.max_sdf;
		d["min_sdf"]    = s.min_sdf;
		d["center"]     = Vector2(s.wx_center, s.wz_center);
		out.push_back(d);
	}
	return out;
}

// ============================================================================
// get_perf_metrics
// ============================================================================

Dictionary HpaGraph::get_perf_metrics() const {
	Dictionary d;
	d["query_count"]   = static_cast<int64_t>(perf_.query_count);
	d["success_count"] = static_cast<int64_t>(perf_.success_count);
	d["failure_count"] = static_cast<int64_t>(perf_.failure_count);

	d["last_total_us"]        = perf_.last_total_us;
	d["last_connect_us"]      = perf_.last_connect_us;
	d["last_abstract_us"]     = perf_.last_abstract_us;
	d["last_refine_us"]       = perf_.last_refine_us;
	d["last_start_connect_us"] = perf_.last_start_connect_us;
	d["last_goal_connect_us"]  = perf_.last_goal_connect_us;

	d["avg_total_us"]    = perf_.avg_total_us;
	d["avg_connect_us"]  = perf_.avg_connect_us;
	d["avg_abstract_us"] = perf_.avg_abstract_us;
	d["avg_refine_us"]   = perf_.avg_refine_us;

	d["max_total_us"]    = perf_.max_total_us;
	d["max_connect_us"]  = perf_.max_connect_us;
	d["max_abstract_us"] = perf_.max_abstract_us;
	d["max_refine_us"]   = perf_.max_refine_us;

	d["last_connector_los_attempts"]       = perf_.last_connector_los_attempts;
	d["last_connector_los_hits"]           = perf_.last_connector_los_hits;
	d["last_connector_local_search_runs"]  = perf_.last_connector_local_search_runs;
	d["last_connector_local_expansions"]   = perf_.last_connector_local_expansions;
	d["last_connector_portal_candidates"]  = perf_.last_connector_portal_candidates;

	d["avg_connector_los_attempts"]       = perf_.avg_connector_los_attempts;
	d["avg_connector_los_hits"]           = perf_.avg_connector_los_hits;
	d["avg_connector_local_search_runs"]  = perf_.avg_connector_local_search_runs;
	d["avg_connector_local_expansions"]   = perf_.avg_connector_local_expansions;
	d["avg_connector_portal_candidates"]  = perf_.avg_connector_portal_candidates;

	d["spike_threshold_us"] = perf_.spike_threshold_us;
	d["spike_count"]        = static_cast<int64_t>(perf_.spike_count);
	d["worst_spike_us"]     = perf_.worst_spike_us;

	float inv = (perf_.window_queries > 0)
		? (1.0f / static_cast<float>(perf_.window_queries)) : 0.0f;
	if (inv > 0.0f) {
		d["window_avg_total_us"]    = perf_.window_total_sum_us    * inv;
		d["window_avg_connect_us"]  = perf_.window_connect_sum_us  * inv;
		d["window_avg_abstract_us"] = perf_.window_abstract_sum_us * inv;
		d["window_avg_refine_us"]   = perf_.window_refine_sum_us   * inv;
	} else {
		d["window_avg_total_us"]    = 0.0f;
		d["window_avg_connect_us"]  = 0.0f;
		d["window_avg_abstract_us"] = 0.0f;
		d["window_avg_refine_us"]   = 0.0f;
	}
	return d;
}

void HpaGraph::reset_perf_metrics() {
	float threshold      = perf_.spike_threshold_us;
	float report_interval = perf_.report_interval_s;
	perf_ = PerfStats();
	perf_.spike_threshold_us = threshold;
	perf_.report_interval_s  = report_interval;
}

void HpaGraph::set_perf_spike_threshold_us(float threshold_us) {
	perf_.spike_threshold_us = std::max(0.0f, threshold_us);
}

float HpaGraph::get_perf_spike_threshold_us() const {
	return perf_.spike_threshold_us;
}

void HpaGraph::set_perf_tracking_enabled(bool enabled) {
	perf_tracking_enabled_ = enabled;
}

bool HpaGraph::is_perf_tracking_enabled() const {
	return perf_tracking_enabled_;
}

// ============================================================================
// stamp_threats / clear_threats
// ============================================================================

void HpaGraph::stamp_threats(const std::vector<ThreatCircle> &threats) {
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);
	threat_blocked_cids_.clear();
	threat_blocked_count_ = 0;
	if (threats.empty() || clusters_.empty() || !nav_map_.is_valid()) return;

	for (const ThreatCircle &t : threats) {
		if (t.radius <= 0.0f) continue;

		int gx_t = static_cast<int>((t.origin.x - min_x_) / cell_size_);
		int gz_t = static_cast<int>((t.origin.y - min_z_) / cell_size_);
		gx_t = std::max(0, std::min(gx_t, grid_w_ - 1));
		gz_t = std::max(0, std::min(gz_t, grid_h_ - 1));

		const float r2 = t.radius * t.radius;

		// Only candidate clusters whose AABB overlaps the threat circle are
		// worth testing — avoids the previous O(clusters × threats) sweep.
		std::vector<int> candidates = clusters_in_radius(t.origin, t.radius);
		for (int cid : candidates) {
			if (cluster_threat_blocked_[cid]) continue;  // already blocked by another threat
			const Cluster &c = clusters_[cid];
			if (!c.navigable) continue;

			// Grid coords of the 4 cluster corner cells.
			// Testing all corners (rather than just the centre) conservatively marks
			// clusters where the threat has line-of-sight to any part of the boundary.
			const int corner_gx[4] = { c.x0, c.x1, c.x0, c.x1 };
			const int corner_gz[4] = { c.z0, c.z0, c.z1, c.z1 };

			bool threatened = false;
			for (int i = 0; i < 4 && !threatened; ++i) {
				float wx, wz;
				grid_to_world(corner_gx[i], corner_gz[i], wx, wz);
				float dx = wx - t.origin.x;
				float dz = wz - t.origin.y;
				if (dx * dx + dz * dz > r2) continue;

				if (nav_map_->line_of_sight(corner_gx[i], corner_gz[i], gx_t, gz_t, 0.0f)) {
					threatened = true;
				}
			}

			if (threatened) {
				cluster_threat_blocked_[cid] = 1;
				threat_blocked_cids_.push_back(cid);
			}
		}
	}

	threat_blocked_count_ = static_cast<int>(threat_blocked_cids_.size());
}

void HpaGraph::clear_threats() {
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);
	threat_blocked_cids_.clear();
	threat_blocked_count_ = 0;
}

// ============================================================================
// get_debug_threat_clusters
// ============================================================================

TypedArray<Dictionary> HpaGraph::get_debug_threat_clusters() const {
	TypedArray<Dictionary> out;
	if (!built_) return out;
	for (int cid = 0; cid < static_cast<int>(clusters_.size()); ++cid) {
		if (cluster_threat_blocked_[cid] == 0) continue;
		const Cluster &cl = clusters_[cid];
		float wx0, wz0, wx1, wz1;
		grid_to_world(cl.x0, cl.z0, wx0, wz0);
		grid_to_world(cl.x1, cl.z1, wx1, wz1);
		float hc = cell_size_ * 0.5f;
		Dictionary d;
		d["x0"] = wx0 - hc;
		d["z0"] = wz0 - hc;
		d["x1"] = wx1 + hc;
		d["z1"] = wz1 + hc;
		out.push_back(d);
	}
	return out;
}

// ============================================================================
// compute_debug_threat_clusters (pure query, no side effects)
// ============================================================================

TypedArray<Dictionary> HpaGraph::compute_debug_threat_clusters(
		const std::vector<ThreatCircle> &threats) const {
	TypedArray<Dictionary> out;
	if (!built_ || threats.empty() || !nav_map_.is_valid()) return out;

	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;

		// Grid coords of the 4 cluster corner cells (mirrors stamp_threats logic).
		const int corner_gx[4] = { c.x0, c.x1, c.x0, c.x1 };
		const int corner_gz[4] = { c.z0, c.z0, c.z1, c.z1 };

		bool blocked = false;
		for (const ThreatCircle &t : threats) {
			if (t.radius <= 0.0f) continue;

			int gx_t = static_cast<int>((t.origin.x - min_x_) / cell_size_);
			int gz_t = static_cast<int>((t.origin.y - min_z_) / cell_size_);
			gx_t = std::max(0, std::min(gx_t, grid_w_ - 1));
			gz_t = std::max(0, std::min(gz_t, grid_h_ - 1));

			const float r2 = t.radius * t.radius;

			for (int i = 0; i < 4 && !blocked; ++i) {
				float wx, wz;
				grid_to_world(corner_gx[i], corner_gz[i], wx, wz);
				float dx = wx - t.origin.x;
				float dz = wz - t.origin.y;
				if (dx * dx + dz * dz > r2) continue;

				if (nav_map_->line_of_sight(corner_gx[i], corner_gz[i], gx_t, gz_t, 0.0f)) {
					blocked = true;
				}
			}

			if (blocked) break;
		}
		if (!blocked) continue;

		float wx0, wz0, wx1, wz1;
		grid_to_world(c.x0, c.z0, wx0, wz0);
		grid_to_world(c.x1, c.z1, wx1, wz1);
		float hc = cell_size_ * 0.5f;
		Dictionary d;
		d["x0"] = wx0 - hc;
		d["z0"] = wz0 - hc;
		d["x1"] = wx1 + hc;
		d["z1"] = wz1 + hc;
		out.push_back(d);
	}
	return out;
}

} // namespace godot
