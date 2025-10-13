# ui_market.gd
# Middle column - Market/Buy interface controller

extends PanelContainer

@onready var credits_display: Label = $VBoxContainer/MarketHeader/CreditsDisplay
@onready var market_vbox: VBoxContainer = $VBoxContainer/MarketScroll/MarketVbox
@onready var market_title: Label = $VBoxContainer/MarketHeader/MarketTitle


# Signal
signal item_purchased(item_id: int, item_name: String, quantity: float, price_per_ton: float)

# State
var db_manager
var player_state: Dictionary = {}
var market_items: Array = []

func update_market(items: Array, player_data: Dictionary):
	market_items = items
	player_state = player_data
	
	# Get database manager
	if not db_manager:
		db_manager = get_node("/root/Main/GameManager/DatabaseManager")
	
	# Update header
	market_title.text = "Market at " + player_data.get("current_system_name", "Unknown")
	credits_display.text = "Credits: " + db_manager.format_credits(player_data.get("credits", 0))
	
	# Rebuild market list
	_rebuild_market_list()

func _rebuild_market_list():
	# Clear existing items
	for child in market_vbox.get_children():
		child.queue_free()
	
	# Group items by category
	var items_by_category = {}
	for item in market_items:
		var category = item.get("category_name", "Unknown")
		if not items_by_category.has(category):
			items_by_category[category] = []
		items_by_category[category].append(item)
	
	# Create UI for each category
	for category in items_by_category.keys():
		_create_category_section(category, items_by_category[category])

func _create_category_section(category_name: String, items: Array):
	# Category header
	var header = Label.new()
	header.text = category_name
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(0.8, 0.8, 1.0))
	market_vbox.add_child(header)
	
	# Add items
	for item in items:
		var item_ui = _create_item_ui(item)
		market_vbox.add_child(item_ui)
	
	# Add spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	market_vbox.add_child(spacer)

func _create_item_ui(item: Dictionary) -> Control:
	var container = PanelContainer.new()
	container.custom_minimum_size = Vector2(0, 100)
	
	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.25)
	style.border_color = Color(0.4, 0.4, 0.5)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	container.add_theme_stylebox_override("panel", style)
	
	# VBox for item info
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	container.add_child(vbox)
	
	# Item name
	var name_label = Label.new()
	name_label.text = item.get("item_name", "Unknown")
	name_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(name_label)
	
	# Rarity
	var rarity_label = Label.new()
	rarity_label.text = "Rarity: " + item.get("rarity_name", "Unknown")
	rarity_label.add_theme_font_size_override("font_size", 12)
	rarity_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(rarity_label)
	
	# Price info
	var price_hbox = HBoxContainer.new()
	vbox.add_child(price_hbox)
	
	var price_label = Label.new()
	var sell_price = item.get("sell_price", 0)
	var base_price = item.get("base_price", 0)
	var price_category = item.get("price_category", "Average")
	
	price_label.text = "%s cr/ton (%s - Base: %s)" % [
		db_manager.format_credits(sell_price).replace(" cr", ""),
		price_category,
		db_manager.format_credits(base_price).replace(" cr", "")
	]
	price_label.add_theme_color_override("font_color", db_manager.get_price_color(price_category))
	price_hbox.add_child(price_label)
	
	# Stock
	var stock_label = Label.new()
	var availability = item.get("availability_percent", 0)
	stock_label.text = "Stock: %.0f%%" % (availability * 100)
	stock_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(stock_label)
	
	# Purchase controls
	var purchase_hbox = HBoxContainer.new()
	purchase_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(purchase_hbox)
	
	# Quantity input
	var quantity_input = SpinBox.new()
	quantity_input.min_value = 0
	quantity_input.max_value = 1000
	quantity_input.step = 1
	quantity_input.value = 0
	quantity_input.custom_minimum_size = Vector2(100, 30)
	purchase_hbox.add_child(quantity_input)
	
	# Max button
	var max_button = Button.new()
	max_button.text = "MAX"
	max_button.custom_minimum_size = Vector2(60, 30)
	max_button.pressed.connect(_on_max_buy_pressed.bind(quantity_input, sell_price))
	purchase_hbox.add_child(max_button)
	
	# Buy button
	var buy_button = Button.new()
	buy_button.text = "BUY"
	buy_button.custom_minimum_size = Vector2(80, 30)
	buy_button.pressed.connect(_on_buy_pressed.bind(
		item.get("item_id", 0),
		item.get("item_name", "Unknown"),
		quantity_input,
		sell_price
	))
	purchase_hbox.add_child(buy_button)
	
	return container

func _on_max_buy_pressed(quantity_input: SpinBox, price_per_ton: float):
	var credits = player_state.get("credits", 0)
	var cargo_free = player_state.get("cargo_free_tons", 0)
	
	# Calculate max by credits
	var max_by_credits = floor(credits / price_per_ton)
	
	# Take minimum of credits limit and cargo limit
	var max_quantity = min(max_by_credits, cargo_free)
	
	quantity_input.value = max_quantity

func _on_buy_pressed(item_id: int, item_name: String, quantity_input: SpinBox, price_per_ton: float):
	var quantity = quantity_input.value
	
	if quantity <= 0:
		return
	
	# Emit signal to game manager
	item_purchased.emit(item_id, item_name, quantity, price_per_ton)
	
	# Reset quantity
	quantity_input.value = 0
