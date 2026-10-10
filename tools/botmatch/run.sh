#!/usr/bin/env bash
# usage: run.sh <godot> <lineup> <matches> <jobs> <out_dir> [base_port]
set -euo pipefail
GODOT=$1 LINEUP=$2 N=$3 JOBS=$4 OUT=$5 BASE=${6:-30100}
mkdir -p "$OUT"
seq 0 $((N - 1)) | xargs -P "$JOBS" -I{} sh -c '
	i={}; port=$(('"$BASE"' + i))
	"'"$GODOT"'" --headless --path . --fixed-fps 16 --server --port $port \
		--botmatch "'"$LINEUP"'" --seed $i --no-replay --gun-matrix-cache \
		--metrics "'"$OUT"'/match_$i.json" > "'"$OUT"'/match_$i.log" 2>&1
	echo "match $i exit $? $(test -f "'"$OUT"'/match_$i.json" && echo ok || echo NO-METRICS)"'
python3 tools/botmatch/aggregate.py "$OUT"
