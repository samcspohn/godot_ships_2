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
		D_METHOD("find_path_packed", "from", "to"),
		&HpaGraph::find_path_packed);
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
	nodes_.clear();
	adj_.clear();
	clusters_.clear();
	cluster_block_count_.clear();
	obstacles_.clear();

	if (!map.is_valid() || !map->is_built()) {
		UtilityFunctions::print("[HpaGraph] build: NavigationMap is not built");
		return;
	}

	nav_map_     = map;
	clearance_   = clearance;
	cluster_size_ = (cluster_size > 0) ? cluster_size : DEFAULT_CLUSTER_SIZE;
	grid_w_      = map->get_grid_width();
	grid_h_      = map->get_grid_height();
	cell_size_   = map->get_cell_size_value();
	min_x_       = map->get_min_x();
	min_z_       = map->get_min_z();

	ncx_ = (grid_w_ + cluster_size_ - 1) / cluster_size_;
	ncz_ = (grid_h_ + cluster_size_ - 1) / cluster_size_;

	UtilityFunctions::print(
		"[HpaGraph] building ", ncx_, "x", ncz_,
		" clusters (", cluster_size_, " cells each) on grid ",
		grid_w_, "x", grid_h_);

	build_clusters();
	build_entrances();
	build_intracluster_edges();

	UtilityFunctions::print(
		"[HpaGraph] built: ", (int)nodes_.size(), " entrance nodes across ",
		(int)clusters_.size(), " clusters");

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
			c.navigable = false;

			// Coarse navigability: check a handful of sample cells
			int sxs[] = { c.x0, c.x1, (c.x0 + c.x1) / 2 };
			int szs[] = { c.z0, c.z1, (c.z0 + c.z1) / 2 };
			for (int si = 0; si < 3 && !c.navigable; ++si)
				for (int sj = 0; sj < 3 && !c.navigable; ++sj)
					if (cell_nav(sxs[si], szs[sj]))
						c.navigable = true;
		}
	}
}

// ============================================================================
// build_entrances
// ============================================================================

void HpaGraph::build_entrances() {
	// Helper: allocate a new AbNode in cluster cid at grid pos (gx, gz),
	// add it to nodes_ / adj_ / clusters_[cid].node_ids, return its id.
	auto make_node = [&](int gx, int gz, int cid) -> int {
		float wx, wz;
		grid_to_world(gx, gz, wx, wz);

		AbNode n;
		n.id         = static_cast<int>(nodes_.size());
		n.cluster_id = cid;
		n.gx         = gx;
		n.gz         = gz;
		n.wx         = wx;
		n.wz         = wz;

		nodes_.push_back(n);
		adj_.push_back({});
		clusters_[cid].node_ids.push_back(n.id);
		return n.id;
	};

	// Process horizontal boundaries: cluster A (cz) below cluster B (cz+1).
	// The shared border row: gz_a = clusters_[A].z1  (last row of A)
	//                        gz_b = clusters_[B].z0  (first row of B)
	for (int cz = 0; cz < ncz_ - 1; ++cz) {
		for (int cx = 0; cx < ncx_; ++cx) {
			int cid_a = cluster_id(cx, cz);
			int cid_b = cluster_id(cx, cz + 1);
			const Cluster &ca = clusters_[cid_a];
			const Cluster &cb = clusters_[cid_b];

			int gz_a = ca.z1;
			int gz_b = cb.z0;

			int run_start = -1;
			for (int gx = ca.x0; gx <= ca.x1 + 1; ++gx) {
				bool nav = (gx <= ca.x1) && cell_nav(gx, gz_a) && cell_nav(gx, gz_b);
				if (nav) {
					if (run_start < 0) run_start = gx;
				} else {
					if (run_start >= 0) {
						int mid_gx = (run_start + gx - 1) / 2;
						int na = make_node(mid_gx, gz_a, cid_a);
						int nb = make_node(mid_gx, gz_b, cid_b);
						// Trivial inter-cluster crossing edge (no cluster penalty)
						adj_[na].push_back({ nb, cell_size_, -1, {} });
						adj_[nb].push_back({ na, cell_size_, -1, {} });
						run_start = -1;
					}
				}
			}
		}
	}

	// Process vertical boundaries: cluster A (cx) left of cluster B (cx+1).
	// The shared border column: gx_a = clusters_[A].x1  (last col of A)
	//                           gx_b = clusters_[B].x0  (first col of B)
	for (int cx = 0; cx < ncx_ - 1; ++cx) {
		for (int cz = 0; cz < ncz_; ++cz) {
			int cid_a = cluster_id(cx, cz);
			int cid_b = cluster_id(cx + 1, cz);
			const Cluster &ca = clusters_[cid_a];
			const Cluster &cb = clusters_[cid_b];

			int gx_a = ca.x1;
			int gx_b = cb.x0;

			int run_start = -1;
			for (int gz = ca.z0; gz <= ca.z1 + 1; ++gz) {
				bool nav = (gz <= ca.z1) && cell_nav(gx_a, gz) && cell_nav(gx_b, gz);
				if (nav) {
					if (run_start < 0) run_start = gz;
				} else {
					if (run_start >= 0) {
						int mid_gz = (run_start + gz - 1) / 2;
						int na = make_node(gx_a, mid_gz, cid_a);
						int nb = make_node(gx_b, mid_gz, cid_b);
						adj_[na].push_back({ nb, cell_size_, -1, {} });
						adj_[nb].push_back({ na, cell_size_, -1, {} });
						run_start = -1;
					}
				}
			}
		}
	}
}

