#!/usr/bin/env bash
# usage: bot5_perf.sh <label> [seed]   12v12 all-v5 match; appends Bot5Hub._physics_process frame stats to doc/BOT_V5_PERF.md
set -euo pipefail
LABEL=$1 SEED=${2:-1}
G=${GODOT:-$HOME/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7_1-stable_linux_x86_64/Godot_v4.7.1-stable_linux.x86_64}
OUT=$(mktemp -d /tmp/bot5_perf.XXXX)
SHIPS_BOT5_TEAMS=all timeout 1800 "$G" --headless --path . --fixed-fps 12 --server --port $((31000 + SEED)) \
	--botmatch tools/botmatch/lineup_12v12_t10.json --seed "$SEED" --no-replay --no-live-mods --gun-matrix-cache \
	--metrics "$OUT/m.json" > "$OUT/m.log" 2>&1 || true
python3 - "$OUT/m.json" "$LABEL" "$SEED" "$(git rev-parse --short HEAD)$(git diff --quiet || echo +)" <<'PY'
import json, sys, datetime
path, label, seed, rev = sys.argv[1:]
d = json.load(open(path))
s = d["bot5"]["hub_frame_us"]
row = "| %s | %s | %s | %s | %.0f | %d | %d | %d | %d | %d | %d | %.0f |" % (
    datetime.date.today(), rev, label, seed, s["mean"], s["p50"], s["p90"], s["p99"], s["p999"], s["max"], s["n"], d["duration"])
print(row)
open("doc/BOT_V5_PERF.md", "a").write(row + "\n")
PY
echo "log: $OUT/m.log"
