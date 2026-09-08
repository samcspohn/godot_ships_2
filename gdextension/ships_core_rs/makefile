# Makefile for the Rust GDExtension ships_core_rs
#
# Unlike the C++ extension, every Godot target (editor / template_debug /
# template_release) maps to ONE .so, so there is no stale-target failure mode:
# `ships_core_rs.gdextension` points all three at the same file.

.PHONY: all e d r dev clean help

OUT := ../../bin/libships_core_rs.linux.x86_64.so

all: e

# e/d/r are aliases kept so `make e d` works the same as for the C++ extension.
e d r: release

release:
	cargo build --release
	@mkdir -p ../../bin
	cp target/release/libships_core_rs.so $(OUT)
	@echo "-> $(OUT)"

# Unoptimized build with debug assertions, same output path.
dev:
	cargo build
	@mkdir -p ../../bin
	cp target/debug/libships_core_rs.so $(OUT)
	@echo "-> $(OUT) (debug)"

clean:
	cargo clean
	rm -f $(OUT)

help:
	@echo "  e / d / r  - optimized build (all three are the same target)"
	@echo "  dev        - unoptimized build with debug assertions"
	@echo "  clean      - remove build artifacts"