// ============================================================================
// build_intracluster_edges
// ============================================================================

void HpaGraph::build_intracluster_edges() {
	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;
		int n = static_cast<int>(c.node_ids.size());
		if (n < 2) continue;

		for (int i = 0; i < n; ++i) {
			for (int j = i + 1; j < n; ++j) {
				int na = c.node_ids[i];
				int nb = c.node_ids[j];
				const AbNode &a = nodes_[na];
				const AbNode &b = nodes_[nb];

				Vector2 pa(a.wx, a.wz);
				Vector2 pb(b.wx, b.wz);

				PathResult pr = nav_map_->find_path_internal(pa, pb, clearance_, 0.0f);
				if (!pr.valid || pr.waypoints.empty()) continue;

				float cost = pr.total_distance;
				if (cost <= 0.0f) cost = pa.distance_to(pb);

				std::vector<Vector2> wps_fwd(pr.waypoints.begin(), pr.waypoints.end());
				std::vector<Vector2> wps_rev(wps_fwd.rbegin(), wps_fwd.rend());

				adj_[na].push_back({ nb, cost, c.id, wps_fwd });
				adj_[nb].push_back({ na, cost, c.id, wps_rev });
			}
		}
	}
}

// ============================================================================
// clusters_in_radius
// ============================================================================

std::vector<int> HpaGraph::clusters_in_radius(Vector2 pos, float radius) const {
	std::vector<int> result;
	if (clusters_.empty()) return result;

	// World AABB of the circle
	float wx0 = pos.x - radius;
	float wx1 = pos.x + radius;
	float wz0 = pos.y - radius;
	float wz1 = pos.y + radius;

	// Convert to cluster grid range (one cluster = cluster_size_ * cell_size_ world units)
	float cluster_world = static_cast<float>(cluster_size_) * cell_size_;

	int cx0 = static_cast<int>((wx0 - min_x_) / cluster_world);
	int cx1 = static_cast<int>((wx1 - min_x_) / cluster_world);
	int cz0 = static_cast<int>((wz0 - min_z_) / cluster_world);
	int cz1 = static_cast<int>((wz1 - min_z_) / cluster_world);

	cx0 = std::max(0, cx0);
	cx1 = std::min(ncx_ - 1, cx1);
	cz0 = std::max(0, cz0);
	cz1 = std::min(ncz_ - 1, cz1);

	for (int cz = cz0; cz <= cz1; ++cz) {
		for (int cx = cx0; cx <= cx1; ++cx) {
			result.push_back(cluster_id(cx, cz));
		}
	}
	return result;
}

// ============================================================================
// add_obstacle / remove_obstacle / clear_obstacles
// ============================================================================

void HpaGraph::add_obstacle(int id, Vector2 pos, float radius) {
	// Remove any existing registration for this id first
	remove_obstacle(id);

	HpaObstacle obs{ id, pos, radius };
	std::vector<int> cids = clusters_in_radius(pos, radius);
	for (int cid : cids) {
		cluster_block_count_[cid]++;
	}
	obs.radius = radius; // already set above, explicit for clarity
	obstacles_[id] = obs;

	// Store the affected cluster ids alongside the obstacle record
	// by re-using the HpaObstacle struct.  We need to record which
	// clusters were incremented so we can decrement the right ones on
	// removal.  Extend the pattern: store clusters in the map.
	// Since HpaObstacle doesn't carry a cluster list, we use a second map.
	// (Simpler: just recompute on removal — cheap since radius is stored.)
}

void HpaGraph::remove_obstacle(int id) {
	auto it = obstacles_.find(id);
	if (it == obstacles_.end()) return;

	const HpaObstacle &obs = it->second;
	std::vector<int> cids = clusters_in_radius(obs.pos, obs.radius);
	for (int cid : cids) {
		if (cid >= 0 && cid < (int)cluster_block_count_.size()) {
			cluster_block_count_[cid] = std::max(0, cluster_block_count_[cid] - 1);
		}
	}
	obstacles_.erase(it);
}

void HpaGraph::clear_obstacles() {
	std::fill(cluster_block_count_.begin(), cluster_block_count_.end(), 0);
	obstacles_.clear();
}

// ============================================================================
// abstract_astar_impl
// ============================================================================

std::vector<int> HpaGraph::abstract_astar_impl(
		const std::vector<AbNode>               &nodes,
		const std::vector<std::vector<AbEdge>>  &adj,
		int start,
		int goal) const
{
	const int N = static_cast<int>(nodes.size());
	if (start < 0 || start >= N || goal < 0 || goal >= N) return {};

	const float INF = std::numeric_limits<float>::infinity();

	std::vector<float> g(N, INF);
	std::vector<int>   parent(N, -1);
	std::vector<bool>  closed(N, false);

	const AbNode &goal_node = nodes[goal];

	auto heur = [&](int id) -> float {
		float dx = nodes[id].wx - goal_node.wx;
		float dz = nodes[id].wz - goal_node.wz;
		return std::sqrt(dx * dx + dz * dz);
	};

	using PQ = std::pair<float, int>;
	std::priority_queue<PQ, std::vector<PQ>, std::greater<PQ>> open;

	g[start] = 0.0f;
	open.push({ heur(start), start });

	while (!open.empty()) {
		auto [f, ci] = open.top();
		open.pop();

		if (closed[ci]) continue;
		closed[ci] = true;

		if (ci == goal) {
			// Reconstruct path start → goal
			std::vector<int> path;
			for (int cur = goal; cur != -1; ) {
				path.push_back(cur);
				if (cur == start) break;
				cur = parent[cur];
			}
			std::reverse(path.begin(), path.end());
			// Validate: must start with 'start'
			if (path.empty() || path.front() != start) return {};
			return path;
		}

		if (ci >= (int)adj.size()) continue;

		float cg = g[ci];
		for (const AbEdge &e : adj[ci]) {
			int to = e.to;
			if (to < 0 || to >= N) continue;
			if (closed[to]) continue;

			// Skip intra-cluster edges through blocked clusters
			if (e.via_cluster >= 0 && cluster_blocked(e.via_cluster)) continue;

			float ng = cg + e.cost;
			if (ng < g[to]) {
				g[to]      = ng;
				parent[to] = ci;
				open.push({ ng + heur(to), to });
			}
		}
	}

	return {}; // no path
}

