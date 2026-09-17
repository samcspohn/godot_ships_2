GODOT ?= godot
ARGS ?=
JOBS ?= $(shell nproc)
HULLS ?= $(wildcard assets/Ships/*/*.tscn)

.PHONY: native bake

native:
	$(MAKE) -C gdextension/ships_core_rs e

# Bake BotGunnery lattices, one Godot process per hull, JOBS at a time, then
# pack the staging dir into user://gunnery.db.
# ARGS="--force" rebakes; HULLS="assets/Ships/Yamato/Yamato.tscn" limits the set.
bake:
	@printf '%s\n' $(HULLS) | sed 's|^|res://|' | xargs -P $(JOBS) -I{} sh -c \
		'$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- $(ARGS) {} 2>&1 | grep -E "^bake: (res|.*produced)"'
	@$(GODOT) --headless --path . res://tools/bake_gunnery.tscn -- --merge 2>&1 | grep -E "^bake:"
