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

struct Cluster {
	int   id;
	int   cx, cz;        // cluster grid coordinates
	int   x0, z0;        // inclusive cell range start
	int   x1, z1;        // inclusive cell range end
	int   sub_x0, sub_z0; // inclusive sub-cluster grid range start (level 1.5)
	int   sub_x1, sub_z1; // inclusive sub-cluster grid range end
	float max_sdf;       // max SDF in cluster  (most open water cell)
	float min_sdf;       // min SDF in cluster  (closest to land)
	float wx_center;     // world X of cluster centre
	float wz_center;     // world Z of cluster centre
	bool  navigable;     // max_sdf >= build clearance
};

// ---------------------------------------------------------------------------
// SubCluster — finer-granularity routing primitive (Level 1.5).
//
// Sized to roughly match the agent's clearance scale: with 50 m cells and a
// typical capital-ship clearance of ~200 m, a 4×4 sub is exactly one
// ship-clearance wide.  Every macro Cluster contains an integer number of
// sub-clusters (cluster_size_ must be divisible by sub_size_).
//
// Sub-cluster A* fills the gap between coarse cluster A* and per-cell A*,
// drastically reducing the cell-grid work for ships whose physical scale
// makes 50 m positioning decisions meaningless.
// ---------------------------------------------------------------------------

struct SubCluster {
	int   id;
	int   parent_cid;    // owning macro cluster id
	int   scx, scz;      // sub-cluster grid coordinates (global)
	int   x0, z0;        // inclusive cell range start (clamped to grid bounds)
	int   x1, z1;        // inclusive cell range end
	float max_sdf;       // max SDF in sub  (most open cell)
	float min_sdf;       // min SDF in sub  (closest to land)
	float wx_center;     // world X of sub centre
	float wz_center;     // world Z of sub centre
	bool  navigable;     // max_sdf >= build clearance
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
// HpaGraph — Cluster-grid hierarchical navigation graph.
//
// Level 0 : SDF grid cells (stored in NavigationMap).
// Level 1 : Fixed-size rectangular clusters.
//
// Each cluster stores max_sdf and min_sdf (scanned at build time).
// No portal/entrance nodes are precomputed.
//
// find_path(from, to, q_cl):
//   1. Direct LOS shortcut with q_cl.
//   2. A* over the cluster grid — skips clusters whose max_sdf < q_cl
//      (no navigable cell for this ship).
//   3. Assembles waypoints from open-water cluster centres; terrain
//      clusters are bridged by NavigationMap::find_path_internal.
//   4. Greedy string-pulling with q_cl to remove redundant waypoints.
//
// "Open water" cluster: min_sdf >= q_cl (all cells safe for this ship).
// "Terrain" cluster   : max_sdf >= q_cl but min_sdf < q_cl (has land).
// "Impassable"        : max_sdf < q_cl (no navigable cell).
//
// Dynamic circular obstacles are handled by per-cluster block counts.
// ---------------------------------------------------------------------------

class HpaGraph : public RefCounted {
	GDCLASS(HpaGraph, RefCounted)

public:
	static constexpr int DEFAULT_CLUSTER_SIZE = 16;
	static constexpr int DEFAULT_SUB_SIZE     = 4;

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
	/// query_clearance: ship clearance (ship_length/2 + ship_beam).  When
	/// <= 0, falls back to the clearance passed to build().
	PathResult find_path(Vector2 from, Vector2 to,
						 float query_clearance = -1.0f) const;

	/// Convenience wrapper — returns only the waypoint positions as a
	/// PackedVector2Array for GDScript callers.
	PackedVector2Array find_path_packed(Vector2 from, Vector2 to,
										 float query_clearance = -1.0f) const;

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

	// No portal nodes in the new design; returns 0 for backward compat.
	int get_node_count()    const { return 0; }
	int get_cluster_count() const { return static_cast<int>(clusters_.size()); }
	int get_sub_cluster_count() const { return static_cast<int>(sub_clusters_.size()); }

