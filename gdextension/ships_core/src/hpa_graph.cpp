#include "hpa_graph.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

namespace godot {

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

	// Start with the true 'from' position
	result.waypoints.push_back(from);
	result.flags.push_back(WP_NONE);

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
			// the last waypoint already added (avoids repeated positions).
			const std::vector<Vector2> &wps = edge->waypoints;
			int start_wi = 0;
			if (!result.waypoints.empty() &&
				result.waypoints.back().distance_to(wps.front()) < cell_size_ * 0.5f) {
				start_wi = 1;
			}
			for (int wi = start_wi; wi < (int)wps.size(); ++wi) {
				result.waypoints.push_back(wps[wi]);
				result.flags.push_back(WP_NONE);
			}
		} else {
			// Fallback: straight line to the next abstract node position
			if (next_id < (int)nodes.size()) {
				Vector2 np(nodes[next_id].wx, nodes[next_id].wz);
				if (result.waypoints.empty() ||
					result.waypoints.back().distance_to(np) > cell_size_ * 0.1f) {
					result.waypoints.push_back(np);
					result.flags.push_back(WP_NONE);
				}
			}
		}
	}

	// Ensure the last waypoint is the exact destination
	if (result.waypoints.empty() ||
		result.waypoints.back().distance_to(to) > cell_size_ * 0.5f) {
		result.waypoints.push_back(to);
		result.flags.push_back(WP_NONE);
	} else {
		// Replace the last point with the exact destination for precision
		result.waypoints.back() = to;
	}

	// Compute total distance
	for (int i = 0; i + 1 < (int)result.waypoints.size(); ++i) {
		result.total_distance +=
			result.waypoints[i].distance_to(result.waypoints[i + 1]);
	}

	result.valid = true;
	return result;
}

// ============================================================================
// find_path
// ============================================================================

