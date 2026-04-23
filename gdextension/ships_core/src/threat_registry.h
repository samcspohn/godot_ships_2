#ifndef THREAT_REGISTRY_H
#define THREAT_REGISTRY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

#include "nav_types.h"

namespace godot {

// One bin holds the ThreatZone vector + grid for a (team_id, radius_bin)
// combination.  Multiple ShipNavigators may hold a stable pointer to the
// same bin — refcounting controls bin lifetime.
struct ThreatBin {
	int team_id;
	int radius_bin;          // ceil(effective_radius / RADIUS_BIN_SIZE)
	float radius;            // canonical radius for this bin (radius_bin * RADIUS_BIN_SIZE)
	int refcount = 0;
	uint64_t version = 0;    // bumped on every rebuild — consumers diff this
	std::vector<ThreatZone> zones;
	ThreatGrid grid;
};

// Global cache of per-team enemy positions and per-bin computed zones.
//
// GDScript drives a single global tick (typically every 4 frames) by calling
// update_team(team_id, positions_with_decay).  Each ShipNavigator acquires a
// bin matched to its (team_id, effective_radius) and consumes the bin's
// pre-built ThreatZone vector and ThreatGrid.
//
// Per-zone radius = bin.radius * decay (decay scalar in [0,1]).
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

	// Replace the per-team enemy position list and rebuild every bin in
	// that team.  |positions_with_decay|: PackedVector3Array where each
	// element is (world.x, world.z, decay scalar).  Decay <= 0 entries
	// are dropped.
	void update_team(int team_id, const PackedVector3Array& positions_with_decay);

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

	std::unordered_map<Key, std::unique_ptr<ThreatBin>> bins_;
	std::unordered_map<int, std::vector<Vector3>> team_positions_;

	void rebuild_bin(ThreatBin* bin);
};

} // namespace godot

#endif // THREAT_REGISTRY_H
