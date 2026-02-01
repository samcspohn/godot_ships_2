# Makefile for Python virtual environment management

PYTHON := python3
VENV_DIR := venv
VENV_BIN := $(VENV_DIR)/bin
VENV_PYTHON := $(VENV_BIN)/python
VENV_PIP := $(VENV_BIN)/pip
REQUIREMENTS := requirements.txt

.PHONY: all venv install clean run tune help

# Default target
all: venv install

# Create virtual environment
venv: $(VENV_DIR)/pyvenv.cfg

$(VENV_DIR)/pyvenv.cfg:
	$(PYTHON) -m venv $(VENV_DIR)
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

# Run the combined optimizer app
app: install
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
	@echo "  all      - Create venv and install dependencies (default)"
	@echo "  venv     - Create virtual environment only"
	@echo "  install  - Install dependencies from requirements.txt"
	@echo "  run      - Run drag_optimizer.py"
	@echo "  tune     - Run interactive drag_tuner.py"
	@echo "  app      - Run combined drag_optimizer_app.py"
	@echo "  decouple - Run decouple_compensation.py analysis"
	@echo "  clean    - Remove virtual environment and cache files"
	@echo "  freeze   - Update requirements.txt with current packages"
	@echo "  help     - Show this help message"
