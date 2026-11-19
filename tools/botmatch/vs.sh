#!/usr/bin/env bash
# usage: vs.sh <godot> <lineup> <matches> <jobs> <out_dir> [base_port] [first_seed]
# v5 on one team, v4 on the other. Each seed runs twice with sides swapped so spawn/side bias cancels.
set -euo pipefail
GODOT=$1 LINEUP=$2 N=$3 JOBS=$4 OUT=$5 BASE=${6:-32100} SEED0=${7:-0}
mkdir -p "$OUT"
seq 0 $((N - 1)) | xargs -P "$JOBS" -I{} sh -c '
	i={}; t=$((i % 2)); s=$((i / 2 + '"$SEED0"')); port=$(('"$BASE"' + i))
	SHIPS_BOT5_TEAMS=$t timeout -k 30 1800 "'"$GODOT"'" --headless --path . --fixed-fps 12 --server --port $port \
		--botmatch "'"$LINEUP"'" --seed $s --no-replay --gun-matrix-cache --point-table-cache --no-live-mods \
		--metrics "'"$OUT"'/t${t}_s$s.json" > "'"$OUT"'/t${t}_s$s.log" 2>&1
	echo "match t${t}_s$s exit $? $(test -f "'"$OUT"'/t${t}_s$s.json" && echo ok || echo NO-METRICS)"'
python3 tools/botmatch/bot5_vs.py "$OUT" | tee "$OUT/summary.txt"
