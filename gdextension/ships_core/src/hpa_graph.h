#ifndef HPA_GRAPH_H
#define HPA_GRAPH_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include "nav_types.h"
#include "navigation_map.h"

namespace godot {

// ---------------------------------------------------------------------------
// Plain data structures (no Godot reflection needed)
// ---------------------------------------------------------------------------

struct AbNode {
	int   id;
	int   cluster_id;
	int   gx, gz;       // grid cell coordinates
	float wx, wz;       // world coordinates
};

struct AbEdge {
	int                  to;
	float                cost;
	int                  via_cluster; // -1 = inter-cluster boundary step
	std::vector<Vector2> waypoints;
};

struct Cluster {
	int  id;
	int  cx, cz;        // cluster grid coordinates
	int  x0, z0;        // inclusive cell range start
	int  x1, z1;        // inclusive cell range end
	std::vector<int> node_ids;
	bool navigable;
};

// ---------------------------------------------------------------------------
// Obstacle record (circular, identified by caller-supplied id)
// ---------------------------------------------------------------------------

struct HpaObstacle {
	int     id;
	Vector2 pos;
	float   radius;
};

// ---------------------------------------------------------------------------
// HpaGraph — Two-level Hierarchical A* navigation graph.
//
// Level 0 : SDF grid cells (stored in NavigationMap).
// Level 1 : Fixed-size rectangular clusters of grid cells.
//
// For each pair of adjacent clusters the shared border is scanned for
// maximal runs of navigable cell pairs.  Each run produces ONE abstract
// "entrance" node on each side of the border, joined by a trivial
// inter-cluster edge (cost = one cell step).
//
// Within each cluster, all pairs of entrance nodes are connected by
// intra-cluster edges whose cost and waypoints are precomputed via
// NavigationMap::find_path_internal().
//
// Dynamic circular obstacles are handled by incrementing a per-cluster
// block count.  Abstract A* simply skips any intra-cluster edge whose
// via_cluster has a positive block count, effectively cutting off whole
// regions with a single array check rather than iterating nodes.
// ---------------------------------------------------------------------------

class HpaGraph : public RefCounted {
	GDCLASS(HpaGraph, RefCounted)

public:
	static constexpr int DEFAULT_CLUSTER_SIZE = 16;

	// ------------------------------------------------------------------
	// Lifecycle
	// ------------------------------------------------------------------

	HpaGraph();
	~HpaGraph();

	// ------------------------------------------------------------------
	// Public API
	// ------------------------------------------------------------------

	/// Build the abstract graph from a pre-built NavigationMap.
	/// cluster_size: number of grid cells per cluster side (default 32).
	/// clearance:    minimum SDF value for a cell to be considered
	///               navigable (ship half-beam in world units).
	void build(Ref<NavigationMap> map, float clearance,
			   int cluster_size = DEFAULT_CLUSTER_SIZE);

	/// Returns true after a successful build().
	bool is_built() const { return built_; }

	/// Find a path from world-space 'from' to 'to'.
	/// Uses HPA connectors for endpoint attachment and does not fall back to
	/// a global grid-level A* if endpoint attachment fails.
	/// For same-cluster, threat-free queries it may still use local grid search.
	PathResult find_path(Vector2 from, Vector2 to) const;

	/// Convenience wrapper — returns only the waypoint positions as a
	/// PackedVector2Array for GDScript callers.
	PackedVector2Array find_path_packed(Vector2 from, Vector2 to) const;

	// Dynamic obstacles ------------------------------------------------

	/// Register a circular obstacle.  All clusters whose axis-aligned
	/// bounding box overlaps (pos, radius) have their block count
	/// incremented; abstract edges that route through those clusters are
	/// skipped until the obstacle is removed.
	void add_obstacle(int id, Vector2 pos, float radius);

	/// Unregister an obstacle by its id.  Block counts are decremented.
	void remove_obstacle(int id);

	/// Unregister all obstacles at once.
	void clear_obstacles();

	// Statistics / debug -----------------------------------------------

	int get_node_count()    const { return static_cast<int>(nodes_.size()); }
	int get_cluster_count() const { return static_cast<int>(clusters_.size()); }

	TypedArray<Dictionary> get_debug_nodes()    const;
	TypedArray<Dictionary> get_debug_edges()    const;
	TypedArray<Dictionary> get_debug_clusters() const;
	// Reads the currently-stamped global blocked state (reflects last stamp_threats call).
	TypedArray<Dictionary> get_debug_threat_clusters() const;
	// Pure query: computes blocked clusters for the given threat set without touching
	// cluster_threat_blocked_.  Always reflects the caller's own threat bin.
	TypedArray<Dictionary> compute_debug_threat_clusters(const std::vector<ThreatCircle> &threats) const;

	// Performance diagnostics (query-time, runtime focused)
	Dictionary get_perf_metrics() const;
	void reset_perf_metrics();
	void set_perf_spike_threshold_us(float threshold_us);
	float get_perf_spike_threshold_us() const;
	void set_perf_tracking_enabled(bool enabled);
	bool is_perf_tracking_enabled() const;

protected:
	static void _bind_methods();

private:
	// ------------------------------------------------------------------
	// Stored graph data
	// ------------------------------------------------------------------

	Ref<NavigationMap>          nav_map_;
	float                       clearance_    = 0.0f;
	int                         cluster_size_ = DEFAULT_CLUSTER_SIZE;

