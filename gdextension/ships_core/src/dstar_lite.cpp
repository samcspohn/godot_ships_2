#include "dstar_lite.h"
#include "waypoint_graph.h"

#include <algorithm>

namespace godot {

DStarLite::DStarLite() {}
DStarLite::~DStarLite() {}

float DStarLite::h(int a, int b) const {
	return graph_->node_position(a).distance_to(graph_->node_position(b));
}

// Forward search: heuristic is distance from node s to goal_
DStarLite::Key DStarLite::calculate_key(int s) const {
	float min_gr = std::min(g_[s], rhs_[s]);
	return { min_gr + h(s, goal_) + km_,
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

	// Forward D* Lite: start (ship) is the source, rhs[start] = 0
	rhs_[start_] = 0.0f;
	insert_open(start_);
}

void DStarLite::update_vertex(int u) {
	// Forward search: rhs(u) = min over predecessors p of (edge_cost(p→u) + g(p))
	// In our undirected graph, predecessors == neighbors.
	// Node-level detection-circle blocking.
	// If u is inside any threat hard_radius (and is not the source or destination),
	// it is unreachable — set rhs to INF immediately and skip predecessor scan.
	if (u != start_ && u != goal_ && !threats_.empty()) {
		Vector2 pos = graph_->node_position(u);
		for (const auto& tz : threats_) {
			if (pos.distance_squared_to(tz.position) <
					tz.hard_radius * tz.hard_radius) {
				rhs_[u] = INF;
				remove_open(u);
				if (g_[u] != rhs_[u]) insert_open(u);
				return;
			}
		}
	}

	if (u != start_) {
		float best = INF;
		const auto& adj = graph_->neighbors(u);
		for (int j = 0; j < (int)adj.size(); j++) {
			int p = adj[j].target;  // predecessor p
			if (!graph_->node_active(p)) continue;
			// cost of edge p -> u: look up from p's adjacency list
			int order_pu = find_neighbor_order(p, u);
			float cost = edge_cost_cached(p, order_pu);
			float val = cost + g_[p];
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

		// Forward search: terminate when goal is consistent and top >= goal key
		Key goal_key = calculate_key(goal_);
		if (!(top_key < goal_key) && rhs_[goal_] == g_[goal_]) {
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
	if (rhs_[goal_] == g_[goal_]) return true;
	return (iters < max_iterations);
}

void DStarLite::update_threats(const std::vector<ThreatZone>& new_threats) {
	if (!graph_) return;

	std::vector<ThreatZone> old_threats = threats_;
	threats_ = new_threats;

	// Mark nodes that may have changed blocking status:
	// those inside or near old circles (might be unblocked now)
	// and those inside or near new circles (might be newly blocked).
	// Search radius = hard_radius only — we only care about nodes
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
		// Update cached cost for a→b
		int order_ab = find_neighbor_order(a, b);
		if (order_ab >= 0) {
			if (order_ab >= (int)edge_costs_[a].size()) {
				edge_costs_[a].resize(order_ab + 1, INF);
			}
			float new_cost = graph_->compute_edge_cost(a, b, ship_radius_, threats_);
			if (new_cost != edge_costs_[a][order_ab]) {
				edge_costs_[a][order_ab] = new_cost;
				// Edge a→b cost changed: affects rhs of b (forward search)
				update_vertex(b);
			}
		}
		// Update cached cost for b→a
		int order_ba = find_neighbor_order(b, a);
		if (order_ba >= 0) {
			if (order_ba >= (int)edge_costs_[b].size()) {
				edge_costs_[b].resize(order_ba + 1, INF);
			}
			float new_cost = graph_->compute_edge_cost(b, a, ship_radius_, threats_);
			if (new_cost != edge_costs_[b][order_ba]) {
				edge_costs_[b][order_ba] = new_cost;
				// Edge b→a cost changed: affects rhs of a (forward search)
				update_vertex(a);
			}
		}
	}
}

// Forward search: advance_start resets the source to a new node.
// Does NOT accumulate km (km only accumulates when goal advances).
void DStarLite::sync_node_edges(int node, const std::vector<int>& old_adj_neighbors) {
	if (!graph_ || node < 0 || node >= (int)edge_costs_.size()) return;

	// Rebuild the edge-cost cache row to match the current adjacency list
	const auto& adj = graph_->neighbors(node);
	edge_costs_[node].resize(adj.size());
	for (int j = 0; j < (int)adj.size(); j++) {
		edge_costs_[node][j] = graph_->compute_edge_cost(
			node, adj[j].target, ship_radius_, threats_);
	}

	// Update this node's own rhs (its predecessors may have changed)
	update_vertex(node);

	// Update new neighbors — they may now have a cheaper predecessor path through node
	for (const auto& e : adj) {
		if (graph_->node_active(e.target)) {
			update_vertex(e.target);
		}
	}

	// Update old neighbors — they may have lost node as a predecessor
	for (int p : old_adj_neighbors) {
		if (p != node && graph_->node_active(p)) {
			update_vertex(p);
		}
	}
}

void DStarLite::advance_start(int new_start) {
	if (!graph_ || new_start < 0 || new_start >= graph_->node_count()) return;
	if (new_start == start_) return;

	int old_start = start_;
	start_ = new_start;

	// Old start is no longer the source — invalidate it so it can get a real rhs
	rhs_[old_start] = INF;
	g_[old_start] = INF;
	update_vertex(old_start);

	// New start is the source — force rhs=0, inconsistent so it will be expanded
	rhs_[new_start] = 0.0f;
	g_[new_start] = INF;
	insert_open(new_start);
}

// Goal has moved to a new node. Accumulates km per D* Lite spec.
void DStarLite::advance_goal(int new_goal) {
	if (!graph_ || new_goal < 0 || new_goal >= graph_->node_count()) return;
	if (new_goal == goal_) return;

	km_ += h(goal_, new_goal);
	goal_ = new_goal;
	// goal_ is just a termination target — no special rhs seeding needed
	// (rhs is seeded at start_ in forward search)
}

// Extract path: in forward search g values grow from start.
// Trace backward from goal_ to start_ by picking the predecessor
// with minimum (edge_cost(pred→current) + g[pred]), then reverse.
std::vector<int> DStarLite::extract_path() const {
	if (!graph_ || start_ < 0 || goal_ < 0) return {};
	if (g_[goal_] >= INF) return {};

	std::vector<int> path;
	path.push_back(goal_);
	int current = goal_;
	int max_steps = graph_->node_count() + 1;

	while (current != start_ && max_steps-- > 0) {
		const auto& adj = graph_->neighbors(current);
		int best_prev = -1;
		float best_cost = INF;

		for (int j = 0; j < (int)adj.size(); j++) {
			int p = adj[j].target;
			if (!graph_->node_active(p)) continue;
			int order_pu = find_neighbor_order(p, current);
			float c = edge_cost_cached(p, order_pu);
			float val = c + g_[p];
			if (val < best_cost) {
				best_cost = val;
				best_prev = p;
			}
		}

		if (best_prev < 0 || best_cost >= INF) break;
		path.push_back(best_prev);
		current = best_prev;
	}

	if (path.empty() || path.back() != start_) {
		return {};
	}

	std::reverse(path.begin(), path.end());
	return path;
}

bool DStarLite::has_path() const {
	if (!graph_ || goal_ < 0) return false;
	return g_[goal_] < INF;
}

float DStarLite::path_cost() const {
	if (!graph_ || goal_ < 0) return INF;
	return g_[goal_];
}

} // namespace godot
