#include "threat_registry.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

void ThreatRegistry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("update_team", "team_id", "ids", "positions_with_decay"),
		&ThreatRegistry::update_team);
	ClassDB::bind_method(D_METHOD("reset"), &ThreatRegistry::reset);
	ClassDB::bind_method(D_METHOD("get_bin_count"), &ThreatRegistry::get_bin_count);
}

ThreatRegistry::ThreatRegistry() {}
ThreatRegistry::~ThreatRegistry() {}

int ThreatRegistry::radius_to_bin(float radius) {
	if (radius <= 0.0f) return 0;
	int rb = (int)std::ceil(radius / RADIUS_BIN_SIZE);
	return rb < 1 ? 1 : rb;
}

ThreatBin* ThreatRegistry::acquire_bin(int team_id, float effective_radius) {
	int rb = radius_to_bin(effective_radius);
	Key k = make_key(team_id, rb);
	auto it = bins_.find(k);
	if (it != bins_.end()) {
		it->second->refcount += 1;
		return it->second.get();
	}
	auto bin = std::make_unique<ThreatBin>();
	bin->team_id = team_id;
	bin->radius_bin = rb;
	bin->radius = (float)rb * RADIUS_BIN_SIZE;
	bin->refcount = 1;
	bin->version = 0;
	ThreatBin* raw = bin.get();
	bins_[k] = std::move(bin);
	// Populate immediately from the latest team data so the first consumer
	// gets a sensible bin instead of an empty one until the next global tick.
	rebuild_bin(raw);
	return raw;
}

void ThreatRegistry::release_bin(ThreatBin* bin) {
	if (!bin) return;
	Key k = make_key(bin->team_id, bin->radius_bin);
	auto it = bins_.find(k);
	if (it == bins_.end()) return;
	if (--it->second->refcount <= 0) {
		bins_.erase(it);
	}
}

void ThreatRegistry::update_team(int team_id,
                                 const PackedInt32Array& ids,
                                 const PackedVector3Array& positions_with_decay) {
	auto& team = teams_[team_id];

	// Mark every existing entry stale; survivors get re-flagged below.
	for (auto& kv : team.enemies) kv.second.seen_this_tick = false;

	int n = std::min(ids.size(), positions_with_decay.size());
	for (int i = 0; i < n; ++i) {
		int eid = ids[i];
		Vector3 pwd = positions_with_decay[i];
		float decay = pwd.z;
		if (decay <= 0.0f) continue;

		auto& es = team.enemies[eid];
		es.enemy_id = eid;
		es.position = Vector2(pwd.x, pwd.y);
		es.decay = decay;
		es.seen_this_tick = true;
	}

	// Prune stale entries
	for (auto it = team.enemies.begin(); it != team.enemies.end(); ) {
		if (!it->second.seen_this_tick) it = team.enemies.erase(it);
		else ++it;
	}

	rebuild_team_bins(team_id);
}

void ThreatRegistry::reset() {
	bins_.clear();
	teams_.clear();
}

void ThreatRegistry::rebuild_team_bins(int team_id) {
	for (auto& kv : bins_) {
		if (kv.second->team_id == team_id) {
			rebuild_bin(kv.second.get());
		}
	}
}

void ThreatRegistry::rebuild_bin(ThreatBin* bin) {
	bin->threats.clear();
	auto it = teams_.find(bin->team_id);
	if (it != teams_.end()) {
		const auto& team = it->second;
		bin->threats.reserve(team.enemies.size());
		for (const auto& ekv : team.enemies) {
			const EnemyArcState& es = ekv.second;
			float radius_eff = bin->radius * es.decay;
			if (radius_eff <= 0.0f) continue;
			bin->threats.emplace_back(es.enemy_id, es.position, radius_eff);
		}
	}
	bin->version += 1;
}
