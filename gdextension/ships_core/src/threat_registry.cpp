#include "threat_registry.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void ThreatRegistry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("update_team", "team_id", "ids",
			"positions_with_decay", "force_spot_ranges"),
		&ThreatRegistry::update_team);
	ClassDB::bind_method(D_METHOD("reset"), &ThreatRegistry::reset);
	ClassDB::bind_method(D_METHOD("get_enemy_count", "team_id"),
		&ThreatRegistry::get_enemy_count);
}

ThreatRegistry::ThreatRegistry() {}
ThreatRegistry::~ThreatRegistry() {}

void ThreatRegistry::update_team(int team_id,
                                 const PackedInt32Array& ids,
                                 const PackedVector3Array& positions_with_decay,
                                 const PackedFloat32Array& force_spot_ranges) {
	auto& team = teams_[team_id];

	// Mark every existing entry stale; survivors get re-flagged below.
	for (auto& kv : team.enemies) kv.second.seen_this_tick = false;

	bool changed = false;
	int n = std::min(ids.size(), positions_with_decay.size());
	for (int i = 0; i < n; ++i) {
		int eid = ids[i];
		Vector3 pwd = positions_with_decay[i];
		float decay = pwd.z;
		if (decay <= 0.0f) continue;
		float force_spot = (i < force_spot_ranges.size())
			? std::max(0.0f, force_spot_ranges[i]) : 0.0f;

		auto it = team.enemies.find(eid);
		if (it == team.enemies.end()) {
			changed = true;
			EnemyThreatState fresh;
			fresh.enemy_id = eid;
			fresh.position = Vector2(pwd.x, pwd.y);
			fresh.decay = decay;
			fresh.force_spot = force_spot;
			fresh.seen_this_tick = true;
			team.enemies.emplace(eid, fresh);
			continue;
		}

		EnemyThreatState& es = it->second;
		// Only a semantic change earns a version bump - consumers rebuild their
		// whole circle list off it, and floating-point noise in a position is
		// not a reason to make every ship on the team do that.
		constexpr float POS_EPS = 0.01f;
		constexpr float SCALAR_EPS = 0.01f;
		if (std::abs(es.position.x - pwd.x) > POS_EPS ||
			std::abs(es.position.y - pwd.y) > POS_EPS ||
			std::abs(es.decay - decay) > SCALAR_EPS ||
			std::abs(es.force_spot - force_spot) > SCALAR_EPS) {
			changed = true;
		}
		es.position = Vector2(pwd.x, pwd.y);
		es.decay = decay;
		es.force_spot = force_spot;
		es.seen_this_tick = true;
	}

	// Prune anything that stopped being reported.
	for (auto it = team.enemies.begin(); it != team.enemies.end(); ) {
		if (!it->second.seen_this_tick) {
			it = team.enemies.erase(it);
			changed = true;
		} else {
			++it;
		}
	}

	if (changed) team.version += 1;
}

void ThreatRegistry::build_threats(int team_id, float observer_radius,
                                   std::vector<ThreatCircle>& out) const {
	out.clear();
	auto it = teams_.find(team_id);
	if (it == teams_.end()) return;
	const auto& team = it->second;
	out.reserve(team.enemies.size());
	for (const auto& ekv : team.enemies) {
		const EnemyThreatState& es = ekv.second;
		// The larger of "how far away this ship can see me by my own
		// concealment" and "how far it can see me whatever my concealment".
		// Decay applies to both: a contact nobody has looked at for a while is
		// a fading claim about where the danger is, not a fading sensor.
		float radius = std::max(observer_radius, es.force_spot) * es.decay;
		if (radius <= 0.0f) continue;
		out.emplace_back(es.enemy_id, es.position, radius);
	}
	// Deterministic ordering keeps stamp_threats and the destination push from
	// depending on unordered_map iteration order.
	std::sort(out.begin(), out.end(), [](const ThreatCircle &a, const ThreatCircle &b) {
		return a.enemy_id < b.enemy_id;
	});
}

uint64_t ThreatRegistry::get_team_version(int team_id) const {
	auto it = teams_.find(team_id);
	return (it == teams_.end()) ? 1u : it->second.version;
}

int ThreatRegistry::get_enemy_count(int team_id) const {
	auto it = teams_.find(team_id);
	return (it == teams_.end()) ? 0 : (int)it->second.enemies.size();
}

void ThreatRegistry::reset() {
	teams_.clear();
}
