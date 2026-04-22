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



void DStarLite::initialize(const WaypointGraph* graph, int start, int goal,
						   float ship_radius,
						   const std::vector<ThreatZone>& threat_zones,
						   const ThreatGrid* threat_grid) {
	graph_ = graph;
	start_ = start;
	goal_ = goal;
	km_ = 0.0f;
	ship_radius_ = ship_radius;
	threat_zones_ = threat_zones;
	threat_grid_ = threat_grid;

	int n = graph_->node_count();

	g_.assign(n, INF);
	rhs_.assign(n, INF);
	in_open_.assign(n, false);
	stored_key_.resize(n);
	open_set_.clear();

	// Backward D* Lite: goal_ is the source, rhs[goal_] = 0
	rhs_[goal_] = 0.0f;
	insert_open(goal_);
}

void DStarLite::update_vertex(int u) {
	// Backward search: rhs(u) = min over successors s of (edge_cost(u->s) + g(s))
	// In our undirected graph, successors == neighbors.
	// Per-ship node-level filters: skip nodes too close to terrain or inside a threat zone.
	// start_ is exempt so the ship can always plan outward from its current position.
	if (u != goal_ && u != start_) {
		// SDF-based terrain clearance: block nodes whose terrain margin is narrower than
		// this ship's radius.  This replaces the old per-ship build-time node exclusion.
		if (graph_->node_sdf(u) < ship_radius_) {
			rhs_[u] = INF;
			remove_open(u);
			if (g_[u] != rhs_[u]) insert_open(u);
			return;
		}

		// Threat zone (detection circle) blocking — grid-accelerated.
		// The grid buckets threats by hard_radius, so candidates returned by
		// query_point(pos) are the only zones whose bbox covers pos. We still
		// do the exact distance check per candidate.
		if (!threat_zones_.empty()) {
			Vector2 pos = graph_->node_position(u);
			bool blocked = false;
			if (threat_grid_ && !threat_grid_->empty()) {
				const auto& candidates = threat_grid_->query_point(pos);
				for (int ti : candidates) {
					const auto& tz = threat_zones_[ti];
					float dx = pos.x - tz.position.x;
					float dz = pos.y - tz.position.y;
					if (dx * dx + dz * dz < tz.hard_radius * tz.hard_radius) {
						blocked = true;
						break;
					}
				}
			} else {
				for (const auto& tz : threat_zones_) {
					float dx = pos.x - tz.position.x;
					float dz = pos.y - tz.position.y;
					if (dx * dx + dz * dz < tz.hard_radius * tz.hard_radius) {
						blocked = true;
						break;
					}
				}
			}
			if (blocked) {
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
		for (const auto& e : adj) {
			if (!graph_->node_active(e.target)) continue;
			// Per-ship edge traversability: corridor must be wide enough for this ship.
			if (e.min_sdf < ship_radius_) continue;
			float val = e.base_weight + g_[e.target];
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

void DStarLite::update_threats(const std::vector<ThreatZone>& new_zones,
							   const ThreatGrid* new_grid) {
	if (!graph_) return;

	std::vector<ThreatZone> old_zones = std::move(threat_zones_);
	threat_zones_ = new_zones;
	threat_grid_ = new_grid;

	// Candidate set: every node inside the hard_radius of any old or new zone.
	// Per-zone get_edges_near queries the graph's own spatial grid — one call
	// per zone, bounded by the zone's own radius (tight).  The navigator
	// rebuilds its threat grid in-place before calling us, so we only have
	// a ThreatGrid snapshot for the NEW zone set, not the old one.
	std::vector<bool> affected(graph_->node_count(), false);
	auto mark_zone = [&](const ThreatZone& tz) {
		auto near = graph_->get_edges_near(tz.position, tz.hard_radius);
		for (const auto& [a, b] : near) {
			affected[a] = true;
			affected[b] = true;
		}
	};
	for (const auto& tz : old_zones) mark_zone(tz);
	for (const auto& tz : new_zones) mark_zone(tz);

	// Narrow: only nodes whose blocking state actually flipped need
	// update_vertex. Most ticks have small zone movements with no flips, so
	// this skips the bulk of work.
	// - was_blocked: linear over old_zones (no snapshot grid).
	// - is_blocked_now: grid->query_point → O(1) bucket of candidate zones
	//   followed by exact distance checks. Same pattern as update_vertex.
	auto was_blocked = [&](Vector2 pos) -> bool {
		for (const auto& tz : old_zones) {
			float dx = pos.x - tz.position.x;
			float dz = pos.y - tz.position.y;
			if (dx * dx + dz * dz < tz.hard_radius * tz.hard_radius) return true;
		}
		return false;
	};
	auto is_blocked_now = [&](Vector2 pos) -> bool {
		if (new_zones.empty()) return false;
		if (threat_grid_ && !threat_grid_->empty()) {
			const auto& cands = threat_grid_->query_point(pos);
			for (int ti : cands) {
				const auto& tz = new_zones[ti];
				float dx = pos.x - tz.position.x;
				float dz = pos.y - tz.position.y;
				if (dx * dx + dz * dz < tz.hard_radius * tz.hard_radius) return true;
			}
			return false;
		}
		for (const auto& tz : new_zones) {
			float dx = pos.x - tz.position.x;
			float dz = pos.y - tz.position.y;
			if (dx * dx + dz * dz < tz.hard_radius * tz.hard_radius) return true;
		}
		return false;
	};

	for (int i = 0; i < graph_->node_count(); i++) {
		if (!affected[i] || !graph_->node_active(i)) continue;
		Vector2 pos = graph_->node_position(i);
		if (was_blocked(pos) == is_blocked_now(pos)) continue;
		update_vertex(i);
	}
}

void DStarLite::notify_edges_changed(const std::vector<std::pair<int,int>>& edges) {
	if (!graph_) return;
	// min_sdf values are already updated in the graph by WaypointGraph::update_proxy_ring.
	// Just re-evaluate rhs for the endpoints so D* Lite repairs propagate.
	for (const auto& [a, b] : edges) {
		if (a >= 0 && a < graph_->node_count() && graph_->node_active(a))
			update_vertex(a);
		if (b >= 0 && b < graph_->node_count() && graph_->node_active(b))
			update_vertex(b);
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
		for (const auto& e : adj) {
			if (!graph_->node_active(e.target)) continue;
			if (e.min_sdf < ship_radius_) continue;
			float val = e.base_weight + g_[e.target];
			if (val < best_cost) {
				best_cost = val;
				best_next = e.target;
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