#include "waypoint_graph.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <random>
#include <numeric>

namespace godot {

static constexpr float INF_COST = std::numeric_limits<float>::infinity();

// ============================================================================
// Construction / destruction
// ============================================================================

WaypointGraph::WaypointGraph() {}
WaypointGraph::~WaypointGraph() {}

// ============================================================================
// GDScript bindings
// ============================================================================

void WaypointGraph::_bind_methods() {
	ClassDB::bind_method(D_METHOD("build", "nav_map", "min_ship_radius"), &WaypointGraph::build);
	ClassDB::bind_method(D_METHOD("is_built"), &WaypointGraph::is_built);
	ClassDB::bind_method(D_METHOD("node_count"), &WaypointGraph::node_count);
	ClassDB::bind_method(D_METHOD("static_node_count"), &WaypointGraph::static_node_count);
	ClassDB::bind_method(D_METHOD("get_all_positions"), &WaypointGraph::get_all_positions);
	ClassDB::bind_method(D_METHOD("get_edge_count"), &WaypointGraph::get_edge_count);
	ClassDB::bind_method(D_METHOD("get_debug_edges"), &WaypointGraph::get_debug_edges);

	ClassDB::bind_method(D_METHOD("add_proxy_ring", "enemy_id", "center", "radius"),
						 &WaypointGraph::add_proxy_ring);
	ClassDB::bind_method(D_METHOD("update_proxy_ring", "enemy_id", "new_center"),
						 &WaypointGraph::update_proxy_ring);
	ClassDB::bind_method(D_METHOD("remove_proxy_ring", "enemy_id"),
						 &WaypointGraph::remove_proxy_ring);
	ClassDB::bind_method(D_METHOD("has_proxy_ring", "enemy_id"),
						 &WaypointGraph::has_proxy_ring);
	ClassDB::bind_method(D_METHOD("clear_proxy_rings"),
						 &WaypointGraph::clear_proxy_rings);
	ClassDB::bind_method(D_METHOD("get_proxy_positions", "enemy_id"),
						 &WaypointGraph::get_proxy_positions);
}

// ============================================================================
// Build — main entry point
// ============================================================================

void WaypointGraph::build(Ref<NavigationMap> map, float min_ship_radius) {
	if (map.is_null() || !map->is_built()) {
		UtilityFunctions::print("[WaypointGraph] Cannot build: NavigationMap is null or not built");
		return;
	}

	// Clear previous data
	positions_.clear();
	adj_.clear();
	is_proxy_.clear();
	proxy_owner_.clear();
	active_.clear();
	proxy_rings_.clear();
	component_.clear();
	static_count_ = 0;
	component_count_ = 0;

	nav_map_ = map;
	min_ship_radius_ = min_ship_radius;

	// Phase 1: Poisson disk sampling (SDF-weighted density)
	poisson_disk_sample(min_ship_radius);

	// Phase 2: Narrow corridor densification
	densify_corridors(min_ship_radius);

	static_count_ = (int)positions_.size();

	// Initialize metadata for static nodes
	is_proxy_.resize(static_count_, false);
	proxy_owner_.resize(static_count_, -1);
	active_.resize(static_count_, true);

	UtilityFunctions::print("[WaypointGraph] Placed ", static_count_, " static waypoint nodes");

	// Build spatial index
	build_spatial_grid();

	// Phase 3: Edge construction
	adj_.resize(static_count_);
	for (int i = 0; i < static_count_; i++) {
		connect_node_to_graph(i, min_ship_radius);
	}

	int total_edges = get_edge_count();
	UtilityFunctions::print("[WaypointGraph] Built ", total_edges, " edges");

	// Phase 4: Connected component labeling
	compute_components();

	UtilityFunctions::print("[WaypointGraph] Found ", component_count_, " connected components");
}

// ============================================================================
// Poisson disk sampling — SDF-weighted density
// ============================================================================

float WaypointGraph::sample_radius_at(Vector2 pos) const {
	float sdf = nav_map_->get_distance(pos.x, pos.y);
	float r = sdf * DENSITY_FACTOR;
	if (r < R_MIN_TIGHT) r = R_MIN_TIGHT;
	if (r > R_MIN_OPEN) r = R_MIN_OPEN;
	return r;
}

void WaypointGraph::poisson_disk_sample(float min_radius) {
	float min_x = nav_map_->get_min_x();
	float min_z = nav_map_->get_min_z();
	float max_x = min_x + (nav_map_->get_grid_width() - 1) * nav_map_->get_cell_size_value();
	float max_z = min_z + (nav_map_->get_grid_height() - 1) * nav_map_->get_cell_size_value();

	float navigable_threshold = min_radius + NODE_MARGIN;

	// Background grid for fast proximity checks (cell size = R_MIN_TIGHT / sqrt(2))
	float bg_cell = R_MIN_TIGHT / 1.41421356f;
	int bg_w = std::max(1, (int)std::ceil((max_x - min_x) / bg_cell));
	int bg_h = std::max(1, (int)std::ceil((max_z - min_z) / bg_cell));

	// -1 = empty, otherwise node index
	std::vector<std::vector<int>> bg_grid(bg_w * bg_h);

	auto bg_idx = [&](float wx, float wz) -> int {
		int cx = std::clamp((int)((wx - min_x) / bg_cell), 0, bg_w - 1);
		int cz = std::clamp((int)((wz - min_z) / bg_cell), 0, bg_h - 1);
		return cz * bg_w + cx;
	};

	auto too_close = [&](Vector2 candidate) -> bool {
		float r_cand = sample_radius_at(candidate);
		int cx = std::clamp((int)((candidate.x - min_x) / bg_cell), 0, bg_w - 1);
		int cz = std::clamp((int)((candidate.y - min_z) / bg_cell), 0, bg_h - 1);

		// Search cells within r_cand radius
		int search_cells = std::max(1, (int)std::ceil(r_cand / bg_cell)) + 1;
		for (int dz = -search_cells; dz <= search_cells; dz++) {
			for (int dx = -search_cells; dx <= search_cells; dx++) {
				int nx = cx + dx;
				int nz = cz + dz;
				if (nx < 0 || nx >= bg_w || nz < 0 || nz >= bg_h) continue;
				for (int ni : bg_grid[nz * bg_w + nx]) {
					float min_dist = std::min(r_cand, sample_radius_at(positions_[ni]));
					if (candidate.distance_to(positions_[ni]) < min_dist) {
						return true;
					}
				}
			}
		}
		return false;
	};

	std::mt19937 rng(42); // deterministic seed
	std::uniform_real_distribution<float> unit(0.0f, 1.0f);

	// Find a seed point: scan grid for first navigable cell
	Vector2 seed;
	bool found_seed = false;
	float step = R_MIN_TIGHT;
	for (float z = min_z + step; z < max_z && !found_seed; z += step) {
		for (float x = min_x + step; x < max_x && !found_seed; x += step) {
			if (nav_map_->get_distance(x, z) > navigable_threshold) {
				seed = Vector2(x, z);
				found_seed = true;
			}
		}
	}

	if (!found_seed) {
		UtilityFunctions::print("[WaypointGraph] No navigable area found for seeding");
		return;
	}

	positions_.push_back(seed);
	bg_grid[bg_idx(seed.x, seed.y)].push_back(0);

	std::vector<int> active_list;
	active_list.push_back(0);

	while (!active_list.empty()) {
		// Pick random active point
		int ai = (int)(unit(rng) * active_list.size());
		if (ai >= (int)active_list.size()) ai = (int)active_list.size() - 1;
		int pi = active_list[ai];
		Vector2 p = positions_[pi];
		float r = sample_radius_at(p);

		bool accepted_any = false;
		for (int k = 0; k < POISSON_K; k++) {
			// Random point in annulus [r, 2r]
			float angle = unit(rng) * 6.28318530f;
			float dist = r + unit(rng) * r;
			Vector2 candidate(p.x + std::cos(angle) * dist,
							  p.y + std::sin(angle) * dist);

			// Bounds check
			if (candidate.x < min_x || candidate.x > max_x ||
				candidate.y < min_z || candidate.y > max_z) continue;

			// Navigability check
			if (nav_map_->get_distance(candidate.x, candidate.y) < navigable_threshold) continue;

			// Proximity check
			if (too_close(candidate)) continue;

			// Accept
			int new_idx = (int)positions_.size();
			positions_.push_back(candidate);
			bg_grid[bg_idx(candidate.x, candidate.y)].push_back(new_idx);
			active_list.push_back(new_idx);
			accepted_any = true;
		}

		if (!accepted_any) {
			// Remove from active list (swap with last)
			active_list[ai] = active_list.back();
			active_list.pop_back();
		}
	}
}

// ============================================================================
// Corridor densification — force nodes into tight straits
// ============================================================================

void WaypointGraph::densify_corridors(float min_radius) {
	float min_x = nav_map_->get_min_x();
	float min_z = nav_map_->get_min_z();
	float cell_size = nav_map_->get_cell_size_value();
	int gw = nav_map_->get_grid_width();
	int gh = nav_map_->get_grid_height();

	float low = min_radius;
	float high = min_radius * 3.0f;
	float min_spacing = R_MIN_TIGHT * 0.5f;

	for (int gz = 0; gz < gh; gz++) {
		for (int gx = 0; gx < gw; gx++) {
			float wx = min_x + gx * cell_size;
			float wz = min_z + gz * cell_size;
			float d = nav_map_->get_distance(wx, wz);

			// Critical chokepoint: barely navigable
			if (d <= low || d >= high) continue;

			Vector2 candidate(wx, wz);

			// Check if any existing node is within min_spacing
			bool has_nearby = false;
			for (const auto& pos : positions_) {
				if (candidate.distance_to(pos) < min_spacing) {
					has_nearby = true;
					break;
				}
			}

			if (!has_nearby) {
				positions_.push_back(candidate);
			}
		}
	}
}

// ============================================================================
// Spatial grid
// ============================================================================

void WaypointGraph::build_spatial_grid() {
	if (positions_.empty() || nav_map_.is_null()) return;

	float min_x = nav_map_->get_min_x();
	float min_z = nav_map_->get_min_z();
	float max_x = min_x + (nav_map_->get_grid_width() - 1) * nav_map_->get_cell_size_value();
	float max_z = min_z + (nav_map_->get_grid_height() - 1) * nav_map_->get_cell_size_value();

	sp_min_x_ = min_x;
	sp_min_z_ = min_z;
	sp_cell_size_ = R_MIN_OPEN; // large cells for fast range queries
	sp_grid_w_ = std::max(1, (int)std::ceil((max_x - min_x) / sp_cell_size_) + 1);
	sp_grid_h_ = std::max(1, (int)std::ceil((max_z - min_z) / sp_cell_size_) + 1);

	spatial_cells_.clear();
	spatial_cells_.resize(sp_grid_w_ * sp_grid_h_);

	for (int i = 0; i < (int)positions_.size(); i++) {
		add_to_spatial_grid(i);
	}
}

int WaypointGraph::spatial_cell_index(float wx, float wz) const {
	int cx = std::clamp((int)((wx - sp_min_x_) / sp_cell_size_), 0, sp_grid_w_ - 1);
	int cz = std::clamp((int)((wz - sp_min_z_) / sp_cell_size_), 0, sp_grid_h_ - 1);
	return cz * sp_grid_w_ + cx;
}

void WaypointGraph::add_to_spatial_grid(int idx) {
	if (sp_grid_w_ <= 0) return;
	int ci = spatial_cell_index(positions_[idx].x, positions_[idx].y);
	spatial_cells_[ci].push_back(idx);
}

void WaypointGraph::remove_from_spatial_grid(int idx) {
	if (sp_grid_w_ <= 0) return;
	int ci = spatial_cell_index(positions_[idx].x, positions_[idx].y);
	auto& cell = spatial_cells_[ci];
	cell.erase(std::remove(cell.begin(), cell.end(), idx), cell.end());
}

std::vector<int> WaypointGraph::spatial_query(Vector2 pos, float radius) const {
	std::vector<int> result;
	if (sp_grid_w_ <= 0) return result;

	int search_cells = std::max(1, (int)std::ceil(radius / sp_cell_size_)) + 1;
	int cx = std::clamp((int)((pos.x - sp_min_x_) / sp_cell_size_), 0, sp_grid_w_ - 1);
	int cz = std::clamp((int)((pos.y - sp_min_z_) / sp_cell_size_), 0, sp_grid_h_ - 1);
	float r2 = radius * radius;

	for (int dz = -search_cells; dz <= search_cells; dz++) {
		int nz = cz + dz;
		if (nz < 0 || nz >= sp_grid_h_) continue;
		for (int dx = -search_cells; dx <= search_cells; dx++) {
			int nx = cx + dx;
			if (nx < 0 || nx >= sp_grid_w_) continue;
			for (int ni : spatial_cells_[nz * sp_grid_w_ + nx]) {
				if (!active_[ni]) continue;
				if (pos.distance_squared_to(positions_[ni]) <= r2) {
					result.push_back(ni);
				}
			}
		}
	}
	return result;
}

// ============================================================================
// Edge construction
// ============================================================================

bool WaypointGraph::corridor_clear(Vector2 a, Vector2 b, float clearance) const {
	if (nav_map_.is_null()) return false;
	RayResult ray = nav_map_->raycast_internal(a, b, clearance);
	return !ray.hit;
}

void WaypointGraph::add_edge(int a, int b, float weight) {
	// Check for duplicate
	for (const auto& e : adj_[a]) {
		if (e.target == b) return;
	}
	adj_[a].push_back({b, weight});
	adj_[b].push_back({a, weight});
}

void WaypointGraph::remove_edges_for_node(int idx) {
	// Remove all edges from this node
	for (const auto& e : adj_[idx]) {
		auto& other_adj = adj_[e.target];
		other_adj.erase(
			std::remove_if(other_adj.begin(), other_adj.end(),
						   [idx](const GraphEdge& ge) { return ge.target == idx; }),
			other_adj.end());
	}
	adj_[idx].clear();
}

void WaypointGraph::connect_node_to_graph(int idx, float clearance, float max_dist) {
	// Find candidates within max_dist using spatial grid
	auto candidates = spatial_query(positions_[idx], max_dist);

	// Sort by distance
	std::sort(candidates.begin(), candidates.end(), [&](int a, int b) {
		return positions_[idx].distance_squared_to(positions_[a]) <
			   positions_[idx].distance_squared_to(positions_[b]);
	});

	int connected = 0;
	for (int ci : candidates) {
		if (ci == idx) continue;
		if (connected >= MAX_NEIGHBORS) break;

		// Already connected?
		bool already = false;
		for (const auto& e : adj_[idx]) {
			if (e.target == ci) { already = true; break; }
		}
		if (already) { connected++; continue; }

		// Corridor validation
		if (corridor_clear(positions_[idx], positions_[ci], clearance)) {
			float dist = positions_[idx].distance_to(positions_[ci]);
			add_edge(idx, ci, dist);
			connected++;
		}
	}

	// If under-connected, try longer range
	if (connected < MIN_NEIGHBORS) {
		auto extended = spatial_query(positions_[idx], max_dist * 2.0f);
		std::sort(extended.begin(), extended.end(), [&](int a, int b) {
			return positions_[idx].distance_squared_to(positions_[a]) <
				   positions_[idx].distance_squared_to(positions_[b]);
		});

		for (int ci : extended) {
			if (ci == idx) continue;
			if (connected >= MIN_NEIGHBORS) break;

			bool already = false;
			for (const auto& e : adj_[idx]) {
				if (e.target == ci) { already = true; break; }
			}
			if (already) { connected++; continue; }

			if (corridor_clear(positions_[idx], positions_[ci], clearance)) {
				float dist = positions_[idx].distance_to(positions_[ci]);
				add_edge(idx, ci, dist);
				connected++;
			}
		}
	}
}

// ============================================================================
// Connected components (BFS)
// ============================================================================

void WaypointGraph::compute_components() {
	int n = (int)positions_.size();
	component_.assign(n, -1);
	component_count_ = 0;

	std::vector<int> queue;
	for (int i = 0; i < n; i++) {
		if (!active_[i] || component_[i] >= 0) continue;

		int comp = component_count_++;
		component_[i] = comp;
		queue.clear();
		queue.push_back(i);

		for (int qi = 0; qi < (int)queue.size(); qi++) {
			int u = queue[qi];
			for (const auto& e : adj_[u]) {
				if (component_[e.target] < 0 && active_[e.target]) {
					component_[e.target] = comp;
					queue.push_back(e.target);
				}
			}
		}
	}
}

// ============================================================================
// Node queries
// ============================================================================

Vector2 WaypointGraph::node_position(int idx) const {
	if (idx < 0 || idx >= (int)positions_.size()) return Vector2();
	return positions_[idx];
}

bool WaypointGraph::node_active(int idx) const {
	if (idx < 0 || idx >= (int)active_.size()) return false;
	return active_[idx];
}

bool WaypointGraph::node_is_proxy(int idx) const {
	if (idx < 0 || idx >= (int)is_proxy_.size()) return false;
	return is_proxy_[idx];
}

int WaypointGraph::node_proxy_owner(int idx) const {
	if (idx < 0 || idx >= (int)proxy_owner_.size()) return -1;
	return proxy_owner_[idx];
}

const std::vector<GraphEdge>& WaypointGraph::neighbors(int idx) const {
	static const std::vector<GraphEdge> empty;
	if (idx < 0 || idx >= (int)adj_.size()) return empty;
	return adj_[idx];
}

int WaypointGraph::node_component(int idx) const {
	if (idx < 0 || idx >= (int)component_.size()) return -1;
	return component_[idx];
}

bool WaypointGraph::same_component(int a, int b) const {
	if (a < 0 || a >= (int)component_.size()) return false;
	if (b < 0 || b >= (int)component_.size()) return false;
	return component_[a] >= 0 && component_[a] == component_[b];
}

// ============================================================================
// Spatial queries
// ============================================================================

int WaypointGraph::find_nearest_node(Vector2 pos, int required_component) const {
	int best = -1;
	float best_dist2 = std::numeric_limits<float>::max();

	// Start with local search, expand if needed
	float search_radius = R_MIN_OPEN * 2.0f;
	for (int attempt = 0; attempt < 3 && best < 0; attempt++) {
		auto candidates = spatial_query(pos, search_radius);
		for (int ci : candidates) {
			if (required_component >= 0 && component_[ci] != required_component) continue;
			float d2 = pos.distance_squared_to(positions_[ci]);
			if (d2 < best_dist2) {
				best_dist2 = d2;
				best = ci;
			}
		}
		search_radius *= 3.0f;
	}

	// Fallback: brute force
	if (best < 0) {
		for (int i = 0; i < (int)positions_.size(); i++) {
			if (!active_[i]) continue;
			if (required_component >= 0 && component_[i] != required_component) continue;
			float d2 = pos.distance_squared_to(positions_[i]);
			if (d2 < best_dist2) {
				best_dist2 = d2;
				best = i;
			}
		}
	}

	return best;
}

std::vector<std::pair<int,int>> WaypointGraph::get_edges_near(Vector2 pos, float radius) const {
	std::vector<std::pair<int,int>> result;
	auto near_nodes = spatial_query(pos, radius);

	for (int ni : near_nodes) {
		for (const auto& e : adj_[ni]) {
			// Include edge if either endpoint is near. Deduplicate by requiring ni < target.
			if (ni < e.target) {
				result.push_back({ni, e.target});
			}
		}
	}
	return result;
}

// ============================================================================
// Edge cost computation
// ============================================================================

float WaypointGraph::compute_edge_cost(int from, int to, float ship_radius,
										const std::vector<ThreatZone>& threats) const {
	if (from < 0 || from >= (int)positions_.size()) return INF_COST;
	if (to < 0 || to >= (int)positions_.size()) return INF_COST;
	if (!active_[from] || !active_[to]) return INF_COST;

	Vector2 a = positions_[from];
	Vector2 b = positions_[to];

	// Terrain corridor check
	if (!corridor_clear(a, b, ship_radius)) return INF_COST;

	float base = a.distance_to(b);

	if (threats.empty()) return base;

	// Detection circle check — march along edge
	// For proxy-to-proxy edges of the same enemy, skip that enemy's detection circle
	int skip_enemy_id = -1;
	if (is_proxy_[from] && is_proxy_[to] &&
		proxy_owner_[from] == proxy_owner_[to] && proxy_owner_[from] >= 0) {
		skip_enemy_id = proxy_owner_[from];
	}

	float step = std::max(ship_radius * 0.5f, 10.0f);
	float edge_len = base;
	int steps = std::max(1, (int)std::ceil(edge_len / step));

	for (int i = 0; i <= steps; i++) {
		float t = (steps > 0) ? (float)i / steps : 0.0f;
		Vector2 p = a.lerp(b, t);

		for (const auto& tz : threats) {
			if (tz.id >= 0 && tz.id == skip_enemy_id) continue;
			float d = p.distance_to(tz.position);
			if (d < tz.hard_radius) return INF_COST;
		}
	}

	return base;
}

float WaypointGraph::compute_terrain_edge_cost(int from, int to, float ship_radius) const {
	static const std::vector<ThreatZone> no_threats;
	return compute_edge_cost(from, to, ship_radius, no_threats);
}

bool WaypointGraph::straight_line_clear(Vector2 from, Vector2 to, float ship_radius,
										 const std::vector<ThreatZone>& threats) const {
	if (nav_map_.is_null()) return false;

	// Terrain check
	RayResult ray = nav_map_->raycast_internal(from, to, ship_radius);
	if (ray.hit) return false;

	// Threat check
	if (!threats.empty()) {
		float step = std::max(ship_radius * 0.5f, 10.0f);
		float dist = from.distance_to(to);
		int steps = std::max(1, (int)std::ceil(dist / step));

		for (int i = 0; i <= steps; i++) {
			float t = (float)i / steps;
			Vector2 p = from.lerp(to, t);
			for (const auto& tz : threats) {
				if (p.distance_to(tz.position) < tz.hard_radius) return false;
			}
		}
	}

	return true;
}

// ============================================================================
// Proxy ring management
// ============================================================================

Array WaypointGraph::add_proxy_ring(int enemy_id, Vector2 center, float radius) {
	Array result;

	// Remove existing ring if present
	if (proxy_rings_.count(enemy_id)) {
		remove_proxy_ring(enemy_id);
	}

	ProxyRing ring;
	ring.center = center;
	ring.radius = radius;

	int n = node_count();

	for (int i = 0; i < PROXY_RING_SIZE; i++) {
		float angle = (float)i / PROXY_RING_SIZE * 6.28318530f;
		Vector2 pos(center.x + std::cos(angle) * radius,
					center.y + std::sin(angle) * radius);

		int idx = (int)positions_.size();
		positions_.push_back(pos);
		adj_.emplace_back();
		is_proxy_.push_back(true);
		proxy_owner_.push_back(enemy_id);
		active_.push_back(true);
		component_.push_back(-1); // will be assigned when connected

		ring.node_indices.push_back(idx);
		result.push_back(idx);
	}

	// Connect ring nodes to each other (adjacent pairs on the ring)
	for (int i = 0; i < PROXY_RING_SIZE; i++) {
		int a = ring.node_indices[i];
		int b = ring.node_indices[(i + 1) % PROXY_RING_SIZE];
		float dist = positions_[a].distance_to(positions_[b]);
		add_edge(a, b, dist);
	}

	// Connect each proxy node to nearby static graph nodes
	for (int idx : ring.node_indices) {
		add_to_spatial_grid(idx);
		connect_node_to_graph(idx, min_ship_radius_, MAX_EDGE_LENGTH);
	}

	// Assign components: proxy nodes inherit component from any connected static node
	for (int idx : ring.node_indices) {
		for (const auto& e : adj_[idx]) {
			if (e.target < static_count_ && component_[e.target] >= 0) {
				component_[idx] = component_[e.target];
				break;
			}
		}
	}

	proxy_rings_[enemy_id] = ring;
	return result;
}

void WaypointGraph::update_proxy_ring(int enemy_id, Vector2 new_center) {
	auto it = proxy_rings_.find(enemy_id);
	if (it == proxy_rings_.end()) return;

	ProxyRing& ring = it->second;
	Vector2 delta = new_center - ring.center;

	// If movement is negligible, skip
	if (delta.length_squared() < 1.0f) return;

	ring.center = new_center;

	// Move proxy nodes
	for (int i = 0; i < PROXY_RING_SIZE; i++) {
		int idx = ring.node_indices[i];
		remove_from_spatial_grid(idx);

		float angle = (float)i / PROXY_RING_SIZE * 6.28318530f;
		positions_[idx] = Vector2(new_center.x + std::cos(angle) * ring.radius,
								  new_center.y + std::sin(angle) * ring.radius);

		add_to_spatial_grid(idx);
	}

	// Update ring edge weights (distances between adjacent proxies don't change
	// since relative positions are the same, but connections to static nodes do)
	for (int idx : ring.node_indices) {
		// Update base_weight for all edges to/from this proxy
		for (auto& e : adj_[idx]) {
			e.base_weight = positions_[idx].distance_to(positions_[e.target]);
		}
		// Also update the reverse entries
		for (auto& e : adj_[idx]) {
			for (auto& re : adj_[e.target]) {
				if (re.target == idx) {
					re.base_weight = e.base_weight;
					break;
				}
			}
		}
	}
}

void WaypointGraph::remove_proxy_ring(int enemy_id) {
	auto it = proxy_rings_.find(enemy_id);
	if (it == proxy_rings_.end()) return;

	for (int idx : it->second.node_indices) {
		active_[idx] = false;
		remove_edges_for_node(idx);
		remove_from_spatial_grid(idx);
	}

	proxy_rings_.erase(it);
}

bool WaypointGraph::has_proxy_ring(int enemy_id) const {
	return proxy_rings_.count(enemy_id) > 0;
}

void WaypointGraph::clear_proxy_rings() {
	std::vector<int> ids;
	for (const auto& [id, _] : proxy_rings_) {
		ids.push_back(id);
	}
	for (int id : ids) {
		remove_proxy_ring(id);
	}
}

// ============================================================================
// Debug / visualization
// ============================================================================

PackedVector2Array WaypointGraph::get_all_positions() const {
	PackedVector2Array arr;
	for (int i = 0; i < (int)positions_.size(); i++) {
		if (active_[i]) arr.push_back(positions_[i]);
	}
	return arr;
}

int WaypointGraph::get_edge_count() const {
	int count = 0;
	for (int i = 0; i < (int)adj_.size(); i++) {
		if (!active_[i]) continue;
		for (const auto& e : adj_[i]) {
			if (e.target > i && active_[e.target]) count++;
		}
	}
	return count;
}

TypedArray<Dictionary> WaypointGraph::get_debug_edges() const {
	TypedArray<Dictionary> arr;
	for (int i = 0; i < (int)adj_.size(); i++) {
		if (!active_[i]) continue;
		for (const auto& e : adj_[i]) {
			if (e.target > i && active_[e.target]) {
				Dictionary d;
				d["from"] = positions_[i];
				d["to"] = positions_[e.target];
				d["weight"] = e.base_weight;
				d["from_proxy"] = (i < (int)is_proxy_.size() && is_proxy_[i]);
				d["to_proxy"] = (e.target < (int)is_proxy_.size() && is_proxy_[e.target]);
				arr.push_back(d);
			}
		}
	}
	return arr;
}

PackedVector2Array WaypointGraph::get_proxy_positions(int enemy_id) const {
	PackedVector2Array arr;
	auto it = proxy_rings_.find(enemy_id);
	if (it == proxy_rings_.end()) return arr;
	for (int idx : it->second.node_indices) {
		arr.push_back(positions_[idx]);
	}
	return arr;
}

} // namespace godot
