#ifndef THREAT_REGISTRY_H
#define THREAT_REGISTRY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "nav_types.h"

namespace godot {


// One enemy, as the threat picture sees it.  Updated by update_team() each tick
// and persistent across calls so an entry survives the ship moving.
struct EnemyThreatState {
	int     enemy_id        = -1;
	Vector2 position        = Vector2();   // world XZ
	float   decay           = 1.0f;        // [0,1] — fades for unspotted ships
	// How far this ship can force-spot regardless of anybody's concealment:
	// radar, hydroacoustic search. Zero for a ship with nothing running. This
	// is the enemy's own reach and has nothing to do with who is asking, which
	// is exactly why it lives here and the observer's radius does not.
	float   force_spot      = 0.0f;
	bool    seen_this_tick  = false;
};


// Per-team enemy positions, shared by every ship on the opposing side.
//
// GDScript drives a single global tick (typically every 4 frames) by calling
// update_team(). Each ShipNavigator then builds its OWN threat circle list from
// this data via build_threats(), sized to its own detection radius.
//
// Circles used to be pre-built here and shared, keyed by team and by the
// observer's radius rounded up to the nearest kilometre. That saved almost
// nothing - the expensive part, HpaGraph::stamp_threats, was always per-ship
// anyway - and it cost a great deal of accuracy: every ship routed against a
// radius up to a kilometre larger than its own, which put the standoff a
// spotting skill wanted reliably INSIDE the circle the router refused to path
// through, so the strict pass failed and threat avoidance was dropped entirely
// for that query. Building per ship is O(enemies) per ship per update tick and
// removes the quantisation completely.
class ThreatRegistry : public RefCounted {
	GDCLASS(ThreatRegistry, RefCounted)

public:
	ThreatRegistry();
	~ThreatRegistry();

	// --- C++-only API (used by ShipNavigator) ---

	// Build the threat circles for one observer. `observer_radius` is the range
	// at which that ship is itself detectable, plus whatever margin it wants;
	// the radius used for each enemy is the larger of that and the enemy's own
	// force-spotting reach, because a radar cruiser sees you at radar range no
	// matter how well you are hidden.
	void build_threats(int team_id, float observer_radius,
	                   std::vector<ThreatCircle>& out) const;

	// Bumped every time update_team() changes anything for this team, so a
	// consumer can skip rebuilding. Never zero, so zero is safe as "never synced".
	uint64_t get_team_version(int team_id) const;

	// --- GDScript-exposed API ---

	// Replace the per-team enemy list. The three arrays are parallel:
	//   ids                  — ship instance IDs
	//   positions_with_decay — (world.x, world.z, decay); decay <= 0 is dropped
	//   force_spot_ranges    — metres of radar/hydro reach, 0 for none
	// Entries are matched by id across calls; vanished ids are pruned.
	void update_team(int team_id,
	                 const PackedInt32Array& ids,
	                 const PackedVector3Array& positions_with_decay,
	                 const PackedFloat32Array& force_spot_ranges);

	// Drop every team's data (e.g. between matches).
	void reset();

	int get_enemy_count(int team_id) const;

protected:
	static void _bind_methods();

private:
	struct TeamData {
		std::unordered_map<int, EnemyThreatState> enemies;
		// Starts at 1 so a consumer can use 0 for "never synced".
		uint64_t version = 1;
	};
	std::unordered_map<int, TeamData> teams_;
};

} // namespace godot

#endif // THREAT_REGISTRY_H
