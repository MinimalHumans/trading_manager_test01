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
var market_type: String = "infinite"

func update_market(items: Array, player_data: Dictionary, mkt_type: String = "infinite"):
	market_items = items
	player_state = player_data
	market_type = mkt_type
	
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
	
	# Limit items per category to reduce choice paralysis
	for category in items_by_category.keys():
		var items = items_by_category[category]
		var limited_items = []
		var common_count = 0
		var rare_count = 0
		var exotic_count = 0
		
		for item in items:
			var rarity = item.get("rarity_name", "Common")
			if rarity == "Common" and common_count < 2:
				limited_items.append(item)
				common_count += 1
			elif rarity == "Rare" and rare_count < 2:
				limited_items.append(item)
				rare_count += 1
			elif rarity == "Exotic" and exotic_count < 1:
				limited_items.append(item)
				exotic_count += 1
		
		items_by_category[category] = limited_items
	
	# Create UI for each category
	for category in items_by_category.keys():
		if items_by_category[category].size() > 0:
			_create_category_section(category, items_by_category[category])

func _create_category_section(category_name: String, items: Array):
	# Category header
	var header = Label.new()
	header.text = category_name
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(0.8, 0.8, 1.0))
	market_vbox.add_child(header)
	
	# Create grid for items (2 columns)
	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	market_vbox.add_child(grid)
	
	# Add items to grid
	for item in items:
		var item_ui = _create_item_ui(item)
		grid.add_child(item_ui)
	
	# Add spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 15)
	market_vbox.add_child(spacer)

func _create_item_ui(item: Dictionary) -> Control:
	var container = PanelContainer.new()
	container.custom_minimum_size = Vector2(350, 100)  # Wider for grid layout
	
	# Check if out of stock for finite markets
	var is_out_of_stock = false
	if market_type != "infinite":
		var current_stock = item.get("current_stock", 0)
		if current_stock <= 0:
			is_out_of_stock = true
	
	# Get category color
	var category_name = item.get("category_name", "Unknown")
	var category_color = db_manager.get_category_color(category_name)
	
	# Style with category color border
	var style = StyleBoxFlat.new()
	if is_out_of_stock:
		style.bg_color = Color(0.15, 0.15, 0.15)  # Darker for out of stock
	else:
		style.bg_color = Color(0.2, 0.2, 0.25)
	
	# Color-coded border (thicker on left for visual pop)
	style.border_color = category_color
	style.border_width_left = 4
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	container.add_theme_stylebox_override("panel", style)
	
	# VBox for item info
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	container.add_child(vbox)
	
	# Item name with category color
	var name_label = Label.new()
	name_label.text = item.get("item_name", "Unknown")
	if is_out_of_stock:
		name_label.text += " [OUT OF STOCK]"
		name_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	else:
		# Apply category color to item name (slightly brightened for readability)
		var bright_color = category_color * 1.3  # Brighten by 30%
		bright_color.a = 1.0  # Ensure full opacity
		name_label.add_theme_color_override("font_color", bright_color)
	name_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(name_label)
	
	# Rarity
	var rarity_label = Label.new()
	rarity_label.text = item.get("rarity_name", "Unknown")
	rarity_label.add_theme_font_size_override("font_size", 11)
	rarity_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(rarity_label)
	
	# Stock info for finite markets
	if market_type != "infinite":
		var stock_label = Label.new()
		var current_stock = item.get("current_stock", 0)
		var max_stock = item.get("max_stock", 0)
		
		# Show actual tons, not percentage
		stock_label.text = "Stock: %.1f/%.1f tons" % [current_stock, max_stock]
		stock_label.add_theme_font_size_override("font_size", 11)
		
		# Color code based on stock level
		var stock_percent = current_stock / max_stock if max_stock > 0 else 0
		if stock_percent <= 0:
			stock_label.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))  # Red
		elif stock_percent < 0.25:
			stock_label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.3))  # Orange
		elif stock_percent < 0.5:
			stock_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))  # Yellow
		else:
			stock_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))  # Light green
		
		vbox.add_child(stock_label)
	
	# Price info
	var price_hbox = HBoxContainer.new()
	vbox.add_child(price_hbox)
	
	var price_label = Label.new()
	var sell_price = item.get("sell_price", 0)
	var base_price = item.get("base_price", 0)
	var price_category = item.get("price_category", "Average")
	
	price_label.text = "%s cr/t (%s)" % [
		db_manager.format_credits(sell_price).replace(" cr", ""),
		price_category
	]
	price_label.add_theme_font_size_override("font_size", 12)
	price_label.add_theme_color_override("font_color", db_manager.get_price_color(price_category))
	price_hbox.add_child(price_label)
	
	# Purchase controls
	var purchase_hbox = HBoxContainer.new()
	purchase_hbox.add_theme_constant_override("separation", 5)
	vbox.add_child(purchase_hbox)
	
	# Quantity input
	var quantity_input = SpinBox.new()
	quantity_input.min_value = 0
	quantity_input.max_value = 1000
	quantity_input.step = 1
	quantity_input.value = 0
	quantity_input.custom_minimum_size = Vector2(80, 25)
	quantity_input.editable = not is_out_of_stock
	purchase_hbox.add_child(quantity_input)
	
	# Max button
	var max_button = Button.new()
	max_button.text = "MAX"
	max_button.custom_minimum_size = Vector2(50, 25)
	max_button.disabled = is_out_of_stock
	max_button.pressed.connect(_on_max_buy_pressed.bind(quantity_input, sell_price, item))
	purchase_hbox.add_child(max_button)
	
	# Buy button
	var buy_button = Button.new()
	buy_button.text = "BUY"
	buy_button.custom_minimum_size = Vector2(60, 25)
	buy_button.disabled = is_out_of_stock
	buy_button.pressed.connect(_on_buy_pressed.bind(
		item.get("item_id", 0),
		item.get("item_name", "Unknown"),
		quantity_input,
		sell_price
	))
	purchase_hbox.add_child(buy_button)
	
	return container

func _on_max_buy_pressed(quantity_input: SpinBox, price_per_ton: float, item: Dictionary):
	# Get fresh player state from game manager
	var game_manager = get_node("/root/Main/GameManager")
	if game_manager:
		var fresh_state = game_manager.current_player_state
		var credits = fresh_state.get("credits", 0)
		var cargo_free = fresh_state.get("cargo_free_tons", 0)
		var max_by_credits = floor(credits / price_per_ton)
		var max_quantity = min(max_by_credits, cargo_free)
		
		# For finite markets, also check stock
		if market_type != "infinite":
			var current_stock = item.get("current_stock", 0)
			max_quantity = min(max_quantity, current_stock)
		
		quantity_input.value = max_quantity
	else:
		# Fallback
		var credits = player_state.get("credits", 0)
		var cargo_free = player_state.get("cargo_free_tons", 0)
		var max_by_credits = floor(credits / price_per_ton)
		var max_quantity = min(max_by_credits, cargo_free)
		
		if market_type != "infinite":
			var current_stock = item.get("current_stock", 0)
			max_quantity = min(max_quantity, current_stock)
		
		quantity_input.value = max_quantity

func _on_buy_pressed(item_id: int, item_name: String, quantity_input: SpinBox, price_per_ton: float):
	var quantity = quantity_input.value
	
	if quantity <= 0:
		return
	
	# Emit signal to game manager
	item_purchased.emit(item_id, item_name, quantity, price_per_ton)
	
	# Reset quantity
	quantity_input.value = 0
