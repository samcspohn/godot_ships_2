#ifndef WAYPOINT_GRAPH_H
#define WAYPOINT_GRAPH_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <vector>
#include <unordered_map>
#include <utility>

#include "nav_types.h"
#include "navigation_map.h"

namespace godot {

// Edge in the sparse waypoint graph
struct GraphEdge {
	int target;        // target node index
	float base_weight; // Euclidean distance
	float min_sdf;     // minimum terrain SDF sampled along this corridor
};

class WaypointGraph : public RefCounted {
	GDCLASS(WaypointGraph, RefCounted)

public:
	// --- Build parameters ---
	static constexpr float DENSITY_FACTOR = 0.5f;    // sample_radius = SDF * this
	static constexpr float R_MIN_TIGHT = 80.0f;      // min spacing near terrain (meters)
	static constexpr float R_MIN_OPEN = 800.0f;       // max spacing in open ocean (meters)
	static constexpr float NODE_MARGIN = 20.0f;       // extra SDF buffer for node placement
	static constexpr int POISSON_K = 30;              // candidates per active point
	static constexpr int MAX_NEIGHBORS = 12;          // max edges per node
	static constexpr int MIN_NEIGHBORS = 3;           // minimum desired edges per node
	static constexpr float MAX_EDGE_LENGTH = 2500.0f; // max edge distance (meters)
	static constexpr int PROXY_RING_SIZE = 8;         // nodes per proxy ring

private:
	// --- Node data (index = node ID) ---
	std::vector<Vector2> positions_;
	std::vector<std::vector<GraphEdge>> adj_;

	// --- Node flags ---
	std::vector<bool> is_proxy_;
	std::vector<int> proxy_owner_;   // enemy ID for proxy nodes, -1 for static
	std::vector<bool> active_;       // false for removed proxy nodes

	int static_count_ = 0;          // nodes 0..static_count_-1 are permanent

	// --- Proxy ring tracking ---
	struct ProxyRing {
		std::vector<int> node_indices; // PROXY_RING_SIZE node indices
		float radius;
		Vector2 center;
	};
	std::unordered_map<int, ProxyRing> proxy_rings_;

	// --- Navigation map reference (for SDF queries) ---
	Ref<NavigationMap> nav_map_;
	float min_ship_radius_ = 25.0f;

	// --- Spatial grid for nearest-node queries ---
	std::vector<std::vector<int>> spatial_cells_;
	int sp_grid_w_ = 0, sp_grid_h_ = 0;
	float sp_cell_size_ = 0.0f;
	float sp_min_x_ = 0.0f, sp_min_z_ = 0.0f;

	// --- Connected components ---
	std::vector<int> component_;
	int component_count_ = 0;

	// --- Per-node SDF cache (populated during build; used by D* Lite for per-ship filtering) ---
	std::vector<float> node_sdf_;

	// --- Internal helpers ---
	void build_spatial_grid();
	void add_to_spatial_grid(int idx);
	void remove_from_spatial_grid(int idx);

	int spatial_cell_index(float wx, float wz) const;
	std::vector<int> spatial_query(Vector2 pos, float radius) const;

	bool corridor_clear(Vector2 a, Vector2 b, float clearance) const;

	// Scan the corridor from a to b and return the minimum SDF encountered.
	float compute_edge_min_sdf(Vector2 a, Vector2 b) const;
	void connect_node_to_graph(int idx, float clearance,
							   float max_dist = MAX_EDGE_LENGTH);
	void add_edge(int a, int b, float weight);
	void remove_edges_for_node(int idx);

	void compute_components();

	// Poisson disk sampling
	void poisson_disk_sample(float min_radius);
	void densify_corridors(float min_radius);

	// Compute local Poisson disk radius at a world position
	float sample_radius_at(Vector2 pos) const;

protected:
	static void _bind_methods();

public:
	WaypointGraph();
	~WaypointGraph();

	// --- Build ---
	void build(Ref<NavigationMap> map, float min_ship_radius);
	bool is_built() const { return static_count_ > 0; }

	// --- Node queries ---
	int node_count() const { return (int)positions_.size(); }
	int static_node_count() const { return static_count_; }
	Vector2 node_position(int idx) const;
	bool node_active(int idx) const;
	float node_sdf(int idx) const;     // SDF at this node's position (> 0 = open water)
	bool node_is_proxy(int idx) const;
	int node_proxy_owner(int idx) const;
	const std::vector<GraphEdge>& neighbors(int idx) const;
	int node_component(int idx) const;
	bool same_component(int a, int b) const;

	// --- Spatial queries ---
	int find_nearest_node(Vector2 pos, int required_component = -1) const;
	std::vector<std::pair<int,int>> get_edges_near(Vector2 pos, float radius) const;

	// --- Edge cost computation ---
	// Straight-line check from arbitrary world position to another,
	// considering terrain only. Returns true if clear.
	bool straight_line_clear(Vector2 from, Vector2 to, float ship_radius) const;

	// --- Proxy ring management ---
	// Add 8 proxy nodes around an enemy ship. Returns their node indices.
	Array add_proxy_ring(int enemy_id, Vector2 center, float radius);
	void update_proxy_ring(int enemy_id, Vector2 new_center);
	void remove_proxy_ring(int enemy_id);
	bool has_proxy_ring(int enemy_id) const;
	void clear_proxy_rings();

	// --- Accessors ---
	Ref<NavigationMap> get_nav_map() const { return nav_map_; }

	// --- Debug / visualization (GDScript) ---
	PackedVector2Array get_all_positions() const;
	int get_edge_count() const;
	TypedArray<Dictionary> get_debug_edges() const;
	PackedVector2Array get_proxy_positions(int enemy_id) const;
};

} // namespace godot

#endif // WAYPOINT_GRAPH_H