	TypedArray<Dictionary> get_debug_nodes()    const;
	TypedArray<Dictionary> get_debug_edges()    const;
	TypedArray<Dictionary> get_debug_clusters() const;
	TypedArray<Dictionary> get_debug_sub_clusters() const;
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
	int                         sub_size_     = DEFAULT_SUB_SIZE;
	int                         subs_per_macro_side_ = DEFAULT_CLUSTER_SIZE / DEFAULT_SUB_SIZE;

	// Cached grid / cluster layout (populated by build())
	int   grid_w_  = 0;
	int   grid_h_  = 0;
	int   ncx_     = 0;  // number of clusters along X
	int   ncz_     = 0;  // number of clusters along Z
	int   nsubx_   = 0;  // number of sub-clusters along X (= ncx_ * subs_per_macro_side_)
	int   nsubz_   = 0;  // number of sub-clusters along Z
	float cell_size_ = 1.0f;
	float min_x_   = 0.0f;
	float min_z_   = 0.0f;

	std::vector<Cluster>             clusters_;
	std::vector<SubCluster>          sub_clusters_;

	// Per-cluster obstacle block counts (parallel to clusters_)
	std::vector<int>                 cluster_block_count_;

	// Per-cluster threat-arc blocked flags (parallel to clusters_).
	// Stamped wholesale each time stamp_threats() is called.
	// Separate from cluster_block_count_ so obstacle blocking and threat
	// blocking can be cleared independently.
	std::vector<uint8_t>             cluster_threat_blocked_;

	// Compact list of currently threat-blocked cluster ids.  Rebuilt by
	// stamp_threats()/clear_threats() in lock-step with cluster_threat_blocked_,
	// so threat_clear() iterates only the small subset instead of every cluster.
	std::vector<int>                 threat_blocked_cids_;

	// O(1) cached count of currently threat-blocked clusters; replaces the
	// per-query linear scan that used to compute threat_layer_active.
	int                              threat_blocked_count_ = 0;

	// Precomputed cluster A* step costs (cardinal / diagonal).  Set in build().
	float                            cardinal_step_cost_ = 0.0f;
	float                            diagonal_step_cost_ = 0.0f;

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
	void build_sub_clusters();

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

	/// A* over the cluster grid.  Returns ordered cluster IDs from
	/// from_cid to to_cid (inclusive), or empty if no path exists.
	/// Clusters with max_sdf < q_cl are treated as impassable.
	std::vector<int> cluster_astar(
			int from_cid, int to_cid, float q_cl) const;

	/// A* over the sub-cluster grid.  Returns ordered sub-cluster IDs from
	/// from_sid to to_sid (inclusive), or empty if no path exists.
	/// Sub-clusters with max_sdf < q_cl are treated as impassable.
	/// If allowed_macros is non-null, only sub-clusters whose parent_cid bit
	/// is set in the supplied per-macro mask are considered passable.  This
	/// constrains the search to a corridor of macros along an abstract path.
	std::vector<int> sub_cluster_astar(
			int from_sid, int to_sid, float q_cl,
			const std::vector<uint8_t>* allowed_macros = nullptr) const;

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

	// --- Sub-cluster indexing ---

	inline int sub_id(int scx, int scz) const {
		return scz * nsubx_ + scx;
	}

	inline int cell_scx(int gx) const {
		return std::min(gx / sub_size_, nsubx_ - 1);
	}

	inline int cell_scz(int gz) const {
		return std::min(gz / sub_size_, nsubz_ - 1);
	}

	inline void grid_to_world(int gx, int gz, float &wx, float &wz) const {
		wx = min_x_ + (static_cast<float>(gx) + 0.5f) * cell_size_;
		wz = min_z_ + (static_cast<float>(gz) + 0.5f) * cell_size_;
	}

	// cell_nav: kept for obstacle helpers that still need it.
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

	/// Corridor-constrained cell A* used by HPA refinement when LOS/sub-cluster
	/// connectors cannot directly bridge a guide segment.
	PathResult constrained_cell_astar(
			Vector2 from, Vector2 to, float q_cl,
			const std::vector<uint8_t> &allowed_macros) const;

	/// Return all cluster ids whose AABB overlaps the circle (pos, radius).
	std::vector<int> clusters_in_radius(Vector2 pos, float radius) const;
};

} // namespace godot

#endif // HPA_GRAPH_H