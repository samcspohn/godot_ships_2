extends Control

class_name ShipUpgradeUI

# Get reference to global UpgradeManager
@onready var upgrade_manager = get_node("/root/UpgradeManager")

signal upgrade_selected(slot_index: int, upgrade_path: String)
signal upgrade_removed(slot_index: int)

@export var max_slots: int = 3
var ship_ref: Ship = null
var available_upgrades = []

# We'll use ship.upgrades instead of this array
var current_slot_selected = -1

@onready var upgrade_slots_container = $UpgradeSlotsContainer
@onready var upgrade_selection_panel = $UpgradeSelectionPanel
@onready var upgrade_list = $UpgradeSelectionPanel/ScrollContainer/UpgradeList
@onready var upgrade_details = $UpgradeSelectionPanel/UpgradeDetails
@onready var close_button = $UpgradeSelectionPanel/CloseButton

func _ready():
	# Wait for UpgradeManager to load upgrades if needed
	if upgrade_manager.available_upgrades.is_empty():
		await upgrade_manager.upgrades_loaded
	
	# Load available upgrades from UpgradeManager
	_load_available_upgrades()
	
	# Create upgrade slot buttons
	_create_upgrade_slots()
	
	# Connect close button
	close_button.pressed.connect(_on_close_button_pressed)
	
	# Hide selection panel initially
	upgrade_selection_panel.visible = false

func _load_available_upgrades():
	available_upgrades = []
	
	# Get metadata for all upgrades
	var upgrade_metadata = upgrade_manager.get_upgrade_metadata()
	
	for metadata in upgrade_metadata:
		available_upgrades.append({
			"name": metadata.name,
			"description": metadata.description,
			"path": metadata.path,
			"icon": metadata.icon
		})

func _create_upgrade_slots():
	for i in range(max_slots):
		var slot_button = Button.new()
		slot_button.text = ""  # No text, only icon
		slot_button.custom_minimum_size = Vector2(64, 64)  # Make it square and larger
		slot_button.name = "UpgradeSlot_" + str(i)
		slot_button.pressed.connect(_on_slot_button_pressed.bind(i))
		slot_button.flat = false
		
		# Add a placeholder icon container
		var icon_rect = TextureRect.new()
		icon_rect.name = "IconRect"
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon_rect.custom_minimum_size = Vector2(48, 48)
		
		slot_button.add_child(icon_rect)
		
		var tooltip = "Click to add an upgrade"
		slot_button.tooltip_text = tooltip
		
		upgrade_slots_container.add_child(slot_button)

func set_ship(ship: Ship):
	ship_ref = ship
	# Print debug info about the ship's upgrades
	print("Setting ship in UI. Ship has ", ship_ref.upgrades.upgrades.size(), " upgrades")
	for i in range(ship_ref.upgrades.upgrades.size()):
		var upgrade = ship_ref.upgrades.upgrades[i]
		if upgrade:
			print("Slot ", i, " has upgrade: ", upgrade.name)
		else:
			print("Slot ", i, " is empty")
	
	# Update UI with ship's current upgrades
	_update_slot_buttons()

