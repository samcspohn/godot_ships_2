# Makefile for building GDExtension library
# Usage:
#   make b      - Build all targets in parallel (editor, template_debug, template_release)
#   make editor - Build editor target only
#   make debug  - Build template_debug target only
#   make release - Build template_release target only
#   make clean  - Clean all build artifacts

# Detect number of CPU cores for parallel scons builds
NPROCS := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Scons command with parallel jobs
SCONS := scons -j$(NPROCS)

.PHONY: all b editor debug release clean

# Default target
all: b

# Build all targets in parallel using make's parallelism
# Run with: make -j3 b (or just make b, as the targets run scons in parallel internally)
b: editor debug release

editor:
	$(SCONS) target=editor optimize=speed

debug:
	$(SCONS) target=template_debug optimize=speed

release:
	$(SCONS) target=template_release optimize=speed

clean:
	$(SCONS) -c target=editor
	$(SCONS) -c target=template_debug
	$(SCONS) -c target=template_release
