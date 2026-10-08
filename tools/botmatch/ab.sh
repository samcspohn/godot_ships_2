#!/usr/bin/env bash
# usage: ab.sh <out_dir> [matches=50] [a_ref=HEAD] [b_ref=WORKTREE]
# Both arms build in their own worktree under $SIM_ROOT and run concurrently.
# WORKTREE snapshots tracked + untracked changes so later edits here can't leak into a run.
set -euo pipefail
OUT=$(realpath -m "$1") N=${2:-50} A=${3:-HEAD} B=${4:-WORKTREE}
GODOT=${GODOT:-$HOME/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7_1-stable_linux_x86_64/Godot_v4.7.1-stable_linux.x86_64}
SIM_ROOT=${SIM_ROOT:-$HOME/Documents/ships_sim}
LINEUP=${LINEUP:-res://tools/botmatch/lineup_12v12_t10.json}
CPUS=${CPUS:-0-127}
TIMEOUT=${TIMEOUT:-3600}
SRC=$(git rev-parse --show-toplevel)
cd "$SRC"

resolve() {
	if [ "$1" != WORKTREE ]; then git rev-parse --verify "$1^{commit}"; return; fi
	local idx; idx=$(mktemp)
	cp "$(git rev-parse --git-path index)" "$idx"
	GIT_INDEX_FILE=$idx git add -A -- . ':!build'
	local tree; tree=$(GIT_INDEX_FILE=$idx git write-tree)
	rm -f "$idx"
	git commit-tree "$tree" -p HEAD -m "ab snapshot"
}

prepare() {
	local name=$1 commit=$2 wt=$SIM_ROOT/worktrees/wt_ab_$1 target=$SIM_ROOT/cargo_ab_$1
	if [ -d "$wt" ]; then
		git -C "$wt" checkout -q --detach -f "$commit"
		git -C "$wt" clean -fdq
	else
		git worktree add -q --detach "$wt" "$commit"
	fi
	local particles=addons/Godot-Unified-Particle-System
	[ -n "$(ls -A "$wt/$particles" 2>/dev/null)" ] || cp -a "$SRC/$particles/." "$wt/$particles/"
	rm -rf "$wt/$particles/.git"
	[ -d "$wt/.godot" ] || cp -a "$SRC/.godot" "$wt/.godot"
	cp "$SRC/assets/gunnery.db" "$wt/assets/gunnery.db"
	[ -d "$target" ] || cp -a "$SRC/gdextension/ships_core_rs/target" "$target"
	CARGO_TARGET_DIR=$target cargo build -q --release --manifest-path "$wt/gdextension/ships_core_rs/Cargo.toml"
	mkdir -p "$wt/bin"
	cp "$target/release/libships_core_rs.so" "$wt/bin/libships_core_rs.linux.x86_64.so"
	"$GODOT" --headless --path "$wt" --import > "$OUT/import_$name.log" 2>&1 || true
	echo "$name $commit $(git log -1 --format=%s "$commit")" >> "$OUT/arms.txt"
}

mkdir -p "$OUT"
: > "$OUT/arms.txt"
CA=$(resolve "$A") CB=$(resolve "$B")
[ "$B" = WORKTREE ] && git diff "$CA" "$CB" > "$OUT/b_vs_a.diff"
prepare a "$CA" & pa=$!
prepare b "$CB" & pb=$!
wait $pa && wait $pb

cat > "$OUT/godot.sh" <<EOF
#!/usr/bin/env bash
exec taskset -c $CPUS timeout -k 30 $TIMEOUT "$GODOT" "\$@"
EOF
chmod +x "$OUT/godot.sh"
(cd "$SIM_ROOT/worktrees/wt_ab_a" && tools/botmatch/run.sh "$OUT/godot.sh" "$LINEUP" "$N" "$N" "$OUT/a" 31000) > "$OUT/a.runlog" 2>&1 & ra=$!
(cd "$SIM_ROOT/worktrees/wt_ab_b" && tools/botmatch/run.sh "$OUT/godot.sh" "$LINEUP" "$N" "$N" "$OUT/b" 32000) > "$OUT/b.runlog" 2>&1 & rb=$!
wait $ra || true
wait $rb || true
python3 tools/botmatch/compare.py "a=$OUT/a" "b=$OUT/b" | tee "$OUT/compare.txt"
