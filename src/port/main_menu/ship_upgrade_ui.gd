extends Control

class_name ShipUpgradeUI

signal upgrade_selected(slot_index: int, upgrade_id: String)
signal upgrade_removed(slot_index: int)

@export var max_slots: int = 3
var ship_ref: Ship = null
var available_upgrades: Array[Dictionary] = []

var current_slot_selected = -1

@onready var upgrade_slots_container = $UpgradeSlotsPanel/UpgradeSlotsContainer
@onready var upgrade_selection_panel = $UpgradeSelectionPanel
@onready var upgrade_list = $UpgradeSelectionPanel/ScrollContainer/UpgradeList
@onready var upgrade_details = $UpgradeSelectionPanel/UpgradeDetails
@onready var close_button = $UpgradeSelectionPanel/CloseButton

func _ready():
	_load_available_upgrades()
	_create_upgrade_slots()
	close_button.pressed.connect(_on_close_button_pressed)
	upgrade_selection_panel.visible = false

func _load_available_upgrades():
	available_upgrades = []

	for id in UpgradeRegistry.get_all_ids():
		var info = UpgradeRegistry.get_upgrade_info(id)
		if not info.is_empty():
			available_upgrades.append(info)

func _create_upgrade_slots():
	for i in range(max_slots):
		var slot_button = Button.new()
		slot_button.text = ""
		slot_button.custom_minimum_size = Vector2(64, 64)
		slot_button.name = "UpgradeSlot_" + str(i)
		slot_button.pressed.connect(_on_slot_button_pressed.bind(i))
		slot_button.flat = false

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
	_update_slot_buttons()

func _on_slot_button_pressed(slot_index: int):
	current_slot_selected = slot_index

	# Clear previous list
	for child in upgrade_list.get_children():
		child.queue_free()

	upgrade_selection_panel.visible = true

	var title_label = upgrade_selection_panel.get_node("TitleLabel")
	if title_label:
		title_label.text = "Select Upgrade for Slot " + str(slot_index + 1)

	# Populate with available upgrades
	for i in range(available_upgrades.size()):
		var upgrade_info = available_upgrades[i]

		var item = Button.new()
		item.text = ""
		item.custom_minimum_size = Vector2(280, 36)
		item.pressed.connect(_on_upgrade_item_pressed.bind(i))

		var hbox = HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_FILL
		hbox.size_flags_vertical = Control.SIZE_FILL

		# Add icon
		var texture_rect = TextureRect.new()
		texture_rect.texture = upgrade_info.get("icon")
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = Vector2(32, 32)
		hbox.add_child(texture_rect)

		# Add spacing
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(8, 0)
		hbox.add_child(spacer)

		# Add name
		var vbox = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

		var name_label = Label.new()
		name_label.text = upgrade_info.get("name", "")
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.add_child(name_label)

		item.tooltip_text = upgrade_info.get("description", "")

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

		var texture_rect = TextureRect.new()
		texture_rect.custom_minimum_size = Vector2(32, 32)
		hbox.add_child(texture_rect)

		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(8, 0)
		hbox.add_child(spacer)

		var label = Label.new()
		label.text = "Remove Upgrade"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)

		remove_button.add_child(hbox)
		upgrade_list.add_child(remove_button)

func _on_upgrade_item_pressed(upgrade_index: int):
	var upgrade_info = available_upgrades[upgrade_index]
	var upgrade_id: String = upgrade_info.get("upgrade_id", "")

	if ship_ref and not upgrade_id.is_empty():
		var upgrade_instance = UpgradeRegistry.create_upgrade(upgrade_id)
		if upgrade_instance:
			ship_ref.upgrades.add_upgrade(current_slot_selected, upgrade_instance)

	_update_slot_buttons()
	upgrade_selection_panel.visible = false
	upgrade_selected.emit(current_slot_selected, upgrade_id)

func _on_remove_upgrade_pressed():
	if ship_ref and current_slot_selected < ship_ref.upgrades.upgrades.size():
		ship_ref.upgrades.remove_upgrade(current_slot_selected)

	_update_slot_buttons()
	upgrade_selection_panel.visible = false
	upgrade_removed.emit(current_slot_selected)

func _update_slot_buttons():
	if not ship_ref:
		return

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

		# Ensure the upgrades array is large enough
		while i >= ship_ref.upgrades.upgrades.size():
			ship_ref.upgrades.upgrades.append(null)

		var upgrade = ship_ref.upgrades.upgrades[i]
		var has_upgrade = upgrade != null

		if has_upgrade:
			slot_button.text = ""
			if upgrade.icon:
				icon_rect.texture = upgrade.icon
			else:
				slot_button.text = upgrade.name.substr(0, 1)
			slot_button.tooltip_text = upgrade.name + "\n\n" + upgrade.description
		else:
			slot_button.text = ""
			icon_rect.texture = null
			slot_button.tooltip_text = "Click to add an upgrade"

func _on_close_button_pressed():
	upgrade_selection_panel.visible = false
