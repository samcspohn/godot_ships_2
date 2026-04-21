#include "dstar_lite.h"
#include "waypoint_graph.h"

#include <algorithm>

namespace godot {

DStarLite::DStarLite() {}
DStarLite::~DStarLite() {}

float DStarLite::h(int a, int b) const {
	return graph_->node_position(a).distance_to(graph_->node_position(b));
}

// Backward search: heuristic is distance from s toward start_ (the ship)
DStarLite::Key DStarLite::calculate_key(int s) const {
	float min_gr = std::min(g_[s], rhs_[s]);
	return { min_gr + h(start_, s) + km_,
			 min_gr };
}

void DStarLite::insert_open(int s) {
	Key k = calculate_key(s);
	if (in_open_[s]) {
		open_set_.erase({stored_key_[s], s});
	}
	open_set_.insert({k, s});
	in_open_[s] = true;
	stored_key_[s] = k;
}

void DStarLite::remove_open(int s) {
	if (!in_open_[s]) return;
	open_set_.erase({stored_key_[s], s});
	in_open_[s] = false;
}

float DStarLite::recompute_edge_cost_for(int node, int neighbor_order) const {
	const auto& adj = graph_->neighbors(node);
	if (neighbor_order < 0 || neighbor_order >= (int)adj.size()) return INF;
	int target = adj[neighbor_order].target;
	return graph_->compute_edge_cost(node, target, ship_radius_, threats_);
}

float DStarLite::edge_cost_cached(int node, int neighbor_order) const {
	if (node < 0 || node >= (int)edge_costs_.size()) return INF;
	if (neighbor_order < 0 || neighbor_order >= (int)edge_costs_[node].size()) return INF;
	return edge_costs_[node][neighbor_order];
}

int DStarLite::find_neighbor_order(int from, int to) const {
	const auto& adj = graph_->neighbors(from);
	for (int i = 0; i < (int)adj.size(); i++) {
		if (adj[i].target == to) return i;
	}
	return -1;
}

void DStarLite::initialize(const WaypointGraph* graph, int start, int goal,
						   float ship_radius, const std::vector<ThreatZone>& threats) {
	graph_ = graph;
	start_ = start;
	goal_ = goal;
	km_ = 0.0f;
	ship_radius_ = ship_radius;
	threats_ = threats;

	int n = graph_->node_count();

	g_.assign(n, INF);
	rhs_.assign(n, INF);
	in_open_.assign(n, false);
	stored_key_.resize(n);
	open_set_.clear();

	// Build edge cost cache -- but only when the graph or ship_radius
	// actually changed.  Terrain is static; a goal-only change does not
	// invalidate any cached edge cost.  Skipping this loop is the dominant
	// saving when the destination drifts (O(E) DDA raycasts avoided).
	const int n_cached = (int)edge_costs_.size();
	const bool full_rebuild = (graph_ != cache_graph_ ||
	                           ship_radius_ != cache_ship_radius_ ||
	                           n_cached == 0);
	if (full_rebuild) {
		edge_costs_.resize(n);
		for (int i = 0; i < n; i++) {
			if (!graph_->node_active(i)) {
				edge_costs_[i].clear();
				continue;
			}
			const auto& adj = graph_->neighbors(i);
			edge_costs_[i].resize(adj.size());
			for (int j = 0; j < (int)adj.size(); j++) {
				edge_costs_[i][j] = graph_->compute_edge_cost(i, adj[j].target,
															   ship_radius_, threats_);
			}
		}
		cache_graph_       = graph_;
		cache_ship_radius_ = ship_radius_;
	} else if (n > n_cached) {
		// Graph grew (proxy nodes added since last full build).
		// Extend with INF -- notify_edges_changed() will fill real costs in.
		edge_costs_.resize(n);
		for (int i = n_cached; i < n; i++) {
			const auto& adj = graph_->neighbors(i);
			edge_costs_[i].assign(adj.size(), INF);
		}
	}

	// Backward D* Lite: goal_ is the source, rhs[goal_] = 0
	rhs_[goal_] = 0.0f;
	insert_open(goal_);

	// Build threat spatial grid for fast node-blocking lookups in update_vertex.
	if (!threats_.empty()) {
		threat_grid_.build(threats_, ThreatGrid::default_cell_size(threats_));
	} else {
		threat_grid_ = ThreatGrid{};
	}
}

void DStarLite::update_vertex(int u) {
	// Backward search: rhs(u) = min over successors s of (edge_cost(u->s) + g(s))
	// In our undirected graph, successors == neighbors.
	// Node-level detection-circle blocking.
	// goal_ is the source -- exempt it and start_ (ship) from blocking.
	// If u is inside any threat hard_radius, it is unreachable.
	if (u != goal_ && u != start_ && !threats_.empty()) {
		Vector2 pos = graph_->node_position(u);
		for (int ti : threat_grid_.query_point(pos)) {
			const auto& tz = threats_[ti];
			if (pos.distance_squared_to(tz.position) <
					tz.hard_radius * tz.hard_radius) {
				rhs_[u] = INF;
				remove_open(u);
				if (g_[u] != rhs_[u]) insert_open(u);
				return;
			}
		}
	}

	if (u != goal_) {
		// goal_ is the source -- its rhs stays 0
		float best = INF;
		const auto& adj = graph_->neighbors(u);
		for (int j = 0; j < (int)adj.size(); j++) {
			int s = adj[j].target;
			if (!graph_->node_active(s)) continue;
			float cost = edge_cost_cached(u, j);
			float val = cost + g_[s];
			if (val < best) best = val;
		}
		rhs_[u] = best;
	}

	remove_open(u);
	if (g_[u] != rhs_[u]) {
		insert_open(u);
	}
}

bool DStarLite::compute_shortest_path(int max_iterations) {
	if (!graph_ || start_ < 0 || goal_ < 0) return true;

	int iters = 0;
	while (!open_set_.empty() && iters < max_iterations) {
		auto top_it = open_set_.begin();
		Key top_key = top_it->first;
		int u = top_it->second;

		// Backward search: terminate when start is consistent and top >= start key
		Key start_key = calculate_key(start_);
		if (!(top_key < start_key) && rhs_[start_] == g_[start_]) {
			break;
		}

		iters++;

		Key k_new = calculate_key(u);
		if (top_key < k_new) {
			open_set_.erase(top_it);
			open_set_.insert({k_new, u});
			stored_key_[u] = k_new;
		} else if (g_[u] > rhs_[u]) {
			// Overconsistent: set g = rhs and propagate to successors
			g_[u] = rhs_[u];
			open_set_.erase(top_it);
			in_open_[u] = false;

			const auto& adj = graph_->neighbors(u);
			for (const auto& e : adj) {
				if (graph_->node_active(e.target)) {
					update_vertex(e.target);
				}
			}
		} else {
			// Underconsistent: reset g = INF and re-expand u and its successors
			g_[u] = INF;
			update_vertex(u);
			const auto& adj = graph_->neighbors(u);
			for (const auto& e : adj) {
				if (graph_->node_active(e.target)) {
					update_vertex(e.target);
				}
			}
		}
	}

	if (open_set_.empty()) return true;
	if (rhs_[start_] == g_[start_]) return true;
	return (iters < max_iterations);
}

void DStarLite::update_threats(const std::vector<ThreatZone>& new_threats) {
	if (!graph_) return;

	std::vector<ThreatZone> old_threats = threats_;
	threats_ = new_threats;

	// Rebuild threat grid for updated positions.
	if (!threats_.empty()) {
		threat_grid_.build(threats_, ThreatGrid::default_cell_size(threats_));
	} else {
		threat_grid_ = ThreatGrid{};
	}

	// Mark nodes that may have changed blocking status:
	// those inside or near old circles (might be unblocked now)
	// and those inside or near new circles (might be newly blocked).
	// Search radius = hard_radius only -- we only care about nodes
	// whose inside/outside status changed, not about far-away edge costs.
	std::vector<bool> affected(graph_->node_count(), false);

	auto mark_circle = [&](const ThreatZone& tz) {
		auto near = graph_->get_edges_near(tz.position, tz.hard_radius);
		for (const auto& [a, b] : near) {
			affected[a] = true;
			affected[b] = true;
		}
	};

	for (const auto& tz : old_threats) mark_circle(tz);
	for (const auto& tz : new_threats) mark_circle(tz);

	for (int i = 0; i < graph_->node_count(); i++) {
		if (affected[i] && graph_->node_active(i)) {
			update_vertex(i);
		}
	}
}

void DStarLite::notify_edges_changed(const std::vector<std::pair<int,int>>& edges) {
	if (!graph_) return;

	for (const auto& [a, b] : edges) {
		// Update cached cost for a->b
		int order_ab = find_neighbor_order(a, b);
		if (order_ab >= 0) {
			if (order_ab >= (int)edge_costs_[a].size()) {
				edge_costs_[a].resize(order_ab + 1, INF);
			}
			float new_cost = graph_->compute_edge_cost(a, b, ship_radius_, threats_);
			if (new_cost != edge_costs_[a][order_ab]) {
				edge_costs_[a][order_ab] = new_cost;
				// Edge a->b cost changed: in backward search rhs(a) may change
				update_vertex(a);
			}
		}
		// Update cached cost for b->a
		int order_ba = find_neighbor_order(b, a);
		if (order_ba >= 0) {
			if (order_ba >= (int)edge_costs_[b].size()) {
				edge_costs_[b].resize(order_ba + 1, INF);
			}
			float new_cost = graph_->compute_edge_cost(b, a, ship_radius_, threats_);
			if (new_cost != edge_costs_[b][order_ba]) {
				edge_costs_[b][order_ba] = new_cost;
				// Edge b->a cost changed: in backward search rhs(b) may change
				update_vertex(b);
			}
		}
	}
}

void DStarLite::advance_start(int new_start) {
	if (!graph_ || new_start < 0 || new_start >= graph_->node_count()) return;
	if (new_start == start_) return;
	km_ += h(start_, new_start);
	start_ = new_start;
	// Existing open-set entries have stale keys; D* Lite handles this via
	// the "if k_old < CalculateKey(u)" re-insert check in compute_shortest_path.
}

std::vector<int> DStarLite::extract_path() const {
	std::vector<int> path;
	if (!graph_ || start_ < 0 || goal_ < 0) return path;
	if (g_[start_] >= INF) return path;

	path.push_back(start_);
	int current = start_;
	int max_steps = graph_->node_count() + 1;

	while (current != goal_ && max_steps-- > 0) {
		const auto& adj = graph_->neighbors(current);
		int best_next = -1;
		float best_cost = INF;
		for (int j = 0; j < (int)adj.size(); j++) {
			int s = adj[j].target;
			if (!graph_->node_active(s)) continue;
			float c = edge_cost_cached(current, j);
			float val = c + g_[s];
			if (val < best_cost) {
				best_cost = val;
				best_next = s;
			}
		}
		if (best_next < 0 || best_cost >= INF) break;
		path.push_back(best_next);
		current = best_next;
	}

	if (path.empty() || path.back() != goal_) {
		path.clear();
	}
	return path;
}

bool DStarLite::has_path() const {
	if (!graph_ || start_ < 0) return false;
	return g_[start_] < INF;
}

float DStarLite::path_cost() const {
	if (!graph_ || start_ < 0) return INF;
	return g_[start_];
}

} // namespace godot
