extends Control

class_name ShipUpgradeUI

signal upgrade_selected(slot_index: int, upgrade_id: String)
signal upgrade_removed(slot_index: int)

var max_slots: int:
	get:
		if ship_ref == null:
			return 0
		return ship_ref.upgrades.upgrades.size()

var ship_ref: Ship = null
var available_upgrades: Array[Dictionary] = []

var current_slot_selected = -1

@onready var upgrade_slots_container = $UpgradeSlotsPanel/VBoxContainer/UpgradeSlotsContainer
@onready var slot_info_panel: RichTextLabel = $UpgradeSlotsPanel/VBoxContainer/SlotInfoPanel
@onready var upgrade_selection_panel = $UpgradeSelectionPanel
@onready var upgrade_list = $UpgradeSelectionPanel/VBoxContainer/ScrollContainer/UpgradeList
@onready var upgrade_details: RichTextLabel = $UpgradeSelectionPanel/VBoxContainer/UpgradeDetails
@onready var close_button = $UpgradeSelectionPanel/VBoxContainer/TitleRow/CloseButton

func _ready():
	_load_available_upgrades()
	_create_upgrade_slots()
	close_button.pressed.connect(_on_close_button_pressed)
	upgrade_selection_panel.visible = false

func _load_available_upgrades():
	available_upgrades = []

	for id in UpgradeRegistry.get_all_ids():
		var info = UpgradeRegistry.get_upgrade_info(id)
		if info.is_empty():
			continue
		# Filter by ship class once a ship has been set. Per-slot tier
		# filtering happens in _on_slot_button_pressed.
		if ship_ref != null:
			var probe: Upgrade = UpgradeRegistry.create_upgrade(id)
			if probe != null and not probe.is_allowed_for_ship(ship_ref):
				continue
		available_upgrades.append(info)

func _create_upgrade_slots():
	# Remove children immediately so get_child() is correct in the same frame.
	for child in upgrade_slots_container.get_children():
		upgrade_slots_container.remove_child(child)
		child.queue_free()

	for i in range(max_slots):
		var slot_box := VBoxContainer.new()
		slot_box.name = "SlotBox_" + str(i)
		slot_box.alignment = BoxContainer.ALIGNMENT_CENTER

		var slot_label := Label.new()
		slot_label.text = "Slot %d" % (i + 1)
		slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		slot_box.add_child(slot_label)

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
		slot_button.tooltip_text = ""
		var slot_idx := i  # capture for lambda
		slot_button.mouse_entered.connect(func() -> void:
			var up = ship_ref.upgrades.upgrades[slot_idx] if ship_ref else null
			if up != null:
				slot_info_panel.text = up.get_tooltip_bbcode()
			else:
				slot_info_panel.text = "[color=#888888]Slot %d — empty[/color]" % (slot_idx + 1)
		)
		slot_button.mouse_exited.connect(func() -> void:
			slot_info_panel.text = "[color=#888888]Hover a slot to see upgrade details[/color]"
		)
		slot_box.add_child(slot_button)

		upgrade_slots_container.add_child(slot_box)

func set_ship(ship: Ship):
	ship_ref = ship
	_load_available_upgrades()
	_create_upgrade_slots()
	_update_slot_buttons()

func _on_slot_button_pressed(slot_index: int):
	current_slot_selected = slot_index
	var slot_tier: int = slot_index + 1

	# Clear previous list
	for child in upgrade_list.get_children():
		child.queue_free()
	upgrade_details.text = "[color=#888888]Hover an upgrade to see details[/color]"

	upgrade_selection_panel.visible = true

	var title_label = upgrade_selection_panel.get_node("VBoxContainer/TitleRow/TitleLabel")
	if title_label:
		title_label.text = "Slot %d" % (slot_index + 1)

	# Populate only with upgrades whose tier matches this slot.
	for i in range(available_upgrades.size()):
		var upgrade_info = available_upgrades[i]
		if int(upgrade_info.get("tier", 1)) != slot_tier:
			continue

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

		var bbcode: String = upgrade_info.get("tooltip_bbcode", "[b]%s[/b]" % upgrade_info.get("name", ""))
		item.mouse_entered.connect(func(): upgrade_details.text = bbcode)

		hbox.add_child(vbox)
		item.add_child(hbox)

		upgrade_list.add_child(item)

	# Add "Remove Upgrade" button if slot has an upgrade
	if ship_ref.upgrades.upgrades[current_slot_selected] != null:
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
		# Sanity: refuse to slot if tier doesn't match this slot.
		if upgrade_instance != null and upgrade_instance.tier != current_slot_selected + 1:
			push_error("Upgrade '%s' tier mismatch for slot %d" % [upgrade_id, current_slot_selected])
			return
		if upgrade_instance:
			ship_ref.upgrades.add_upgrade(current_slot_selected, upgrade_instance)

	_update_slot_buttons()
	upgrade_selection_panel.visible = false
	upgrade_selected.emit(current_slot_selected, upgrade_id)

func _on_remove_upgrade_pressed():
	ship_ref.upgrades.remove_upgrade(current_slot_selected)
	_update_slot_buttons()
	upgrade_selection_panel.visible = false
	upgrade_removed.emit(current_slot_selected)

func _update_slot_buttons():
	if not ship_ref:
		return

	for i in range(max_slots):
		var slot_box: Node = upgrade_slots_container.get_child(i)
		var slot_button: Button = slot_box.get_node("UpgradeSlot_" + str(i))
		var icon_rect: TextureRect = slot_button.get_node_or_null("IconRect")

		if not icon_rect:
			icon_rect = TextureRect.new()
			icon_rect.name = "IconRect"
			icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			icon_rect.custom_minimum_size = Vector2(48, 48)
			slot_button.add_child(icon_rect)

		var upgrade = ship_ref.upgrades.upgrades[i]

		if upgrade != null:
			slot_button.text = ""
			icon_rect.texture = upgrade.icon if upgrade.icon else null
			if not upgrade.icon:
				slot_button.text = upgrade.name.substr(0, 1)
			slot_button.tooltip_text = ""
		else:
			slot_button.text = ""
			icon_rect.texture = null
			slot_button.tooltip_text = ""

func _on_close_button_pressed():
	upgrade_selection_panel.visible = false
