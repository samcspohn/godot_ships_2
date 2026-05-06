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
	ClassDB::bind_method(D_METHOD("get_debug_nodes"), &HpaGraph::get_debug_nodes);
	ClassDB::bind_method(D_METHOD("get_debug_edges"), &HpaGraph::get_debug_edges);
	ClassDB::bind_method(D_METHOD("get_debug_clusters"), &HpaGraph::get_debug_clusters);
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
	cluster_block_count_.clear();
	cluster_threat_blocked_.clear();
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

	UtilityFunctions::print(
		"[HpaGraph] building ", ncx_, "x", ncz_,
		" clusters (", cluster_size_, " cells each) on grid ",
		grid_w_, "x", grid_h_);

	build_clusters();

	int navigable_count = 0;
	for (const Cluster &c : clusters_)
		if (c.navigable) ++navigable_count;

	UtilityFunctions::print(
		"[HpaGraph] built: ", (int)clusters_.size(), " clusters (",
		navigable_count, " navigable)");

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

				const Cluster &nc = clusters_[ncid];
				float step_dx = nc.wx_center - cc.wx_center;
				float step_dz = nc.wz_center - cc.wz_center;
				float step_cost = std::sqrt(step_dx * step_dx + step_dz * step_dz);
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
	bool threat_layer_active = false;
	for (uint8_t b : cluster_threat_blocked_)
		if (b) { threat_layer_active = true; break; }

	// Reject a LOS segment that clips any threat-blocked cluster AABB.
	auto threat_clear = [&](const Vector2 &a, const Vector2 &b) -> bool {
		if (!threat_layer_active) return true;
		for (int cid = 0; cid < static_cast<int>(clusters_.size()); ++cid) {
			if (!cluster_threat_blocked_[cid]) continue;
			const Cluster &cl = clusters_[cid];
			float wx0, wz0, wx1, wz1;
			grid_to_world(cl.x0, cl.z0, wx0, wz0);
			grid_to_world(cl.x1, cl.z1, wx1, wz1);
			float hc = cell_size_ * 0.5f;
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

	// ── Step 2: Same-cluster / short-range local pathfind ──────────────────
	if (from_cid == to_cid) {
		auto t0 = Clock::now();
		PathResult local = nav_map_->find_path_internal(from, to, q_cl);
		auto t1 = Clock::now();
		refine_us = std::chrono::duration<float, std::micro>(t1 - t0).count();
		connector_local_search_runs++;
		return finalize_query(local);
	}

	// ── Step 3: Cluster A* ─────────────────────────────────────────────────
	auto t_abs0 = Clock::now();
	std::vector<int> cluster_path = cluster_astar(from_cid, to_cid, q_cl);
	auto t_abs1 = Clock::now();
	abstract_us = std::chrono::duration<float, std::micro>(t_abs1 - t_abs0).count();

	if (cluster_path.empty()) return finalize_query(no_path);

	// ── Step 4: Build guide points ─────────────────────────────────────────
	// Use open-water cluster centres (min_sdf >= q_cl) as guide waypoints.
	// Terrain clusters (min_sdf < q_cl) are omitted; the LOS+local-A* pass
	// below naturally routes through them using the ship's real clearance.
	auto is_cluster_open = [&](int cid) -> bool {
		return cid >= 0 &&
		       cid < static_cast<int>(clusters_.size()) &&
		       clusters_[cid].min_sdf >= q_cl;
	};

	std::vector<Vector2> guide;
	guide.push_back(from);
	// Skip first (from_cid) and last (to_cid) cluster — they're covered by
	// the from/to endpoints themselves.
	for (int i = 1; i + 1 < static_cast<int>(cluster_path.size()); ++i) {
		int cid = cluster_path[i];
		if (is_cluster_open(cid)) {
			guide.emplace_back(clusters_[cid].wx_center, clusters_[cid].wz_center);
		}
	}
	guide.push_back(to);

	// ── Step 5: Connect guide points ───────────────────────────────────────
	// For each consecutive pair: straight line when LOS with q_cl is clear,
	// otherwise a local A* call using the ship's actual clearance.
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
		} else {
			// Local A* bridges the terrain with the ship's actual clearance.
			connector_local_search_runs++;
			PathResult local = nav_map_->find_path_internal(A, B, q_cl);
			if (local.valid && local.waypoints.size() >= 2) {
				for (int j = 1; j < static_cast<int>(local.waypoints.size()); ++j) {
					if (waypoints.back().distance_to(local.waypoints[j]) > merge_eps)
						waypoints.push_back(local.waypoints[j]);
				}
			} else {
				// Local pathfind failed; keep the guide point as a fallback.
				waypoints.push_back(B);
			}
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
	if (threats.empty() || clusters_.empty() || !nav_map_.is_valid()) return;

	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;

		// Grid coords of the 4 cluster corner cells.
		// Testing all corners (rather than just the centre) conservatively marks
		// clusters where the threat has line-of-sight to any part of the boundary.
		const int corner_gx[4] = { c.x0, c.x1, c.x0, c.x1 };
		const int corner_gz[4] = { c.z0, c.z0, c.z1, c.z1 };

		for (const ThreatCircle &t : threats) {
			if (t.radius <= 0.0f) continue;

			int gx_t = static_cast<int>((t.origin.x - min_x_) / cell_size_);
			int gz_t = static_cast<int>((t.origin.y - min_z_) / cell_size_);
			gx_t = std::max(0, std::min(gx_t, grid_w_ - 1));
			gz_t = std::max(0, std::min(gz_t, grid_h_ - 1));

			const float r2 = t.radius * t.radius;
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
				cluster_threat_blocked_[c.id] = 1;
				break;
			}
		}
	}
}

void HpaGraph::clear_threats() {
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);
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