// ============================================================================
// refine_path_impl
// ============================================================================

PathResult HpaGraph::refine_path_impl(
		const std::vector<int>                  &abs_path,
		const std::vector<AbNode>               &nodes,
		const std::vector<std::vector<AbEdge>>  &adj,
		Vector2 from,
		Vector2 to) const
{
	PathResult result;
	result.valid          = false;
	result.total_distance = 0.0f;

	if (abs_path.size() < 2) return result;

	// ── Step 1: Assemble raw waypoints from precomputed edge paths ───────────
	std::vector<Vector2> raw;
	raw.push_back(from);

	for (int i = 0; i + 1 < (int)abs_path.size(); ++i) {
		int cur_id  = abs_path[i];
		int next_id = abs_path[i + 1];

		// Find the edge cur → next
		const AbEdge *edge = nullptr;
		if (cur_id < (int)adj.size()) {
			for (const AbEdge &e : adj[cur_id]) {
				if (e.to == next_id) { edge = &e; break; }
			}
		}

		if (edge && !edge->waypoints.empty()) {
			// Use precomputed waypoints; skip the first one if it duplicates
			// the last point already added (avoids repeated positions).
			const std::vector<Vector2> &wps = edge->waypoints;
			int start_wi = 0;
			if (!raw.empty() &&
				raw.back().distance_to(wps.front()) < cell_size_ * 0.5f) {
				start_wi = 1;
			}
			for (int wi = start_wi; wi < (int)wps.size(); ++wi) {
				raw.push_back(wps[wi]);
			}
		} else {
			// Fallback: straight line to the next abstract node position
			if (next_id < (int)nodes.size()) {
				Vector2 np(nodes[next_id].wx, nodes[next_id].wz);
				if (raw.empty() ||
					raw.back().distance_to(np) > cell_size_ * 0.1f) {
					raw.push_back(np);
				}
			}
		}
	}

	// Ensure exact destination at the end
	if (raw.empty() || raw.back().distance_to(to) > cell_size_ * 0.5f) {
		raw.push_back(to);
	} else {
		raw.back() = to;
	}

	if (raw.size() < 2) return result;

	// ── Step 2: String pulling — greedy LOS simplification ──────────────────
	// Convert a world coordinate to the nearest grid cell index, clamped to
	// the valid grid range.
	auto to_gx = [&](float wx) -> int {
		int gx = static_cast<int>((wx - min_x_) / cell_size_);
		return std::max(0, std::min(gx, grid_w_ - 1));
	};
	auto to_gz = [&](float wz) -> int {
		int gz = static_cast<int>((wz - min_z_) / cell_size_);
		return std::max(0, std::min(gz, grid_h_ - 1));
	};

	// Threat-cluster gate: reject a shortcut whose world-space segment clips
	// any cluster that has been stamped as threat-blocked.  Uses the same
	// cluster AABB expansion (+half-cell) as stamp_threats so the two
	// tests are geometrically consistent.  When no threats are active every
	// entry in cluster_threat_blocked_ is 0, so the inner loop exits
	// immediately and there is no performance cost.
	auto threat_cluster_clear = [&](float ax, float az, float bx, float bz) -> bool {
		for (int cid = 0; cid < static_cast<int>(clusters_.size()); ++cid) {
			if (cluster_threat_blocked_[cid] == 0) continue;
			const Cluster &cl = clusters_[cid];
			float wx0, wz0, wx1, wz1;
			grid_to_world(cl.x0, cl.z0, wx0, wz0);
			grid_to_world(cl.x1, cl.z1, wx1, wz1);
			float hc = cell_size_ * 0.5f;
			wx0 -= hc; wz0 -= hc;
			wx1 += hc; wz1 += hc;
			if (segment_clips_aabb(ax, az, bx, bz, wx0, wz0, wx1, wz1))
				return false;
		}
		return true;
	};

	std::vector<Vector2> pulled;
	pulled.push_back(raw.front());

	size_t anchor = 0;
	while (anchor < raw.size() - 1) {
		size_t farthest = anchor + 1;
		// Try to reach as far forward as possible with a clear LOS that also
		// avoids threat-blocked clusters (mirrors finish_path_search behaviour).
		for (size_t test = raw.size() - 1; test > anchor + 1; --test) {
			if (nav_map_->line_of_sight(
					to_gx(raw[anchor].x), to_gz(raw[anchor].y),
					to_gx(raw[test].x),   to_gz(raw[test].y),
					clearance_) &&
				threat_cluster_clear(
					raw[anchor].x, raw[anchor].y,
					raw[test].x,   raw[test].y)) {
				farthest = test;
				break;
			}
		}
		pulled.push_back(raw[farthest]);
		anchor = farthest;
	}

	// ── Step 3: Package result ───────────────────────────────────────────────
	result.waypoints = pulled;
	result.flags.assign(pulled.size(), WP_NONE);

	for (size_t i = 0; i + 1 < pulled.size(); ++i) {
		result.total_distance += pulled[i].distance_to(pulled[i + 1]);
	}

	result.valid = true;
	return result;
}

