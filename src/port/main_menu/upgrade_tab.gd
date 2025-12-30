# src/client/upgrade_tab.gd
extends Control

# Reference to ShipUpgradeUI for easier access from main menu
@onready var ship_upgrade_ui = $ShipUpgradeUI

# Signal to forward from ShipUpgradeUI
signal upgrade_selected(slot_index: int, upgrade_path: String)
signal upgrade_removed(slot_index: int)

func _ready():
	# Connect signals from ShipUpgradeUI
	ship_upgrade_ui.upgrade_selected.connect(_on_upgrade_selected)
	ship_upgrade_ui.upgrade_removed.connect(_on_upgrade_removed)

func set_ship(ship: Ship):
	ship_upgrade_ui.set_ship(ship)

func _on_upgrade_selected(slot_index: int, upgrade_path: String):
	# Forward the signal
	upgrade_selected.emit(slot_index, upgrade_path)

func _on_upgrade_removed(slot_index: int):
	# Forward the signal
	upgrade_removed.emit(slot_index)
