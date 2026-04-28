#ifndef THREAT_REGISTRY_H
#define THREAT_REGISTRY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

#include "nav_types.h"

namespace godot {

class NavigationMap;

// Per-enemy persistent arc state.  Lives in ThreatRegistry, keyed by
// (team_id, enemy_id).  Origin/decay update on the global team tick (every
// few frames); arc lengths update one-arc-per-frame round-robin via
// tick_arcs(), spreading the terrain raycast cost.
struct EnemyArcState {
	static constexpr int    NUM_ARCS    = 12;
	static constexpr float  HALF_ANGLE  = 0.2617993878f;     // 15 deg in radians
	static constexpr float  MIN_LENGTH  = 1000.0f;           // floor enforced when stamping
	static constexpr float  MAX_PROBE   = 12000.0f;          // raycast distance ceiling

	int     enemy_id   = -1;
	Vector2 position   = Vector2();   // world XZ
	float   decay      = 1.0f;        // [0,1] — fades for unspotted ships
	float   arc_length[NUM_ARCS] = {  // metres, terrain-limited
		MAX_PROBE, MAX_PROBE, MAX_PROBE, MAX_PROBE,
		MAX_PROBE, MAX_PROBE, MAX_PROBE, MAX_PROBE,
		MAX_PROBE, MAX_PROBE, MAX_PROBE, MAX_PROBE,
	};
	uint8_t next_arc   = 0;           // round-robin probe cursor
	bool    seen_this_tick = false;   // set during update_team to detect stale entries

	static float arc_bearing(int i) {
		// 12 arcs spaced evenly around the circle, sector centres at
		// (i + 0.5) * 30 deg.  Bearing is in standard XZ-plane radians:
		// 0 = +X, π/2 = +Z.  Wraps via modular arithmetic.
		return ((float)i + 0.5f) * (6.2831853072f / (float)NUM_ARCS);
	}
};

// One bin holds the rasterized arc set + blocked grid for a (team_id,
// radius_bin) combination.  Multiple ShipNavigators may hold a stable
// pointer to the same bin — refcounting controls bin lifetime.
struct ThreatBin {
	int team_id;
	int radius_bin;          // ceil(effective_radius / RADIUS_BIN_SIZE)
	float radius;            // canonical radius for this bin (radius_bin * RADIUS_BIN_SIZE)
	int refcount = 0;
	uint64_t version = 0;    // bumped on every rebuild — consumers diff this
	std::vector<ThreatArc> arcs;
	BlockedGrid grid;
};

// Global cache of per-team enemy positions and per-bin computed arc grids.
//
// GDScript drives a single global tick (typically every 4 frames) by calling
// update_team(team_id, ids, positions_with_decay).  Each ShipNavigator
// acquires a bin matched to its (team_id, effective_radius) and consumes the
// bin's pre-built arc set + BlockedGrid.
//
// Per-arc effective length = clamp(arc.terrain_probed_length, MIN, bin.radius * decay).
class ThreatRegistry : public RefCounted {
	GDCLASS(ThreatRegistry, RefCounted)

public:
	// Quantization step for binning effective radii.  1000 m means ships
	// within 1 km of each other's effective avoidance radius share a bin.
	static constexpr float RADIUS_BIN_SIZE = 1000.0f;

	ThreatRegistry();
	~ThreatRegistry();

	// --- C++-only API (used by ShipNavigator) ---

	// Acquire (or create) a bin for (team_id, effective_radius).
	// Returned pointer is stable until release_bin drops refcount to zero.
	ThreatBin* acquire_bin(int team_id, float effective_radius);
	void release_bin(ThreatBin* bin);

	static int radius_to_bin(float radius);

	// --- GDScript-exposed API ---

	// Replace the per-team enemy position list and refresh every bin in
	// that team.  |ids| and |positions_with_decay| are parallel arrays:
	// each Vector3 element is (world.x, world.z, decay scalar).  Decay <= 0
	// entries are dropped.  Persistent EnemyArcState entries are matched by
	// id across calls so arc lengths survive ship movement; vanished ids
	// are pruned.
	void update_team(int team_id,
	                 const PackedInt32Array& ids,
	                 const PackedVector3Array& positions_with_decay);

	// Per-frame: advance one arc per enemy via raycast against |nav_map|.
	// Cheap (constant work per enemy) — full 12-arc refresh takes 12 frames.
	void tick_arcs(Ref<NavigationMap> nav_map);

	// Drop every bin and team data (e.g. between matches).
	void reset();

	int get_bin_count() const { return (int)bins_.size(); }

protected:
	static void _bind_methods();

private:
	using Key = uint64_t;
	static Key make_key(int team_id, int radius_bin) {
		return ((uint64_t)(uint32_t)team_id << 32) | (uint32_t)radius_bin;
	}

	// Per-team enemy state, keyed by enemy_id.  Persistent across update_team
	// calls so each ship's arc length probes accumulate over time.
	struct TeamData {
		std::unordered_map<int, EnemyArcState> enemies;
	};
	std::unordered_map<int, TeamData> teams_;
	std::unordered_map<Key, std::unique_ptr<ThreatBin>> bins_;

	void rebuild_bin(ThreatBin* bin);
	void rebuild_team_bins(int team_id);
};

} // namespace godot

#endif // THREAT_REGISTRY_H