// ============================================================================
// find_path
// ============================================================================

PathResult HpaGraph::find_path(Vector2 from, Vector2 to) const {
	using Clock = std::chrono::steady_clock;
	auto query_t0 = Clock::now();

	float connect_us = 0.0f;
	float abstract_us = 0.0f;
	float refine_us = 0.0f;
	float start_connect_us = 0.0f;
	float goal_connect_us = 0.0f;

	int connector_los_attempts = 0;
	int connector_los_hits = 0;
	int connector_local_search_runs = 0;
	int connector_local_expansions = 0;
	int connector_portal_candidates = 0;

	PathResult no_path;
	no_path.valid = false;
	no_path.total_distance = 0.0f;

	auto finalize_query = [&](PathResult r) -> PathResult {
		if (!perf_tracking_enabled_) {
			return r;
		}

		auto query_t1 = Clock::now();
		float total_us = std::chrono::duration<float, std::micro>(query_t1 - query_t0).count();

		perf_.query_count++;
		if (r.valid) perf_.success_count++;
		else perf_.failure_count++;

		perf_.last_total_us = total_us;
		perf_.last_connect_us = connect_us;
		perf_.last_abstract_us = abstract_us;
		perf_.last_refine_us = refine_us;
		perf_.last_start_connect_us = start_connect_us;
		perf_.last_goal_connect_us = goal_connect_us;

		perf_.last_connector_los_attempts = connector_los_attempts;
		perf_.last_connector_los_hits = connector_los_hits;
		perf_.last_connector_local_search_runs = connector_local_search_runs;
		perf_.last_connector_local_expansions = connector_local_expansions;
		perf_.last_connector_portal_candidates = connector_portal_candidates;

		auto update_ema = [&](float &ema, float sample) {
			if (perf_.query_count <= 1) ema = sample;
			else ema = ema * 0.9f + sample * 0.1f;
		};

		update_ema(perf_.avg_total_us, total_us);
		update_ema(perf_.avg_connect_us, connect_us);
		update_ema(perf_.avg_abstract_us, abstract_us);
		update_ema(perf_.avg_refine_us, refine_us);

		update_ema(perf_.avg_connector_los_attempts, static_cast<float>(connector_los_attempts));
		update_ema(perf_.avg_connector_los_hits, static_cast<float>(connector_los_hits));
		update_ema(perf_.avg_connector_local_search_runs, static_cast<float>(connector_local_search_runs));
		update_ema(perf_.avg_connector_local_expansions, static_cast<float>(connector_local_expansions));
		update_ema(perf_.avg_connector_portal_candidates, static_cast<float>(connector_portal_candidates));

		perf_.max_total_us = std::max(perf_.max_total_us, total_us);
		perf_.max_connect_us = std::max(perf_.max_connect_us, connect_us);
		perf_.max_abstract_us = std::max(perf_.max_abstract_us, abstract_us);
		perf_.max_refine_us = std::max(perf_.max_refine_us, refine_us);

		perf_.window_queries++;
		perf_.window_total_sum_us += total_us;
		perf_.window_connect_sum_us += connect_us;
		perf_.window_abstract_sum_us += abstract_us;
		perf_.window_refine_sum_us += refine_us;

		if (total_us >= perf_.spike_threshold_us) {
			perf_.spike_count++;
			perf_.worst_spike_us = std::max(perf_.worst_spike_us, total_us);
			UtilityFunctions::print(
				"[HpaGraph][SPIKE] total_us=", total_us,
				" connect_us=", connect_us,
				" abstract_us=", abstract_us,
				" refine_us=", refine_us,
				" los=", connector_los_hits, "/", connector_los_attempts,
				" local_runs=", connector_local_search_runs,
				" local_exp=", connector_local_expansions,
				" portals=", connector_portal_candidates,
				" spikes=", static_cast<int64_t>(perf_.spike_count));
		}

		uint64_t now_wall_us = static_cast<uint64_t>(
			std::chrono::duration_cast<std::chrono::microseconds>(query_t1.time_since_epoch()).count());
		if (perf_.last_report_wall_us == 0) {
			perf_.last_report_wall_us = now_wall_us;
		}
		uint64_t report_interval_us = static_cast<uint64_t>(perf_.report_interval_s * 1000000.0f);
		if (report_interval_us == 0) report_interval_us = 5000000;
		if (now_wall_us - perf_.last_report_wall_us >= report_interval_us) {
			float inv = (perf_.window_queries > 0) ? (1.0f / static_cast<float>(perf_.window_queries)) : 0.0f;
			float w_avg_total = perf_.window_total_sum_us * inv;
			float w_avg_connect = perf_.window_connect_sum_us * inv;
			float w_avg_abstract = perf_.window_abstract_sum_us * inv;
			float w_avg_refine = perf_.window_refine_sum_us * inv;
			float elapsed_s = static_cast<float>(now_wall_us - perf_.last_report_wall_us) / 1000000.0f;
			if (elapsed_s <= 0.0f) elapsed_s = perf_.report_interval_s;
			float qps = static_cast<float>(perf_.window_queries) / elapsed_s;
			UtilityFunctions::print(
				"[HpaGraph][AVG 5s] queries=", static_cast<int64_t>(perf_.window_queries),
				" qps=", qps,
				" avg_total_us=", w_avg_total,
				" avg_connect_us=", w_avg_connect,
				" avg_abstract_us=", w_avg_abstract,
				" avg_refine_us=", w_avg_refine,
				" max_total_us=", perf_.max_total_us,
				" spike_count=", static_cast<int64_t>(perf_.spike_count));
			perf_.window_queries = 0;
			perf_.window_total_sum_us = 0.0f;
			perf_.window_connect_sum_us = 0.0f;
			perf_.window_abstract_sum_us = 0.0f;
			perf_.window_refine_sum_us = 0.0f;
			perf_.last_report_wall_us = now_wall_us;
		}

		return r;
	};

	if (!built_) {
		return finalize_query(no_path);
	}

	auto world_to_cell = [&](Vector2 wp, int &gx, int &gz) {
		gx = static_cast<int>((wp.x - min_x_) / cell_size_);
		gz = static_cast<int>((wp.y - min_z_) / cell_size_);
		gx = std::max(0, std::min(gx, grid_w_ - 1));
		gz = std::max(0, std::min(gz, grid_h_ - 1));
	};

	auto make_direct = [&](Vector2 a, Vector2 b) -> PathResult {
		PathResult r;
		r.waypoints.push_back(a);
		r.waypoints.push_back(b);
		r.flags.assign(2, WP_NONE);
		r.total_distance = a.distance_to(b);
		r.valid = true;
		return r;
	};

	int from_gx = 0, from_gz = 0, to_gx = 0, to_gz = 0;
	world_to_cell(from, from_gx, from_gz);
	world_to_cell(to, to_gx, to_gz);

	int from_cid = cluster_id(cell_cx(from_gx), cell_cz(from_gz));
	int to_cid   = cluster_id(cell_cx(to_gx), cell_cz(to_gz));

	bool threat_layer_active = false;
	for (uint8_t blocked : cluster_threat_blocked_) {
		if (blocked != 0) {
			threat_layer_active = true;
			break;
		}
	}

	// Same-cluster fast path. Keep this disabled while threats are active so
	// we don't bypass HPA threat blocking with a threat-blind local path.
	if (from_cid == to_cid && !threat_layer_active) {
		if (nav_map_->line_of_sight(from_gx, from_gz, to_gx, to_gz, clearance_)) {
			return finalize_query(make_direct(from, to));
		}
		auto t0 = Clock::now();
		PathResult local = nav_map_->find_path_internal(from, to, clearance_, 0.0f);
		auto t1 = Clock::now();
		refine_us = std::chrono::duration<float, std::micro>(t1 - t0).count();
		return finalize_query(local);
	}

	// Hierarchical query graph: permanent graph + two temporary endpoint nodes.
	std::vector<AbNode>              q_nodes = nodes_;
	std::vector<std::vector<AbEdge>> q_adj   = adj_;

	constexpr int   MAX_CONNECT_RING       = 2;
	constexpr int   MAX_PORTAL_CANDIDATES  = 24;
	constexpr int   MAX_LOCAL_EXPANSIONS   = 30000;
	constexpr float WP_MERGE_EPSILON_SCALE = 0.1f;

	auto connect_point = [&](Vector2 wp, int wp_gx, int wp_gz, int center_cid) -> int {
		if (center_cid < 0 || center_cid >= static_cast<int>(clusters_.size())) return -1;

		int vid = static_cast<int>(q_nodes.size());
		AbNode vn;
		vn.id         = vid;
		vn.cluster_id = center_cid;
		vn.gx         = wp_gx;
		vn.gz         = wp_gz;
		vn.wx         = wp.x;
		vn.wz         = wp.y;
		q_nodes.push_back(vn);
		q_adj.push_back({});

		auto add_connector_edge = [&](int nid, float cost, const std::vector<Vector2> &wps_fwd) {
			if (cost <= 0.0f) {
				const AbNode &n = nodes_[nid];
				cost = wp.distance_to(Vector2(n.wx, n.wz));
			}
			std::vector<Vector2> wps_rev(wps_fwd.rbegin(), wps_fwd.rend());
			// via_cluster = -1: endpoint attachment edges must remain usable even
			// if the owning cluster is currently blocked by threat/obstacle stamps.
			q_adj[vid].push_back({ nid, cost, -1, wps_fwd });
			q_adj[nid].push_back({ vid, cost, -1, wps_rev });
		};

		bool any = false;
		const Cluster &cc = clusters_[center_cid];

		for (int ring = 0; ring <= MAX_CONNECT_RING; ++ring) {
			std::vector<uint8_t> allowed_clusters(clusters_.size(), 0);
			int cx0 = std::max(0, cc.cx - ring);
			int cx1 = std::min(ncx_ - 1, cc.cx + ring);
			int cz0 = std::max(0, cc.cz - ring);
			int cz1 = std::min(ncz_ - 1, cc.cz + ring);

			for (int cz = cz0; cz <= cz1; ++cz) {
				for (int cx = cx0; cx <= cx1; ++cx) {
					int cid = cluster_id(cx, cz);
					allowed_clusters[cid] = 1;
				}
			}

			std::vector<int> candidate_nodes;
			candidate_nodes.reserve(64);
			for (int cid = 0; cid < static_cast<int>(clusters_.size()); ++cid) {
				if (!allowed_clusters[cid]) continue;
				for (int nid : clusters_[cid].node_ids) {
					candidate_nodes.push_back(nid);
				}
			}
			if (candidate_nodes.empty()) continue;

			std::sort(candidate_nodes.begin(), candidate_nodes.end(), [&](int a, int b) {
				float dax = nodes_[a].wx - wp.x;
				float daz = nodes_[a].wz - wp.y;
				float dbx = nodes_[b].wx - wp.x;
				float dbz = nodes_[b].wz - wp.y;
				return (dax * dax + daz * daz) < (dbx * dbx + dbz * dbz);
			});
			if (static_cast<int>(candidate_nodes.size()) > MAX_PORTAL_CANDIDATES) {
				candidate_nodes.resize(MAX_PORTAL_CANDIDATES);
			}
			connector_portal_candidates += static_cast<int>(candidate_nodes.size());

			std::vector<uint8_t> connected(candidate_nodes.size(), 0);

			// Fast path: direct LOS to portal node skips all local search.
			for (size_t i = 0; i < candidate_nodes.size(); ++i) {
				int nid = candidate_nodes[i];
				const AbNode &n = nodes_[nid];
				connector_los_attempts++;
				if (!nav_map_->line_of_sight(wp_gx, wp_gz, n.gx, n.gz, clearance_)) {
					continue;
				}
				connector_los_hits++;

				std::vector<Vector2> wps;
				wps.push_back(wp);
				Vector2 np(n.wx, n.wz);
				if (wp.distance_to(np) > cell_size_ * WP_MERGE_EPSILON_SCALE) {
					wps.push_back(np);
				}
				add_connector_edge(nid, wp.distance_to(np), wps);
				connected[i] = 1;
				any = true;
			}

			std::vector<int> unresolved_indices;
			for (size_t i = 0; i < candidate_nodes.size(); ++i) {
				if (!connected[i]) unresolved_indices.push_back(static_cast<int>(i));
			}

			if (!unresolved_indices.empty() && cell_nav(wp_gx, wp_gz)) {
				connector_local_search_runs++;
				using PQ = std::pair<float, int>;
				std::priority_queue<PQ, std::vector<PQ>, std::greater<PQ>> open;

				const int total_cells = grid_w_ * grid_h_;
				const float INF = std::numeric_limits<float>::infinity();
				std::vector<float> dist(total_cells, INF);
				std::vector<int> parent(total_cells, -1);
				std::vector<uint8_t> closed(total_cells, 0);
				std::unordered_map<int, std::vector<int>> targets_by_cell;
				targets_by_cell.reserve(unresolved_indices.size());

				auto cell_idx = [&](int gx, int gz) -> int { return gz * grid_w_ + gx; };

				for (int tix : unresolved_indices) {
					int nid = candidate_nodes[tix];
					int tidx = cell_idx(nodes_[nid].gx, nodes_[nid].gz);
					targets_by_cell[tidx].push_back(tix);
				}

				int start_idx = cell_idx(wp_gx, wp_gz);
				dist[start_idx] = 0.0f;
				parent[start_idx] = start_idx;
				open.push({ 0.0f, start_idx });

				const int dx8[] = {-1, 0, 1, -1, 1, -1, 0, 1};
				const int dz8[] = {-1, -1, -1, 0, 0, 1, 1, 1};
				int expansions = 0;
				int remaining_target_cells = static_cast<int>(targets_by_cell.size());

				while (!open.empty() && remaining_target_cells > 0 && expansions < MAX_LOCAL_EXPANSIONS) {
					auto [cg, ci] = open.top();
					open.pop();
					if (closed[ci]) continue;
					closed[ci] = 1;
					expansions++;

					auto hit = targets_by_cell.find(ci);
					if (hit != targets_by_cell.end()) {
						for (int tix : hit->second) {
							if (connected[tix]) continue;
							int nid = candidate_nodes[tix];

							std::vector<Vector2> rev_cells;
							int cur = ci;
							while (cur != start_idx) {
								if (cur < 0) break;
								int cx = cur % grid_w_;
								int cz = cur / grid_w_;
								float wx, wz;
								grid_to_world(cx, cz, wx, wz);
								rev_cells.push_back(Vector2(wx, wz));
								int pi = parent[cur];
								if (pi == cur) break;
								cur = pi;
							}
							if (cur != start_idx) continue;

							std::reverse(rev_cells.begin(), rev_cells.end());
							std::vector<Vector2> wps_fwd;
							wps_fwd.reserve(rev_cells.size() + 2);
							wps_fwd.push_back(wp);
							for (const Vector2 &p : rev_cells) {
								if (wps_fwd.back().distance_to(p) > cell_size_ * WP_MERGE_EPSILON_SCALE) {
									wps_fwd.push_back(p);
								}
							}
							Vector2 np(nodes_[nid].wx, nodes_[nid].wz);
							if (wps_fwd.back().distance_to(np) > cell_size_ * WP_MERGE_EPSILON_SCALE) {
								wps_fwd.push_back(np);
							}

							add_connector_edge(nid, dist[ci], wps_fwd);
							connected[tix] = 1;
							any = true;
						}
						targets_by_cell.erase(hit);
						remaining_target_cells--;
					}

					int cx = ci % grid_w_;
					int cz = ci / grid_w_;
					for (int d = 0; d < 8; ++d) {
						int nx = cx + dx8[d];
						int nz = cz + dz8[d];
						if (nx < 0 || nx >= grid_w_ || nz < 0 || nz >= grid_h_) continue;

						int n_cid = cluster_id(cell_cx(nx), cell_cz(nz));
						if (!allowed_clusters[n_cid]) continue;
						if (!cell_nav(nx, nz)) continue;

						bool is_diag = (dx8[d] != 0 && dz8[d] != 0);
						if (is_diag) {
							int ax = cx + dx8[d];
							int az = cz;
							int bx = cx;
							int bz = cz + dz8[d];
							if (!cell_nav(ax, az) || !cell_nav(bx, bz)) continue;
						}

						float step = is_diag ? (cell_size_ * 1.41421356f) : cell_size_;
						int nidx = cell_idx(nx, nz);
						float ng = cg + step;
						if (ng >= dist[nidx]) continue;
						dist[nidx] = ng;
						parent[nidx] = ci;
						open.push({ ng, nidx });
					}
				}
				connector_local_expansions += expansions;
			}

			if (any) {
				break; // Use nearest ring that can connect this endpoint.
			}
		}

		if (!any) {
			q_nodes.pop_back();
			q_adj.pop_back();
			return -1;
		}

		return vid;
	};

	auto c0 = Clock::now();
	int start_id = connect_point(from, from_gx, from_gz, from_cid);
	auto c1 = Clock::now();
	start_connect_us = std::chrono::duration<float, std::micro>(c1 - c0).count();

	auto c2 = Clock::now();
	int goal_id  = connect_point(to, to_gx, to_gz, to_cid);
	auto c3 = Clock::now();
	goal_connect_us = std::chrono::duration<float, std::micro>(c3 - c2).count();
	connect_us = start_connect_us + goal_connect_us;

	// No global grid-level fallback here: if endpoints cannot be connected
	// through the HPA connector pipeline, report no path.
	if (start_id < 0 || goal_id < 0) {
		return finalize_query(no_path);
	}

	auto a0 = Clock::now();
	std::vector<int> abs_path = abstract_astar_impl(q_nodes, q_adj, start_id, goal_id);
	auto a1 = Clock::now();
	abstract_us = std::chrono::duration<float, std::micro>(a1 - a0).count();
	if (abs_path.empty()) {
		return finalize_query(no_path);
	}

	auto r0 = Clock::now();
	PathResult refined = refine_path_impl(abs_path, q_nodes, q_adj, from, to);
	auto r1 = Clock::now();
	refine_us = std::chrono::duration<float, std::micro>(r1 - r0).count();

	return finalize_query(refined);
}

