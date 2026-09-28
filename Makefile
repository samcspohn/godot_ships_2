GODOTS_BIN := $(HOME)/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7_1-stable_linux_x86_64/Godot_v4.7.1-stable_linux.x86_64
GODOT ?= $(if $(shell command -v godot),godot,$(GODOTS_BIN))
ARGS ?=
JOBS ?= $(shell nproc)
HULLS ?= $(wildcard assets/Ships/*/*.tscn)

.PHONY: native bake sim

native:
	$(MAKE) -C gdextension/ships_core_rs e

# Bake BotGunnery lattices in one Godot process (all threads, NUMA-pinned) and
# pack assets/gunnery.db. ARGS="--force" rebakes, plus --threads=N / --no-smt;
# HULLS="assets/Ships/Yamato/Yamato.tscn" limits the set.
bake:
	@command -v "$(GODOT)" >/dev/null || { echo "bake: GODOT=$(GODOT) not found; pass GODOT=<path>"; exit 1; }
	@$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- $(ARGS) \
		$(patsubst %,res://%,$(HULLS)) 2>&1 | grep -E "^bake:"

# Headless all-bot matches, JOBS in parallel, then per-bot/per-ship tables in OUT.
# make sim N=16 LINEUP=res://tools/botmatch/lineup_3v3.json
N ?= 8
LINEUP ?= res://tools/botmatch/lineup_3v3.json
OUT ?= build/botmatch/$(shell date +%Y%m%d_%H%M%S)
sim:
	tools/botmatch/run.sh "$(GODOT)" "$(LINEUP)" $(N) $(JOBS) "$(OUT)"
