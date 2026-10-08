GODOTS_BIN := $(HOME)/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7_1-stable_linux_x86_64/Godot_v4.7.1-stable_linux.x86_64
GODOT ?= $(if $(shell command -v godot),godot,$(GODOTS_BIN))
ARGS ?=
JOBS ?= $(shell nproc)
HULLS ?= $(wildcard assets/Ships/*/*.tscn)

.PHONY: native bake sim smoke ab watch

native:
	$(MAKE) -C gdextension/ships_core_rs e

# Bake BotGunnery lattices in one Godot process (all threads, NUMA-pinned) and
# pack assets/gunnery.db. ARGS="--force" rebakes, plus --threads=N / --no-smt;
# HULLS="assets/Ships/Yamato/Yamato.tscn" limits the set.
bake:
	@command -v "$(GODOT)" >/dev/null || { echo "bake: GODOT=$(GODOT) not found; pass GODOT=<path>"; exit 1; }
	@$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- $(ARGS) \
		$(patsubst %,res://%,$(HULLS)) 2>&1 | grep -E "^bake:"

# Headless all-bot matches, JOBS in parallel, then per-bot/per-ship/per-spawn
# tables in OUT. Each match is its own seed, so its own spawn deal.
# make sim N=40
N ?= 40
LINEUP ?= res://tools/botmatch/lineup_12v12_t10.json
OUT ?= build/botmatch/$(shell date +%Y%m%d_%H%M%S)
sim:
	tools/botmatch/run.sh "$(GODOT)" "$(LINEUP)" $(N) $(JOBS) "$(OUT)"

# 3v3 behaviour check, not a performance metric.
SMOKE_N ?= 4
smoke:
	tools/botmatch/run.sh "$(GODOT)" res://tools/botmatch/lineup_3v3.json $(SMOKE_N) $(JOBS) "$(OUT)"

# A/B: AB_N 12v12 matches per arm, both arms at once, each in its own worktree
# under ~/Documents/ships_sim. B defaults to a snapshot of this working tree.
# make ab A=HEAD~1 B=HEAD AB_N=50
AB_N ?= 50
A ?= HEAD
B ?= WORKTREE
AB_OUT ?= $(HOME)/Documents/ships_sim/ab_$(shell date +%Y%m%d_%H%M%S)
ab:
	GODOT="$(GODOT)" tools/botmatch/ab.sh "$(AB_OUT)" $(AB_N) $(A) $(B)

# One all-bot match in real time with a windowed spectator client; closing the
# window stops the server. Server log in build/watch_server.log.
# make watch WATCH_LINEUP=res://tools/botmatch/lineup_3v3.json SEED=2 PORT=30500
WATCH_LINEUP ?= res://tools/botmatch/lineup_12v12_t10.json
SEED ?= 1
PORT ?= 30500
watch:
	@mkdir -p build
	@$(GODOT) --headless --path . --server --port $(PORT) --botmatch "$(WATCH_LINEUP)" --seed $(SEED) --no-replay \
		> build/watch_server.log 2>&1 & srv=$$!; \
	trap 'kill $$srv 2>/dev/null' EXIT INT TERM; \
	until ss -ltn | grep -q ":$(PORT) "; do kill -0 $$srv 2>/dev/null || { echo "watch: server exited, see build/watch_server.log"; exit 1; }; sleep 0.5; done; \
	$(GODOT) --path . --spectate 127.0.0.1:$(PORT)