// ============================================================================
// find_path_packed
// ============================================================================

PackedVector2Array HpaGraph::find_path_packed(Vector2 from, Vector2 to) const {
	PathResult pr = find_path(from, to);
	PackedVector2Array out;
	if (!pr.valid) return out;
	for (const Vector2 &wp : pr.waypoints) {
		out.push_back(wp);
	}
	return out;
}

// ============================================================================
// Debug accessors
// ============================================================================

TypedArray<Dictionary> HpaGraph::get_debug_nodes() const {
	TypedArray<Dictionary> out;
	for (const AbNode &n : nodes_) {
		Dictionary d;
		d["id"]         = n.id;
		d["cluster_id"] = n.cluster_id;
		d["position"]   = Vector2(n.wx, n.wz);
		out.push_back(d);
	}
	return out;
}

TypedArray<Dictionary> HpaGraph::get_debug_edges() const {
	TypedArray<Dictionary> out;
	for (int i = 0; i < (int)nodes_.size(); ++i) {
		for (const AbEdge &e : adj_[i]) {
			if (e.to <= i) continue; // avoid duplicates
			Dictionary d;
			d["from"]        = i;
			d["to"]          = e.to;
			d["cost"]        = e.cost;
			d["via_cluster"] = e.via_cluster;
			d["inter"]       = (e.via_cluster < 0);
			if ((int)nodes_.size() > i && (int)nodes_.size() > e.to) {
				d["from_pos"] = Vector2(nodes_[i].wx, nodes_[i].wz);
				d["to_pos"]   = Vector2(nodes_[e.to].wx, nodes_[e.to].wz);
			}
			out.push_back(d);
		}
	}
	return out;
}