	// Cached grid / cluster layout (populated by build())
	int   grid_w_  = 0;
	int   grid_h_  = 0;
	int   ncx_     = 0;  // number of clusters along X
	int   ncz_     = 0;  // number of clusters along Z
	float cell_size_ = 1.0f;
	float min_x_   = 0.0f;
	float min_z_   = 0.0f;

	std::vector<Cluster>             clusters_;
	std::vector<AbNode>              nodes_;
	std::vector<std::vector<AbEdge>> adj_;   // adj_[node_id]

	// Per-cluster obstacle block counts (parallel to clusters_)
	std::vector<int>                 cluster_block_count_;

	// Per-cluster threat-arc blocked flags (parallel to clusters_).
	// Stamped wholesale each time stamp_threats() is called.
	// Separate from cluster_block_count_ so obstacle blocking and threat
	// blocking can be cleared independently.
	std::vector<uint8_t>             cluster_threat_blocked_;

	// Registered obstacles (keyed by id) for removal
	std::unordered_map<int, HpaObstacle> obstacles_;

	bool built_ = false;

	struct PerfStats {
		uint64_t query_count = 0;
		uint64_t success_count = 0;
		uint64_t failure_count = 0;

		float last_total_us = 0.0f;
		float last_connect_us = 0.0f;
		float last_abstract_us = 0.0f;
		float last_refine_us = 0.0f;
		float last_start_connect_us = 0.0f;
		float last_goal_connect_us = 0.0f;

		float avg_total_us = 0.0f;
		float avg_connect_us = 0.0f;
		float avg_abstract_us = 0.0f;
		float avg_refine_us = 0.0f;

		float max_total_us = 0.0f;
		float max_connect_us = 0.0f;
		float max_abstract_us = 0.0f;
		float max_refine_us = 0.0f;

		int last_connector_los_attempts = 0;
		int last_connector_los_hits = 0;
		int last_connector_local_search_runs = 0;
		int last_connector_local_expansions = 0;
		int last_connector_portal_candidates = 0;

		float avg_connector_los_attempts = 0.0f;
		float avg_connector_los_hits = 0.0f;
		float avg_connector_local_search_runs = 0.0f;
		float avg_connector_local_expansions = 0.0f;
		float avg_connector_portal_candidates = 0.0f;

		float spike_threshold_us = 2500.0f;
		uint64_t spike_count = 0;
		float worst_spike_us = 0.0f;

		float report_interval_s = 5.0f;
		uint64_t last_report_wall_us = 0;
		uint64_t window_queries = 0;
		float window_total_sum_us = 0.0f;
		float window_connect_sum_us = 0.0f;
		float window_abstract_sum_us = 0.0f;
		float window_refine_sum_us = 0.0f;
	};

	mutable PerfStats perf_;
	bool perf_tracking_enabled_ = false;

	// ------------------------------------------------------------------
	// Build helpers
	// ------------------------------------------------------------------

	void build_clusters();
	void build_entrances();
	void build_intracluster_edges();

	// Threat rasterization onto the Level-1 cluster grid.
	// stamp_threats() tests every navigable cluster: clusters within a
	// threat circle that have line-of-sight to the threat origin are marked
	// blocked. clear_threats() zeroes the vector.
public:
	void stamp_threats(const std::vector<ThreatCircle>& threats);
	void clear_threats();
private:

	// ------------------------------------------------------------------
	// Query helpers
	// ------------------------------------------------------------------

	/// Run abstract A* on an (optionally augmented) copy of the graph.
	/// Returns an ordered list of node ids from start to goal,
	/// or an empty vector if no path exists.
	std::vector<int> abstract_astar_impl(
			const std::vector<AbNode>&               nodes,
			const std::vector<std::vector<AbEdge>>&  adj,
			int start,
			int goal) const;

	/// Expand an abstract node-id sequence back into a smooth
	/// world-space PathResult.
	PathResult refine_path_impl(
			const std::vector<int>&                  abs_path,
			const std::vector<AbNode>&               nodes,
			const std::vector<std::vector<AbEdge>>&  adj,
			Vector2 from,
			Vector2 to) const;

	// ------------------------------------------------------------------
	// Inline coordinate / SDF helpers
	// ------------------------------------------------------------------

	inline int cluster_id(int cx, int cz) const {
		return cz * ncx_ + cx;
	}

	inline int cell_cx(int gx) const {
		return std::min(gx / cluster_size_, ncx_ - 1);
	}

	inline int cell_cz(int gz) const {
		return std::min(gz / cluster_size_, ncz_ - 1);
	}

	inline void grid_to_world(int gx, int gz, float &wx, float &wz) const {
		wx = min_x_ + (static_cast<float>(gx) + 0.5f) * cell_size_;
		wz = min_z_ + (static_cast<float>(gz) + 0.5f) * cell_size_;
	}

	inline bool cell_nav(int gx, int gz) const {
		if (gx < 0 || gx >= grid_w_ || gz < 0 || gz >= grid_h_) return false;
		float wx, wz;
		grid_to_world(gx, gz, wx, wz);
		return nav_map_->get_distance(wx, wz) >= clearance_;
	}

	inline bool cluster_blocked(int cid) const {
		if (cid < 0 || cid >= static_cast<int>(cluster_block_count_.size()))
			return false;
		return cluster_block_count_[cid] > 0 || cluster_threat_blocked_[cid] != 0;
	}

	/// Return all cluster ids whose AABB overlaps the circle (pos, radius).
	std::vector<int> clusters_in_radius(Vector2 pos, float radius) const;
};

} // namespace godot

#endif // HPA_GRAPH_H