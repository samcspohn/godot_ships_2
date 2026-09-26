GODOT ?= godot
ARGS ?=
JOBS ?= $(shell nproc)
HULLS ?= $(wildcard assets/Ships/*/*.tscn)

.PHONY: native bake sim

native:
	$(MAKE) -C gdextension/ships_core_rs e

# Bake BotGunnery lattices, one Godot process per hull, JOBS at a time, then
# pack the staging dir into user://gunnery.db.
# ARGS="--force" rebakes; HULLS="assets/Ships/Yamato/Yamato.tscn" limits the set.
bake:
	@printf '%s\n' $(HULLS) | sed 's|^|res://|' | xargs -P $(JOBS) -I{} sh -c \
		'$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- $(ARGS) {} 2>&1 | grep -E "^bake: (res|.*produced)"'
	@$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- --merge 2>&1 | grep -E "^bake:"

# Headless all-bot matches, JOBS in parallel, then per-bot/per-ship tables in OUT.
# make sim N=16 LINEUP=res://tools/botmatch/lineup_3v3.json
N ?= 8
LINEUP ?= res://tools/botmatch/lineup_3v3.json
OUT ?= build/botmatch/$(shell date +%Y%m%d_%H%M%S)
sim:
	tools/botmatch/run.sh "$(GODOT)" "$(LINEUP)" $(N) $(JOBS) "$(OUT)"
