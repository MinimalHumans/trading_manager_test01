# ui_cargo.gd
# Right column - Cargo hold/Sell interface controller

extends PanelContainer
@onready var cargo_stats: Label = $VBoxContainer/CargoHeader/CargoStats
@onready var credits_large: Label = $VBoxContainer/CargoHeader/CreditsLarge
@onready var jumps_display: Label = $VBoxContainer/CargoHeader/JumpsDisplay
@onready var cargo_vbox: VBoxContainer = $VBoxContainer/CargoScroll/CargoVbox
@onready var cargo_title: Label = $VBoxContainer/CargoHeader/CargoTitle

# UI references


# Signal
signal item_sold(item_id: int, item_name: String, quantity: float, price_per_ton: float)

# State
var db_manager
var player_state: Dictionary = {}
var inventory_items: Array = []
var sell_prices: Dictionary = {}

func update_cargo(inventory: Array, prices: Dictionary, player_data: Dictionary):
	inventory_items = inventory
	sell_prices = prices
	player_state = player_data
	
	# Get database manager
	if not db_manager:
		db_manager = get_node("/root/Main/GameManager/DatabaseManager")
	
	# Update header
	cargo_stats.text = "%.1f / %d tons" % [
		player_data.get("cargo_used_tons", 0),
		player_data.get("cargo_capacity_tons", 50)
	]
	
	credits_large.text = "Credits: " + db_manager.format_credits(player_data.get("credits", 0))
	jumps_display.text = "Jumps: %d" % player_data.get("total_jumps", 0)
	
	# Rebuild cargo list
	_rebuild_cargo_list()

func _rebuild_cargo_list():
	# Clear existing items
	for child in cargo_vbox.get_children():
		child.queue_free()
	
	if inventory_items.is_empty():
		var empty_label = Label.new()
		empty_label.text = "Cargo hold is empty"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		cargo_vbox.add_child(empty_label)
		return
	
	# Create UI for each item
	for item in inventory_items:
		var item_ui = _create_cargo_item_ui(item)
		cargo_vbox.add_child(item_ui)

func _create_cargo_item_ui(item: Dictionary) -> Control:
	var container = PanelContainer.new()
	container.custom_minimum_size = Vector2(0, 120)
	
	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.2, 0.2)
	style.border_color = Color(0.5, 0.4, 0.4)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	container.add_theme_stylebox_override("panel", style)
	
	# VBox for item info
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	container.add_child(vbox)
	
	# Item name and quantity
	var name_label = Label.new()
	name_label.text = "%s (%.1f tons)" % [
		item.get("item_name", "Unknown"),
		item.get("quantity_tons", 0)
	]
	name_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(name_label)
	
	# Category
	var category_label = Label.new()
	category_label.text = "Category: " + item.get("category_name", "Unknown")
	category_label.add_theme_font_size_override("font_size", 12)
	category_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(category_label)
	
	# Check if system will buy this item
	var item_id = item.get("item_id", 0)
	var price_info = sell_prices.get(item_id, {})
	var will_buy = price_info.get("will_buy", 0)
	
	if will_buy:
		# Price info
		var buy_price = price_info.get("buy_price", 0)
		var price_category = price_info.get("price_category", "Average")
		
		var price_label = Label.new()
		price_label.text = "This system pays: %s cr/ton (%s)" % [
			db_manager.format_credits(buy_price).replace(" cr", ""),
			price_category
		]
		price_label.add_theme_color_override("font_color", db_manager.get_price_color(price_category))
		vbox.add_child(price_label)
		
		# Total value
		var total_value = buy_price * item.get("quantity_tons", 0)
		var value_label = Label.new()
		value_label.text = "Total value: " + db_manager.format_credits(total_value)
		value_label.add_theme_font_size_override("font_size", 12)
		vbox.add_child(value_label)
		
		# Sell controls
		var sell_hbox = HBoxContainer.new()
		sell_hbox.add_theme_constant_override("separation", 10)
		vbox.add_child(sell_hbox)
		
		# Quantity input
		var quantity_input = SpinBox.new()
		quantity_input.min_value = 0
		quantity_input.max_value = item.get("quantity_tons", 0)
		quantity_input.step = 1
		quantity_input.value = 0
		quantity_input.custom_minimum_size = Vector2(100, 30)
		sell_hbox.add_child(quantity_input)
		
		# Max button
		var max_button = Button.new()
		max_button.text = "MAX"
		max_button.custom_minimum_size = Vector2(60, 30)
		max_button.pressed.connect(_on_max_sell_pressed.bind(quantity_input, item.get("quantity_tons", 0)))
		sell_hbox.add_child(max_button)
		
		# Sell button
		var sell_button = Button.new()
		sell_button.text = "SELL"
		sell_button.custom_minimum_size = Vector2(80, 30)
		sell_button.pressed.connect(_on_sell_pressed.bind(
			item_id,
			item.get("item_name", "Unknown"),
			quantity_input,
			buy_price
		))
		sell_hbox.add_child(sell_button)
		
	else:
		# System not buying
		var not_buying_label = Label.new()
		not_buying_label.text = "Not buying"
		not_buying_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		vbox.add_child(not_buying_label)
	
	return container

func _on_max_sell_pressed(quantity_input: SpinBox, max_quantity: float):
	quantity_input.value = max_quantity

func _on_sell_pressed(item_id: int, item_name: String, quantity_input: SpinBox, price_per_ton: float):
	var quantity = quantity_input.value
	
	if quantity <= 0:
		return
	
	# Emit signal to game manager
	item_sold.emit(item_id, item_name, quantity, price_per_ton)
	
	# Reset quantity
	quantity_input.value = 0
