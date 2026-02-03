# Makefile for Python virtual environment management
# Uses free-threaded Python 3.14 for parallel simulation

PYTHON_FREETHREADED := python3.14t
VENV_DIR := venv
VENV_BIN := $(VENV_DIR)/bin
VENV_PYTHON := $(VENV_BIN)/python
VENV_PIP := $(VENV_BIN)/pip
REQUIREMENTS := requirements.txt

.PHONY: all venv install clean run tune app decouple freeze check-python help

# Default target
all: venv install

# Check if free-threaded Python is available, install if not
check-python:
	@which $(PYTHON_FREETHREADED) > /dev/null 2>&1 || \
		(echo "Installing free-threaded Python 3.14..." && \
		sudo dnf install -y python3.14-freethreading)
	@echo "Free-threaded Python: $$($(PYTHON_FREETHREADED) --version)"
	@$(PYTHON_FREETHREADED) -c "import sys; print('GIL enabled:', sys._is_gil_enabled())"

# Create virtual environment with free-threaded Python
venv: check-python $(VENV_DIR)/pyvenv.cfg

$(VENV_DIR)/pyvenv.cfg:
	$(PYTHON_FREETHREADED) -m venv $(VENV_DIR)
	$(VENV_PIP) install --upgrade pip

# Install dependencies
install: venv
	$(VENV_PIP) install -r $(REQUIREMENTS)

# Run the drag optimizer
run: install
	$(VENV_PYTHON) drag_optimizer.py

# Run the interactive tuner
tune: install
	$(VENV_PYTHON) drag_tuner.py

# Run the combined optimizer app (with parallel simulation)
app: install
	@echo "Running with free-threaded Python 3.14 (GIL disabled, parallel simulation)"
	$(VENV_PYTHON) drag_optimizer_app.py

# Run the decouple compensation analysis
decouple: install
	$(VENV_PYTHON) decouple_compensation.py

# Clean up virtual environment
clean:
	rm -rf $(VENV_DIR)
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

# Freeze current dependencies
freeze: venv
	$(VENV_PIP) freeze > $(REQUIREMENTS)

# Help
help:
	@echo "Available targets:"
	@echo "  all          - Create venv and install dependencies (default)"
	@echo "  venv         - Create virtual environment with free-threaded Python"
	@echo "  install      - Install dependencies from requirements.txt"
	@echo "  run          - Run drag_optimizer.py"
	@echo "  tune         - Run interactive drag_tuner.py"
	@echo "  app          - Run drag_optimizer_app.py (parallel simulation, ~16x faster)"
	@echo "  decouple     - Run decouple_compensation.py analysis"
	@echo "  clean        - Remove virtual environment and cache files"
	@echo "  freeze       - Update requirements.txt with current packages"
	@echo "  check-python - Verify free-threaded Python is installed"
	@echo "  help         - Show this help message"