PathResult HpaGraph::find_path(Vector2 from, Vector2 to) const {
	if (!built_) {
		PathResult r; r.valid = false; return r;
	}

	// Determine grid cells and owning clusters for from / to
	auto world_to_cluster = [&](Vector2 wp) -> int {
		int gx = static_cast<int>((wp.x - min_x_) / cell_size_);
		int gz = static_cast<int>((wp.y - min_z_) / cell_size_);
		gx = std::max(0, std::min(gx, grid_w_ - 1));
		gz = std::max(0, std::min(gz, grid_h_ - 1));
		return cluster_id(cell_cx(gx), cell_cz(gz));
	};

	int from_cid = world_to_cluster(from);
	int to_cid   = world_to_cluster(to);

	// -----------------------------------------------------------------------
	// Fast path: same cluster — delegate directly to the grid-level planner
	// -----------------------------------------------------------------------
	if (from_cid == to_cid) {
		return nav_map_->find_path_internal(from, to, clearance_, 0.0f);
	}

	// -----------------------------------------------------------------------
	// Hierarchical path: copy the permanent graph and augment with two
	// temporary nodes for 'from' and 'to'.
	// -----------------------------------------------------------------------
	std::vector<AbNode>              q_nodes = nodes_;
	std::vector<std::vector<AbEdge>> q_adj   = adj_;

	// Helper: connect world point wp to all entrance nodes in cluster cid.
	// Adds a virtual node at index q_nodes.size() with edges to/from entrances.
	// Returns the virtual node id, or -1 if cluster has no reachable entrances.
	auto connect_point = [&](Vector2 wp, int cid) -> int {
		const Cluster &c = clusters_[cid];
		if (c.node_ids.empty()) return -1;

		int vid = static_cast<int>(q_nodes.size());
		int gx  = static_cast<int>((wp.x - min_x_) / cell_size_);
		int gz  = static_cast<int>((wp.y - min_z_) / cell_size_);
		gx = std::max(0, std::min(gx, grid_w_ - 1));
		gz = std::max(0, std::min(gz, grid_h_ - 1));

		AbNode vn;
		vn.id         = vid;
		vn.cluster_id = cid;
		vn.gx         = gx;
		vn.gz         = gz;
		vn.wx         = wp.x;
		vn.wz         = wp.y;
		q_nodes.push_back(vn);
		q_adj.push_back({});  // empty adjacency for this virtual node

		bool any = false;
		for (int nid : c.node_ids) {
			const AbNode &n = nodes_[nid];
			Vector2 np(n.wx, n.wz);

			PathResult pr = nav_map_->find_path_internal(wp, np, clearance_, 0.0f);
			if (!pr.valid || pr.waypoints.empty()) continue;

			float cost = pr.total_distance;
			if (cost <= 0.0f) cost = wp.distance_to(np);

			std::vector<Vector2> wps_fwd(pr.waypoints.begin(), pr.waypoints.end());
			std::vector<Vector2> wps_rev(wps_fwd.rbegin(), wps_fwd.rend());

			// vid → entrance nid
			q_adj[vid].push_back({ nid, cost, cid, wps_fwd });
			// entrance nid → vid  (append to existing adjacency)
			q_adj[nid].push_back({ vid, cost, cid, wps_rev });

			any = true;
		}

		if (!any) {
			// No reachable entrance; remove the virtual node
			q_nodes.pop_back();
			q_adj.pop_back();
			return -1;
		}
		return vid;
	};

	int start_id = connect_point(from, from_cid);
	int goal_id  = connect_point(to,   to_cid);

	// Fall back to direct grid A* if we couldn't connect either endpoint
	if (start_id < 0 || goal_id < 0) {
		return nav_map_->find_path_internal(from, to, clearance_, 0.0f);
	}

	// Run abstract A*
	std::vector<int> abs_path =
		abstract_astar_impl(q_nodes, q_adj, start_id, goal_id);

	if (abs_path.empty()) {
		// Abstract A* found no route; fall back to direct grid A*
		return nav_map_->find_path_internal(from, to, clearance_, 0.0f);
	}

	return refine_path_impl(abs_path, q_nodes, q_adj, from, to);
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

// ============================================================================
// stamp_threat_arcs / clear_threat_arcs
// ============================================================================

// Point-in-arc wedge test.  Returns true if (px, pz) lies within the
// radial sector defined by arc: distance <= arc.length AND angular
// difference from arc.bearing <= arc.half_angle.
static bool point_in_arc(float px, float pz, const ThreatArc &arc) {
	float dx = px - arc.origin.x;
	float dz = pz - arc.origin.y;
	float dist_sq = dx * dx + dz * dz;
	if (dist_sq > arc.length * arc.length) return false;
	if (dist_sq < 0.01f) return true; // origin itself — always inside

	float bearing = std::atan2(dz, dx);
	float diff    = bearing - arc.bearing;
	// Normalise to (-π, π]
	while (diff >  3.14159265f) diff -= 6.28318530f;
	while (diff < -3.14159265f) diff += 6.28318530f;
	return std::abs(diff) <= arc.half_angle;
}

// Test whether a cluster's rectangular cell range overlaps a ThreatArc.
// We probe 9 representative points (corners, edge midpoints, centre).
// Additionally, if the arc origin sits inside the cluster AABB we block
// it immediately — this catches narrow arcs whose centre line passes
// through without hitting any sample point.
static bool cluster_overlaps_arc(float wx0, float wz0, float wx1, float wz1,
                                 const ThreatArc &arc)
{
	// Fast reject: AABB of cluster vs circle bounding the arc
	float mid_x  = (wx0 + wx1) * 0.5f;
	float mid_z  = (wz0 + wz1) * 0.5f;
	float half_w = (wx1 - wx0) * 0.5f;
	float half_h = (wz1 - wz0) * 0.5f;
	float box_reach = std::sqrt(half_w * half_w + half_h * half_h);
	float dx_o = arc.origin.x - mid_x;
	float dz_o = arc.origin.y - mid_z;
	float dist_o = std::sqrt(dx_o * dx_o + dz_o * dz_o);
	// If the circle can't possibly reach the cluster AABB, skip
	if (dist_o > arc.length + box_reach) return false;

	// If the arc origin is inside the cluster, block immediately
	if (arc.origin.x >= wx0 && arc.origin.x <= wx1 &&
	    arc.origin.y >= wz0 && arc.origin.y <= wz1) {
		return true;
	}

	// Sample 9 points: 4 corners, 4 edge midpoints, 1 centre
	const float xs[3] = { wx0, mid_x, wx1 };
	const float zs[3] = { wz0, mid_z, wz1 };
	for (int zi = 0; zi < 3; ++zi) {
		for (int xi = 0; xi < 3; ++xi) {
			if (point_in_arc(xs[xi], zs[zi], arc)) return true;
		}
	}
	return false;
}

void HpaGraph::stamp_threat_arcs(const std::vector<ThreatArc> &arcs) {
	// Reset threat layer
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);

	if (arcs.empty() || clusters_.empty()) return;

	// Pre-cache the cell_size in world units so grid_to_world is cheap
	// (it already uses the cached min_x_/min_z_/cell_size_ fields).
	for (const Cluster &c : clusters_) {
		if (!c.navigable) continue;

		// World-space AABB of this cluster (cell centres at the corners)
		float wx0, wz0, wx1, wz1;
		grid_to_world(c.x0, c.z0, wx0, wz0);
		grid_to_world(c.x1, c.z1, wx1, wz1);
		// Expand by half a cell so AABB covers entire cell footprint
		float hc = cell_size_ * 0.5f;
		wx0 -= hc; wz0 -= hc;
		wx1 += hc; wz1 += hc;

		for (const ThreatArc &arc : arcs) {
			if (arc.length <= 0.0f) continue;
			if (cluster_overlaps_arc(wx0, wz0, wx1, wz1, arc)) {
				cluster_threat_blocked_[c.id] = 1;
				break; // no need to test remaining arcs for this cluster
			}
		}
	}
}

void HpaGraph::clear_threat_arcs() {
	std::fill(cluster_threat_blocked_.begin(), cluster_threat_blocked_.end(), 0);
}

} // namespace godot