TypedArray<Dictionary> HpaGraph::get_debug_clusters() const {
	TypedArray<Dictionary> out;
	for (const Cluster &c : clusters_) {
		Dictionary d;
		d["id"]        = c.id;
		d["cx"]        = c.cx;
		d["cz"]        = c.cz;
		d["navigable"] = c.navigable;
		d["blocked"]   = (cluster_block_count_[c.id] > 0);
		d["node_count"] = (int)c.node_ids.size();
		// World-space corners of the cluster
		float wx0, wz0, wx1, wz1;
		grid_to_world(c.x0, c.z0, wx0, wz0);
		grid_to_world(c.x1, c.z1, wx1, wz1);
		d["world_min"] = Vector2(wx0, wz0);
		d["world_max"] = Vector2(wx1, wz1);
		out.push_back(d);
	}
	return out;
}

Dictionary HpaGraph::get_perf_metrics() const {
	Dictionary d;
	d["tracking_enabled"] = perf_tracking_enabled_;
	d["query_count"] = static_cast<int64_t>(perf_.query_count);
	d["success_count"] = static_cast<int64_t>(perf_.success_count);
	d["failure_count"] = static_cast<int64_t>(perf_.failure_count);

	d["last_total_us"] = perf_.last_total_us;
	d["last_connect_us"] = perf_.last_connect_us;
	d["last_start_connect_us"] = perf_.last_start_connect_us;
	d["last_goal_connect_us"] = perf_.last_goal_connect_us;
	d["last_abstract_us"] = perf_.last_abstract_us;
	d["last_refine_us"] = perf_.last_refine_us;

	d["avg_total_us"] = perf_.avg_total_us;
	d["avg_connect_us"] = perf_.avg_connect_us;
	d["avg_abstract_us"] = perf_.avg_abstract_us;
	d["avg_refine_us"] = perf_.avg_refine_us;

	d["max_total_us"] = perf_.max_total_us;
	d["max_connect_us"] = perf_.max_connect_us;
	d["max_abstract_us"] = perf_.max_abstract_us;
	d["max_refine_us"] = perf_.max_refine_us;

	d["last_connector_los_attempts"] = perf_.last_connector_los_attempts;
	d["last_connector_los_hits"] = perf_.last_connector_los_hits;
	d["last_connector_local_search_runs"] = perf_.last_connector_local_search_runs;
	d["last_connector_local_expansions"] = perf_.last_connector_local_expansions;
	d["last_connector_portal_candidates"] = perf_.last_connector_portal_candidates;

	d["avg_connector_los_attempts"] = perf_.avg_connector_los_attempts;
	d["avg_connector_los_hits"] = perf_.avg_connector_los_hits;
	d["avg_connector_local_search_runs"] = perf_.avg_connector_local_search_runs;
	d["avg_connector_local_expansions"] = perf_.avg_connector_local_expansions;
	d["avg_connector_portal_candidates"] = perf_.avg_connector_portal_candidates;

	d["spike_threshold_us"] = perf_.spike_threshold_us;
	d["spike_count"] = static_cast<int64_t>(perf_.spike_count);
	d["worst_spike_us"] = perf_.worst_spike_us;
	d["report_interval_s"] = perf_.report_interval_s;
	d["window_queries"] = static_cast<int64_t>(perf_.window_queries);
	if (perf_.window_queries > 0) {
		float inv = 1.0f / static_cast<float>(perf_.window_queries);
		d["window_avg_total_us"] = perf_.window_total_sum_us * inv;
		d["window_avg_connect_us"] = perf_.window_connect_sum_us * inv;
		d["window_avg_abstract_us"] = perf_.window_abstract_sum_us * inv;
		d["window_avg_refine_us"] = perf_.window_refine_sum_us * inv;
	} else {
		d["window_avg_total_us"] = 0.0f;
		d["window_avg_connect_us"] = 0.0f;
		d["window_avg_abstract_us"] = 0.0f;
		d["window_avg_refine_us"] = 0.0f;
	}

	return d;
}

