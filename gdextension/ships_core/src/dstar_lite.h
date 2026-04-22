#ifndef DSTAR_LITE_H
#define DSTAR_LITE_H

#include <vector>
#include <set>
#include <cmath>
#include <limits>

#include "nav_types.h"


namespace godot {

class WaypointGraph;

// D* Lite incremental heuristic search -- one instance per ship.
//
// Searches BACKWARD from goal to ship (classic D* Lite formulation).
// g(s) = estimated cost from node s TO the goal.
// When edge costs change (detection circles move), only the locally
// affected subgraph is repaired.
//
// Key points:
//   - rhs[goal_] = 0  (goal is the source/seed)
//   - heuristic is h(start_, s)  -- distance from s toward the ship
//   - km accumulates when START advances (ship moves to next waypoint)
class DStarLite {
public:
	struct Key {
		float k1, k2;
		bool operator<(const Key& o) const {
			return k1 < o.k1 || (k1 == o.k1 && k2 < o.k2);
		}
		bool operator==(const Key& o) const {
			return k1 == o.k1 && k2 == o.k2;
		}
	};

private:
	static constexpr float INF = std::numeric_limits<float>::infinity();

	// Graph reference (not owned)
	const WaypointGraph* graph_ = nullptr;



	// Per-node state
	// g_[s]   = current best known cost from s TO goal
	// rhs_[s] = one-step lookahead value (min over successors)
	std::vector<float> g_;
	std::vector<float> rhs_;

	// Priority queue: ordered set of (key, node_index)
	std::set<std::pair<Key, int>> open_set_;

	// Track open-set membership and stored keys (for O(log n) removal)
	std::vector<bool> in_open_;
	std::vector<Key> stored_key_;

	// Search endpoints
	int start_ = -1;   // ship current nearest node (termination check)
	int goal_  = -1;   // destination node (source, rhs=0)
	float km_  = 0.0f; // key modifier -- accumulates when start_ advances

	// Ship parameters for edge cost computation
	float ship_radius_ = 25.0f;

	// Current threat list (per-ship concealment zones, plain circles)
	std::vector<ThreatZone> threat_zones_;

	// --- Internal methods ---

	float h(int a, int b) const;
	Key calculate_key(int s) const;

	void insert_open(int s);
	void remove_open(int s);

	// D* Lite UpdateVertex operation (backward formulation)
	void update_vertex(int u);



public:
	DStarLite();
	~DStarLite();

	// --- Initialization ---

	// Set up for a new path query. Computes all edge costs and runs initial search.
	void initialize(const WaypointGraph* graph, int start, int goal,
					float ship_radius,
					const std::vector<ThreatZone>& threat_zones);

	// --- Core search ---

	// Continue/complete the search with an iteration budget.
	// Returns true when converged (path found or no path exists).
	bool compute_shortest_path(int max_iterations = 100000);

	// --- Incremental updates ---

	// Call when threat zones change. Recomputes affected node blocking
	// and marks dirty nodes for repair.
	void update_threats(const std::vector<ThreatZone>& new_zones);

	// Call when proxy node positions have changed. Recomputes costs
	// for the specified edges.
	void notify_edges_changed(const std::vector<std::pair<int,int>>& edges);

	// Ship advanced to a new nearest waypoint node.
	// Accumulates km_ += h(old_start, new_start) per D* Lite spec,
	// then updates start_. No rhs/g reset needed -- start is only the
	// termination point, not the source seed.
	void advance_start(int new_start);

	// --- Path extraction ---

	// Extract the current shortest path as a sequence of node indices
	// (start -> ... -> goal). Returns empty if no path exists.
	std::vector<int> extract_path() const;

	// Does a valid path to goal exist?
	bool has_path() const;

	// Cost from start to goal (INF if no path).
	float path_cost() const;

	// --- Queries ---

	bool is_initialized() const { return graph_ != nullptr && goal_ >= 0; }
	int get_start() const { return start_; }
	int get_goal() const { return goal_; }
	const std::vector<ThreatZone>& get_threat_zones() const { return threat_zones_; }
};

} // namespace godot

#endif // DSTAR_LITE_H