func _on_slot_button_pressed(slot_index: int):
	current_slot_selected = slot_index
	
	# Clear previous list
	for child in upgrade_list.get_children():
		child.queue_free()
	
	# Show upgrade selection panel
	upgrade_selection_panel.visible = true
	
	# Update the title to show which slot is being modified
	var title_label = upgrade_selection_panel.get_node("TitleLabel")
	if title_label:
		title_label.text = "Select Upgrade for Slot " + str(slot_index + 1)
	
	# Populate with available upgrades
	for i in range(available_upgrades.size()):
		var upgrade = available_upgrades[i]
		
		var item = Button.new()
		item.text = ""  # No text directly on button
		item.custom_minimum_size = Vector2(280, 36)  # Reduced height since we only show name now
		item.pressed.connect(_on_upgrade_item_pressed.bind(i))
		
		var hbox = HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_FILL
		hbox.size_flags_vertical = Control.SIZE_FILL
		
		# Add icon
		var texture_rect = TextureRect.new()
		texture_rect.texture = upgrade.icon if upgrade.icon else null
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = Vector2(32, 32)
		hbox.add_child(texture_rect)
		
		# Add spacing
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(8, 0)
		hbox.add_child(spacer)
		
		# Add vertical layout for name only (description will be tooltip)
		var vbox = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		
		var name_label = Label.new()
		name_label.text = upgrade.name
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.add_child(name_label)
		
		# Set tooltip on the entire button instead of showing a separate description label
		item.tooltip_text = upgrade.description
		
		hbox.add_child(vbox)
		item.add_child(hbox)
		
		upgrade_list.add_child(item)
	
	# Add "Remove Upgrade" button if slot has an upgrade
	if current_slot_selected < ship_ref.upgrades.upgrades.size() and ship_ref.upgrades.upgrades[current_slot_selected] != null:
		var remove_button = Button.new()
		remove_button.custom_minimum_size = Vector2(280, 36)
		remove_button.pressed.connect(_on_remove_upgrade_pressed)
		remove_button.tooltip_text = "Remove the currently mounted upgrade from this slot"
		
		var hbox = HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_FILL
		hbox.size_flags_vertical = Control.SIZE_FILL
		
		# Add icon for remove (could use a red X icon here)
		var texture_rect = TextureRect.new()
		texture_rect.custom_minimum_size = Vector2(32, 32)
		hbox.add_child(texture_rect)
		
		# Add spacing
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(8, 0)
		hbox.add_child(spacer)
		
		# Add text
		var label = Label.new()
		label.text = "Remove Upgrade"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)
		
		remove_button.add_child(hbox)
		upgrade_list.add_child(remove_button)

func _on_upgrade_item_pressed(upgrade_index: int):
	var upgrade = available_upgrades[upgrade_index]
	
	# Apply the upgrade to the ship through the upgrade manager
	if ship_ref:
		upgrade_manager.apply_upgrade_to_ship(ship_ref, current_slot_selected, upgrade.path)
	
	# Update the button text
	_update_slot_buttons()
	
	# Close the panel
	upgrade_selection_panel.visible = false
	
	# Emit signal that an upgrade was selected
	upgrade_selected.emit(current_slot_selected, upgrade.path)

func _on_remove_upgrade_pressed():
	# Check if there's an upgrade at this slot position
	if current_slot_selected < ship_ref.upgrades.upgrades.size():
		var upgrade = ship_ref.upgrades.upgrades[current_slot_selected]
		if upgrade:
			# Remove the upgrade from the ship
			upgrade_manager.remove_upgrade_from_ship(ship_ref, upgrade_manager.get_path_from_upgrade(upgrade))
	
	# Update the button text
	_update_slot_buttons()
	
	# Close the panel
	upgrade_selection_panel.visible = false
	
	# Emit signal that an upgrade was removed
	upgrade_removed.emit(current_slot_selected)

func _update_slot_buttons():
	print("Updating slot buttons. Ship ref exists: ", ship_ref != null)
	if ship_ref:
		print("Ship has ", ship_ref.upgrades.upgrades.size(), " upgrades")
	
	for i in range(max_slots):
		var slot_button = upgrade_slots_container.get_child(i)
		var icon_rect = slot_button.get_node_or_null("IconRect")
		
		if not icon_rect:
			icon_rect = TextureRect.new()
			icon_rect.name = "IconRect"
			icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			icon_rect.custom_minimum_size = Vector2(48, 48)
			slot_button.add_child(icon_rect)
		
		# Check if this slot has an upgrade in the ship's upgrades array
		var has_upgrade = false
		var upgrade = null
		
		if ship_ref:
			# Make sure the upgrades array is properly initialized and has enough elements
			while i >= ship_ref.upgrades.upgrades.size():
				ship_ref.upgrades.upgrades.append(null)
				
			upgrade = ship_ref.upgrades.upgrades[i]
			has_upgrade = upgrade != null
			print("Slot ", i, " has upgrade: ", has_upgrade, " Name: ", upgrade.name if has_upgrade else "None")
		
		if has_upgrade:
			slot_button.text = ""  # No text, only icon
			
			if upgrade.icon:
				# Update icon
				icon_rect.texture = upgrade.icon
			else:
				# If no icon, show the name as text
				slot_button.text = upgrade.name.substr(0, 1)  # First letter of name
			
			# Update tooltip to show name and description
			slot_button.tooltip_text = upgrade.name + "\n\n" + upgrade.description
		else:
			# Empty slot
			slot_button.text = ""
			icon_rect.texture = null
			slot_button.tooltip_text = "Click to add an upgrade"

func _on_close_button_pressed():
	upgrade_selection_panel.visible = false