void HpaGraph::reset_perf_metrics() {
	float threshold = perf_.spike_threshold_us;
	float report_interval = perf_.report_interval_s;
	perf_ = PerfStats();
	perf_.spike_threshold_us = threshold;
	perf_.report_interval_s = report_interval;
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
	// Reset threat layer
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);

	if (threats.empty() || clusters_.empty() || !nav_map_.is_valid()) return;

	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;

		// World coords of this cluster's centre cell
		int mid_gx = (c.x0 + c.x1) / 2;
		int mid_gz = (c.z0 + c.z1) / 2;
		float cx_world, cz_world;
		grid_to_world(mid_gx, mid_gz, cx_world, cz_world);

		for (const ThreatCircle &t : threats) {
			if (t.radius <= 0.0f) continue;
			float dx = cx_world - t.origin.x;
			float dz = cz_world - t.origin.y;
			if (dx * dx + dz * dz > t.radius * t.radius) continue;

			// LOS from cluster centre to threat origin (clearance 0 — any terrain blocks).
			int gx_t = static_cast<int>((t.origin.x - min_x_) / cell_size_);
			int gz_t = static_cast<int>((t.origin.y - min_z_) / cell_size_);
			gx_t = std::max(0, std::min(gx_t, grid_w_ - 1));
			gz_t = std::max(0, std::min(gz_t, grid_h_ - 1));

			if (nav_map_->line_of_sight(mid_gx, mid_gz, gx_t, gz_t, 0.0f)) {
				cluster_threat_blocked_[c.id] = 1;
				break;  // cluster is blocked — no need to test remaining threats
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
// compute_debug_threat_clusters
// Pure query version: performs the same circle + LOS test as stamp_threats but
// writes results directly into the output array rather than cluster_threat_blocked_.
// Safe to call from any ship's navigator without disturbing shared routing state.
// ============================================================================

TypedArray<Dictionary> HpaGraph::compute_debug_threat_clusters(
		const std::vector<ThreatCircle> &threats) const {
	TypedArray<Dictionary> out;
	if (!built_ || threats.empty() || !nav_map_.is_valid()) return out;

	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;

		int mid_gx = (c.x0 + c.x1) / 2;
		int mid_gz = (c.z0 + c.z1) / 2;
		float cx_world, cz_world;
		grid_to_world(mid_gx, mid_gz, cx_world, cz_world);

		bool blocked = false;
		for (const ThreatCircle &t : threats) {
			if (t.radius <= 0.0f) continue;
			float dx = cx_world - t.origin.x;
			float dz = cz_world - t.origin.y;
			if (dx * dx + dz * dz > t.radius * t.radius) continue;

			int gx_t = static_cast<int>((t.origin.x - min_x_) / cell_size_);
			int gz_t = static_cast<int>((t.origin.y - min_z_) / cell_size_);
			gx_t = std::max(0, std::min(gx_t, grid_w_ - 1));
			gz_t = std::max(0, std::min(gz_t, grid_h_ - 1));

			if (nav_map_->line_of_sight(mid_gx, mid_gz, gx_t, gz_t, 0.0f)) {
				blocked = true;
				break;
			}
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