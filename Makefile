GODOTS_BIN := $(HOME)/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7_1-stable_linux_x86_64/Godot_v4.7.1-stable_linux.x86_64
GODOT ?= $(if $(shell command -v godot),godot,$(GODOTS_BIN))
ARGS ?=
JOBS ?= $(shell nproc)
HULLS ?= $(wildcard assets/Ships/*/*.tscn assets/Ships/*.tscn)

.PHONY: native bake sim smoke ab watch learn

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
# Builds and saves user://point_tables for LINEUP with the bots' real loadouts: one sim that quits once every
# (gun, hull) table is on file. ab.sh runs it per arm; sims (run.sh) then only load.
point-tables:
	SHIPS_POINT_THREADS=$${SHIPS_POINT_THREADS:-32} timeout 900 $(GODOT) --headless --path . --fixed-fps 12 --server \
		--port 39890 --botmatch "$(LINEUP)" --seed 1 --no-replay --gun-matrix-cache --point-table-cache \
		--point-tables-only --no-live-mods 2>&1 | grep -E "^point tables"

sim:
	tools/botmatch/run.sh "$(GODOT)" "$(LINEUP)" $(N) $(JOBS) "$(OUT)"

# One fixed situation (tools/scenarios/*.json): SCN lines for traced hulls, DUEL option scores, metrics.
# make scenario S=tools/scenarios/yamato_dm_close.json
S ?= tools/scenarios/yamato_dm_close.json
scenario:
	mkdir -p build/scenario
	"$(GODOT)" --headless --path . --fixed-fps 12 --server --port 30480 --botmatch res://$(S) --no-replay --gun-matrix-cache \
		--no-live-mods --metrics build/scenario/$(notdir $(basename $(S))).json 2>&1 | tee build/scenario/$(notdir $(basename $(S))).log \
		| grep -E "^(SCN|DUEL)|SCRIPT ERROR"

# Every scenario's checks over SCN_N seeds, SCN_JOBS at a time: make scenarios [ONLY=dd_*] [SCN_N=40] [SCN_JOBS=200] [TRACE=1]
SCN_N ?= 40
SCN_JOBS ?= 200
ONLY ?= *
scenarios:
	rm -rf build/scenarios; mkdir -p build/scenarios
	for f in tools/scenarios/$(ONLY).json; do for s in $$(seq 1 $(SCN_N)); do echo "$$f $$s"; done; done | awk '{print $$0, NR}' | \
		xargs -P $(SCN_JOBS) -L1 sh -c 'n=$$(basename $$0 .json); "$(GODOT)" --headless --path . --fixed-fps 12 --server \
		--port $$((30480+$$2)) --botmatch res://$$0 --seed $$1 --no-replay --gun-matrix-cache --no-live-mods \
		--metrics build/scenarios/$$n.s$$1.json > build/scenarios/$$n.s$$1.log 2>&1; true'
	python3 tools/botmatch/scenario_report.py build/scenarios tools/scenarios --only "$(ONLY)" $(if $(TRACE),--trace)

# A scenario from a replay snapshot (default: newest replay, 9:30), then SNAP_N runs of it against the recorded ending.
# make snap [REPLAY=user://replays/x.replay] [AT=9:30] [TRACE=SP1,Shimakaze];  make snap-run S=tools/scenarios/snap_x_930.json
AT ?= 9:30
SNAP_N ?= 8
snap:
	"$(GODOT)" --headless --path . -s res://tools/replay_scenario.gd -- --at $(AT) $(if $(REPLAY),--replay $(REPLAY)) \
		$(if $(TRACE),--trace $(TRACE)) 2>&1 | grep -A40 "^replay_scenario"

# Watch a scenario (any tools/scenarios/*.json) as `make watch` does: make spectate S=tools/scenarios/snap_x_930.json
spectate:
	$(MAKE) watch WATCH_LINEUP=res://$(S)

snap-run:
	d=build/snap/$(notdir $(basename $(S))); rm -rf $$d; mkdir -p $$d; \
	for i in $$(seq 1 $(SNAP_N)); do \
		"$(GODOT)" --headless --path . --fixed-fps 12 --server --port $$((30600+i)) --botmatch res://$(S) --no-replay \
		--gun-matrix-cache --no-live-mods --metrics $$d/run_$$i.json > $$d/run_$$i.log 2>&1 & done; wait; \
	grep -c "SCRIPT ERROR" $$d/*.log | grep -v ":0$$"; \
	python3 tools/botmatch/snap_report.py $(S) $$d

# 3v3 behaviour check, not a performance metric.
SMOKE_N ?= 4
smoke:
	tools/botmatch/run.sh "$(GODOT)" res://tools/botmatch/lineup_3v3.json $(SMOKE_N) $(JOBS) "$(OUT)"

# A/B: AB_N 12v12 matches per arm, both arms at once, each in its own worktree
# under ~/Documents/ships_sim. B defaults to a snapshot of this working tree.
# make ab A=HEAD~1 B=HEAD AB_N=100
AB_N ?= 100
A ?= HEAD
B ?= WORKTREE
AB_OUT ?= $(HOME)/Documents/ships_sim/ab_$(shell date +%Y%m%d_%H%M%S)
# Rebuild assets/damage_prior.json from every saved bot-only match sample in user://damage_samples.
learn:
	$(GODOT) --headless --path . -s res://tools/learn_damage.gd

ab:
	GODOT="$(GODOT)" tools/botmatch/ab.sh "$(AB_OUT)" $(AB_N) $(A) $(B)

# One all-bot match in real time with a windowed spectator client; closing the
# window stops the server. Server log in build/watch_server.log.
# make watch WATCH_LINEUP=res://tools/botmatch/lineup_3v3.json SEED=2 PORT=30500 WATCH_SPEED=2
WATCH_LINEUP ?= res://tools/botmatch/lineup_12v12_t10.json
# Server keeps the 1/12 s physics step and SimClock paces it to WATCH_SPEED: --time-scale stretches the step and ships tunnel into islands.
WATCH_SPEED ?= 1
SEED ?= 1
PORT ?= 30500
# Replay with bot debug overlays lands in user://replays; WATCH_REPLAY=0 to skip.
WATCH_REPLAY ?= 1
watch:
	@mkdir -p build
	@$(GODOT) --headless --path . --fixed-fps 12 --sim-speed $(WATCH_SPEED) --server --port $(PORT) --botmatch "$(WATCH_LINEUP)" --seed $(SEED) $(if $(filter 0,$(WATCH_REPLAY)),--no-replay) \
		> build/watch_server.log 2>&1 & srv=$$!; \
	trap 'kill $$srv 2>/dev/null' EXIT INT TERM; \
	until ss -ltn | grep -q ":$(PORT) "; do kill -0 $$srv 2>/dev/null || { echo "watch: server exited, see build/watch_server.log"; exit 1; }; sleep 0.5; done; \
	$(GODOT) --path . --time-scale $(WATCH_SPEED) --spectate 127.0.0.1:$(PORT)
