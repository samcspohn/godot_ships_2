#include "threat_registry.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

void ThreatRegistry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("update_team", "team_id", "positions_with_decay"),
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

void ThreatRegistry::update_team(int team_id, const PackedVector3Array& positions_with_decay) {
	auto& vec = team_positions_[team_id];
	vec.clear();
	int n = positions_with_decay.size();
	vec.reserve(n);
	for (int i = 0; i < n; ++i) {
		vec.push_back(positions_with_decay[i]);
	}
	for (auto& kv : bins_) {
		if (kv.second->team_id == team_id) {
			rebuild_bin(kv.second.get());
		}
	}
}

void ThreatRegistry::reset() {
	bins_.clear();
	team_positions_.clear();
}

void ThreatRegistry::rebuild_bin(ThreatBin* bin) {
	bin->zones.clear();
	auto it = team_positions_.find(bin->team_id);
	if (it != team_positions_.end()) {
		const auto& src = it->second;
		bin->zones.reserve(src.size());
		for (const auto& p : src) {
			float decay = p.z;
			if (decay <= 0.0f) continue;
			ThreatZone tz;
			tz.id = -1;
			tz.position = Vector2(p.x, p.y); // Vector3.y holds world Z (packed).
			tz.hard_radius = bin->radius * decay;
			bin->zones.push_back(tz);
		}
	}
	if (bin->zones.empty()) {
		bin->grid = ThreatGrid();
	} else {
		float cs = ThreatGrid::default_cell_size(bin->zones);
		bin->grid.build(bin->zones, cs);
	}
	bin->version += 1;
}
