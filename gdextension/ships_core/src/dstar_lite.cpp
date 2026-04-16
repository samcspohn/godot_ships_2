#include "dstar_lite.h"
#include "waypoint_graph.h"

#include <algorithm>

namespace godot {

// ============================================================================
// Construction / destruction
// ============================================================================

DStarLite::DStarLite() {}
DStarLite::~DStarLite() {}

// ============================================================================
// Heuristic — Euclidean distance between node positions
// ============================================================================

float DStarLite::h(int a, int b) const {
	return graph_->node_position(a).distance_to(graph_->node_position(b));
}

// ============================================================================
// Priority key
// ============================================================================

DStarLite::Key DStarLite::calculate_key(int s) const {
	float min_gr = std::min(g_[s], rhs_[s]);
	return { min_gr + h(start_, s) + km_,
			 min_gr };
}

// ============================================================================
// Open set operations
// ============================================================================

void DStarLite::insert_open(int s) {
	Key k = calculate_key(s);
	if (in_open_[s]) {
		// Remove old entry first
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

// ============================================================================
// Edge cost helpers
// ============================================================================

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

// ============================================================================
// Initialize — set up for a new path query
// ============================================================================

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

	// Build edge cost cache
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

	// D* Lite: goal has rhs = 0, inserted into open set
	rhs_[goal_] = 0.0f;
	insert_open(goal_);
}

// ============================================================================
// UpdateVertex — core D* Lite operation
// ============================================================================

void DStarLite::update_vertex(int u) {
	// rhs(u) = min over successors s of (c(u, s) + g(s))
	// In an undirected graph, successors = neighbors
	if (u != goal_) {
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

	// Remove from open set, re-insert if inconsistent
	remove_open(u);
	if (g_[u] != rhs_[u]) {
		insert_open(u);
	}
}

// ============================================================================
// ComputeShortestPath — main D* Lite loop
// ============================================================================

bool DStarLite::compute_shortest_path(int max_iterations) {
	if (!graph_ || start_ < 0 || goal_ < 0) return true;

	int iters = 0;
	while (!open_set_.empty() && iters < max_iterations) {
		auto top_it = open_set_.begin();
		Key top_key = top_it->first;
		int u = top_it->second;

		Key start_key = calculate_key(start_);

		// Termination: open set top >= start key AND start is consistent
		if (!(top_key < start_key) && rhs_[start_] == g_[start_]) {
			break;
		}

		iters++;

		Key k_new = calculate_key(u);
		if (top_key < k_new) {
			// Key is outdated — re-insert with correct key
			open_set_.erase(top_it);
			open_set_.insert({k_new, u});
			stored_key_[u] = k_new;
		} else if (g_[u] > rhs_[u]) {
			// Overconsistent — make consistent
			g_[u] = rhs_[u];
			open_set_.erase(top_it);
			in_open_[u] = false;

			// Update all predecessors (= neighbors in undirected graph)
			const auto& adj = graph_->neighbors(u);
			for (const auto& e : adj) {
				if (graph_->node_active(e.target)) {
					update_vertex(e.target);
				}
			}
		} else {
			// Underconsistent — reset and propagate
			g_[u] = INF;
			// Update u and all predecessors
			update_vertex(u);
			const auto& adj = graph_->neighbors(u);
			for (const auto& e : adj) {
				if (graph_->node_active(e.target)) {
					update_vertex(e.target);
				}
			}
		}
	}

	// Converged if open set is empty or start is consistent with valid key
	if (open_set_.empty()) return true;
	if (rhs_[start_] == g_[start_]) return true;
	return (iters < max_iterations); // ran out of budget
}

// ============================================================================
// Threat updates — recompute affected edge costs
// ============================================================================

void DStarLite::update_threats(const std::vector<ThreatZone>& new_threats) {
	if (!graph_) return;

	std::vector<ThreatZone> old_threats = threats_;
	threats_ = new_threats;

	// Find all edges that could be affected by old or new threats.
	// An edge is potentially affected if it's near any threat's position.
	// For efficiency, collect affected node set, then check their edges.
	std::vector<bool> affected_node(graph_->node_count(), false);

	auto mark_near = [&](const std::vector<ThreatZone>& tzs) {
		for (const auto& tz : tzs) {
			float search_r = tz.soft_radius + WaypointGraph::MAX_EDGE_LENGTH;
			auto near = graph_->get_edges_near(tz.position, search_r);
			for (const auto& [a, b] : near) {
				affected_node[a] = true;
				affected_node[b] = true;
			}
		}
	};

	mark_near(old_threats);
	mark_near(new_threats);

	// Recompute edge costs for affected nodes and call update_vertex where changed
	for (int i = 0; i < graph_->node_count(); i++) {
		if (!affected_node[i] || !graph_->node_active(i)) continue;

		const auto& adj = graph_->neighbors(i);
		bool any_changed = false;
		for (int j = 0; j < (int)adj.size(); j++) {
			float new_cost = graph_->compute_edge_cost(i, adj[j].target,
														ship_radius_, threats_);
			if (new_cost != edge_costs_[i][j]) {
				edge_costs_[i][j] = new_cost;
				any_changed = true;
			}
		}
		if (any_changed) {
			update_vertex(i);
		}
	}
}

// ============================================================================
// Notify specific edges changed (e.g., proxy ring moved)
// ============================================================================

void DStarLite::notify_edges_changed(const std::vector<std::pair<int,int>>& edges) {
	if (!graph_) return;

	for (const auto& [a, b] : edges) {
		// Update cost for a -> b
		int order_ab = find_neighbor_order(a, b);
		if (order_ab >= 0) {
			float new_cost = graph_->compute_edge_cost(a, b, ship_radius_, threats_);
			if (new_cost != edge_costs_[a][order_ab]) {
				edge_costs_[a][order_ab] = new_cost;
				update_vertex(a);
			}
		}
		// Update cost for b -> a
		int order_ba = find_neighbor_order(b, a);
		if (order_ba >= 0) {
			float new_cost = graph_->compute_edge_cost(b, a, ship_radius_, threats_);
			if (new_cost != edge_costs_[b][order_ba]) {
				edge_costs_[b][order_ba] = new_cost;
				update_vertex(b);
			}
		}
	}
}

// ============================================================================
// Advance start — ship moved to next waypoint
// ============================================================================

void DStarLite::advance_start(int new_start) {
	if (!graph_ || new_start < 0 || new_start >= graph_->node_count()) return;
	if (new_start == start_) return;

	km_ += h(start_, new_start);
	start_ = new_start;

	// Recompute may be needed — the key formula changed (km_ and start_ changed).
	// Existing open set entries have stale keys, but D* Lite handles this via
	// the "if k_old < CalculateKey(u)" re-insert check in compute_shortest_path.
}

// ============================================================================
// Path extraction — greedy forward walk from start
// ============================================================================

std::vector<int> DStarLite::extract_path() const {
	std::vector<int> path;
	if (!graph_ || start_ < 0 || goal_ < 0) return path;
	if (g_[start_] >= INF) return path; // no path

	path.push_back(start_);
	int current = start_;
	int max_steps = graph_->node_count() + 1; // safety

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

		if (best_next < 0 || best_cost >= INF) break; // stuck
		path.push_back(best_next);
		current = best_next;
	}

	// Verify path reaches goal
	if (path.empty() || path.back() != goal_) {
		path.clear();
	}

	return path;
}

// ============================================================================
// Queries
// ============================================================================

bool DStarLite::has_path() const {
	if (!graph_ || start_ < 0) return false;
	return g_[start_] < INF;
}

float DStarLite::path_cost() const {
	if (!graph_ || start_ < 0) return INF;
	return g_[start_];
}

} // namespace godot
