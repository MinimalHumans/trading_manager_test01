# game_manager.gd
# Central game state management and coordination

extends Node

# Node references
@onready var db_manager = $DatabaseManager
@onready var new_game_panel = $"../NewGamePanel"
@onready var game_panel = $"../GamePanel"
@onready var system_list_ui = $"../GamePanel/HBoxContainer/SystemListPanel"
@onready var market_ui = $"../GamePanel/HBoxContainer/MarketPanel"
@onready var cargo_ui = $"../GamePanel/HBoxContainer/CargoPanel"
@onready var win_dialog = $"../WinDialog"

# Game state
var current_player_state: Dictionary = {}
var current_system: Dictionary = {}
var market_buy_items: Array = []
var market_sell_prices: Dictionary = {}
var player_inventory: Array = []

# NEW: Universe market system
var universe_market_values: Dictionary = {}
var market_fluctuation_amount: float = 0.3  # Tunable: how much market changes per jump
var connected_planet_discount: float = 0.10  # Tunable: discount for goods from 1-jump neighbors
var market_value_per_point: float = 0.05  # Tunable: price change per market point (5% = balanced with planet modifiers)

# NEW: Event system
var current_event: Dictionary = {}  # Active event or empty if none
var last_event_jump: int = -999  # Jump when last event occurred
var event_trigger_chance: float = 0.2  # 4% chance per jump
var event_cooldown_jumps: int = 5  # Minimum jumps between events
var event_decay_rate: float = 0.25  # How much event fades per jump

# Signals
signal game_started
signal player_state_changed
signal system_changed
signal credits_changed
signal cargo_changed
signal game_won
signal confirmation_result(confirmed: bool)
signal market_values_changed  # NEW: Signal when market fluctuates

func _ready():
	# Wait for database to initialize
	await get_tree().process_frame
	
	# Connect UI signals
	connect_ui_signals()
	
	# Show new game panel
	new_game_panel.visible = true
	game_panel.visible = false

func connect_ui_signals():
	# New game setup
	if new_game_panel.has_signal("start_game"):
		new_game_panel.start_game.connect(_on_start_game)
	
	# System list
	if system_list_ui.has_signal("system_selected"):
		system_list_ui.system_selected.connect(_on_system_selected)
	if system_list_ui.has_signal("travel_requested"):
		system_list_ui.travel_requested.connect(_on_travel_requested)
	
	# Market
	if market_ui.has_signal("item_purchased"):
		market_ui.item_purchased.connect(_on_item_purchased)
	
	# Cargo
	if cargo_ui.has_signal("item_sold"):
		cargo_ui.item_sold.connect(_on_item_sold)

# ============================================================================
# GAME INITIALIZATION
# ============================================================================

func _on_start_game(config: Dictionary):
	var start_time = Time.get_ticks_msec()
	
	# Initialize database
	if not db_manager.initialize_new_game(config):
		push_error("Failed to initialize new game")
		return
	print("Init DB: %d ms" % (Time.get_ticks_msec() - start_time))
	
	# NEW: Initialize universe market (all categories start at 5.0)
	initialize_universe_market()
	
	# Load initial state
	var t1 = Time.get_ticks_msec()
	refresh_player_state()
	print("Refresh player state: %d ms" % (Time.get_ticks_msec() - t1))
	
	var market_type = current_player_state.get("market_type", "infinite")
	
	# Note: Save database is already fresh from initialize_new_game()
	# No need to clear inventory - it's created clean
	
	# Hide new game panel, show game panel
	new_game_panel.visible = false
	game_panel.visible = true
	
	# Initialize UI
	var t3 = Time.get_ticks_msec()
	system_list_ui.initialize(db_manager, current_player_state)
	print("Init system list UI: %d ms" % (Time.get_ticks_msec() - t3))
	
	var t4 = Time.get_ticks_msec()
	refresh_current_system()
	print("Refresh current system: %d ms" % (Time.get_ticks_msec() - t4))
	
	# Initialize inventory for starting system if needed
	var starting_system = current_player_state.get("current_system_id", 0)
	if market_type != "infinite" and not db_manager.has_inventory_for_system(starting_system):
		var t5 = Time.get_ticks_msec()
		db_manager.initialize_system_inventory_lazy(starting_system)
		print("Init starting inventory: %d ms" % (Time.get_ticks_msec() - t5))
	
	var t6 = Time.get_ticks_msec()
	refresh_market()
	print("Refresh market: %d ms" % (Time.get_ticks_msec() - t6))
	
	var t7 = Time.get_ticks_msec()
	refresh_cargo()
	print("Refresh cargo: %d ms" % (Time.get_ticks_msec() - t7))
	
	print("TOTAL START TIME: %d ms" % (Time.get_ticks_msec() - start_time))
	
	game_started.emit()

# NEW: Initialize universe market values
func initialize_universe_market():
	var categories = [
		"Food & Agriculture",
		"Raw Materials",
		"Manufactured Goods",
		"Technology",
		"Medical Supplies",
		"Luxury Goods",
		"Weapons & Ordnance"
	]
	
	# Generate random starting values between 3.0 and 7.0
	for cat in categories:
		universe_market_values[cat] = randf_range(3.0, 7.0)
	
	# Normalize to ensure total equals 35
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Universe market initialized: ", universe_market_values)

# NEW: Check if a market event should trigger
func check_for_event_trigger():
	var current_jumps = current_player_state.get("total_jumps", 0)
	
	# Don't trigger events in first 5 jumps or within cooldown period
	if current_jumps < 5:
		return
	
	var jumps_since_last_event = current_jumps - last_event_jump
	if jumps_since_last_event < event_cooldown_jumps:
		return
	
	# If event is active and hasn't fully decayed, decay it
	if not current_event.is_empty():
		decay_active_event()
		return
	
	# Random chance to trigger new event
	if randf() < event_trigger_chance:
		trigger_market_event()

# NEW: Trigger a random market event
func trigger_market_event():
	if db_manager.market_events.is_empty():
		return
	
	# Select random event
	var random_event = db_manager.market_events[randi() % db_manager.market_events.size()]
	
	# Calculate magnitude within range
	var magnitude = randf_range(random_event["magnitude_min"], random_event["magnitude_max"])
	
	# Store event details
	current_event = {
		"text": random_event["event_text"],
		"category": random_event["category_name"],
		"impact_type": random_event["impact_type"],
		"magnitude": magnitude,
		"remaining_strength": magnitude  # Will decay over time
	}
	
	last_event_jump = current_player_state.get("total_jumps", 0)
	
	# Apply event to market
	apply_event_to_market()
	
	# Show popup to player
	show_event_popup(current_event["text"])
	
	print("Market event triggered: %s affects %s by %f" % [current_event["impact_type"], current_event["category"], magnitude])

# NEW: Apply event impact to market values
func apply_event_to_market():
	if current_event.is_empty():
		return
	
	var category = current_event["category"]
	var impact_type = current_event["impact_type"]
	var strength = current_event["remaining_strength"]
	
	# Apply impact based on type
	if impact_type == "spike":
		# Increase this category value
		universe_market_values[category] += strength
	elif impact_type == "crash":
		# Decrease this category value
		universe_market_values[category] -= strength
	
	# Normalize to maintain total of 35
	var categories = universe_market_values.keys()
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Market after event: ", universe_market_values)
	market_values_changed.emit()

# NEW: Decay active event over time
func decay_active_event():
	if current_event.is_empty():
		return
	
	# Reduce event strength
	current_event["remaining_strength"] -= event_decay_rate
	
	# If event has fully decayed, clear it
	if current_event["remaining_strength"] <= 0:
		print("Market event has fully decayed")
		current_event = {}
		return
	
	# Reapply with reduced strength
	# First, reverse the previous impact
	var category = current_event["category"]
	var impact_type = current_event["impact_type"]
	var old_strength = current_event["remaining_strength"] + event_decay_rate
	
	if impact_type == "spike":
		universe_market_values[category] -= old_strength
	elif impact_type == "crash":
		universe_market_values[category] += old_strength
	
	# Apply new (decayed) impact
	apply_event_to_market()
	
	print("Event decaying: %s remaining strength = %f" % [current_event["category"], current_event["remaining_strength"]])

# NEW: Show event popup to player
func show_event_popup(event_text: String):
	var dialog = AcceptDialog.new()
	add_child(dialog)
	dialog.dialog_text = event_text
	dialog.title = "BREAKING NEWS"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	
	# Style it to look like a news alert
	dialog.min_size = Vector2(500, 200)
	
	dialog.confirmed.connect(func():
		dialog.queue_free()
	)
	
	dialog.close_requested.connect(func():
		dialog.queue_free()
	)
	
	dialog.popup_centered()

# NEW: Fluctuate universe market values
func fluctuate_universe_market():
	var categories = universe_market_values.keys()
	
	# Select 2-3 random categories to change
	var num_to_change = randi_range(2, 3)
	var changed_categories = []
	
	for i in range(num_to_change):
		var random_cat = categories[randi() % categories.size()]
		if not changed_categories.has(random_cat):
			changed_categories.append(random_cat)
	
	# Apply random changes to selected categories
	var changes = {}
	for cat in changed_categories:
		var change = randf_range(-market_fluctuation_amount, market_fluctuation_amount)
		changes[cat] = change
	
	# Apply correlation effects using database relationships
	for relationship in db_manager.category_relationships:
		var primary_cat_id = relationship["primary_category_id"]
		var influenced_cat_id = relationship["influenced_category_id"]
		var strength = relationship["correlation_strength"]
		
		# Convert category IDs to names
		var primary_cat_name = _get_category_name_by_id(primary_cat_id)
		var influenced_cat_name = _get_category_name_by_id(influenced_cat_id)
		
		# If primary category changed, influence the related category
		if changes.has(primary_cat_name):
			var primary_change = changes[primary_cat_name]
			var influenced_change = primary_change * strength
			
			if changes.has(influenced_cat_name):
				changes[influenced_cat_name] += influenced_change
			else:
				changes[influenced_cat_name] = influenced_change
	
	# Apply all changes
	for cat in changes.keys():
		universe_market_values[cat] += changes[cat]
	
	# Normalize to ensure total = 35
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Market fluctuated: ", universe_market_values)
	market_values_changed.emit()

# NEW: Helper to get category name by ID
func _get_category_name_by_id(category_id: int) -> String:
	for cat in db_manager.all_categories:
		if cat["category_id"] == category_id:
			return cat["category_name"]
	return ""

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

func refresh_player_state():
	current_player_state = db_manager.get_player_state()
	player_inventory = db_manager.get_player_inventory()
	
	# Check win condition
	if current_player_state.get("credits", 0) >= current_player_state.get("win_goal", 25000):
		_show_victory()
	
	player_state_changed.emit()

func refresh_current_system():
	var system_id = current_player_state.get("current_system_id", 0)
	current_system = db_manager.get_system_by_id(system_id)
	system_changed.emit()

func refresh_market():
	var system_id = current_player_state.get("current_system_id", 0)
	var market_type = current_player_state.get("market_type", "infinite")
	
	# NEW: Pass universe market values, connection discount, AND market modifier strength
	market_buy_items = db_manager.get_market_buy_items(
		system_id, 
		market_type, 
		universe_market_values, 
		connected_planet_discount,
		market_value_per_point
	)
	market_sell_prices = db_manager.get_market_sell_prices(system_id)
	
	if market_ui:
		market_ui.update_market(market_buy_items, current_player_state, market_type)

func refresh_cargo():
	player_inventory = db_manager.get_player_inventory()
	
	if cargo_ui:
		cargo_ui.update_cargo(player_inventory, market_sell_prices, current_player_state)
		# NEW: Update market graph
		cargo_ui.update_market_graph(universe_market_values)

# ============================================================================
# TRAVEL SYSTEM
# ============================================================================

func _on_system_selected(system_id: int):
	# Update market preview for selected system (optional feature)
	pass

func _on_travel_requested(destination_id: int, distance: int):
	var start_time = Time.get_ticks_msec()
	
	var fuel_cost = distance * current_player_state.get("base_fuel_cost", 25)
	var current_credits = current_player_state.get("credits", 0)
	var market_type = current_player_state.get("market_type", "infinite")
	
	# Validate travel
	if current_credits < fuel_cost:
		_show_error("Insufficient credits for fuel!")
		return
	
	# Show confirmation dialog
	var system_name = db_manager.get_system_by_id(destination_id).get("system_name", "Unknown")
	var confirm_text = "Travel to %s?\nDistance: %d jumps\nFuel Cost: %s\nNew Balance: %s" % [
		system_name,
		distance,
		db_manager.format_credits(fuel_cost),
		db_manager.format_credits(current_credits - fuel_cost)
	]
	
	var confirmed = await _show_confirmation(confirm_text)
	if not confirmed:
		return
	
	var t1 = Time.get_ticks_msec()
	
	# Execute travel
	if db_manager.execute_travel(destination_id, distance, fuel_cost):
		print("Execute travel: %d ms" % (Time.get_ticks_msec() - t1))
		
		# NEW: Fluctuate universe market on each jump
		fluctuate_universe_market()
		
		# NEW: Check for random market event
		check_for_event_trigger()
		
		# For finite markets, handle inventory initialization and regeneration
		if market_type != "infinite":
			var t2 = Time.get_ticks_msec()
			var has_inventory = db_manager.has_inventory_for_system(destination_id)
			print("Check inventory: %d ms" % (Time.get_ticks_msec() - t2))
			
			if not has_inventory:
				var t3 = Time.get_ticks_msec()
				db_manager.initialize_system_inventory_lazy(destination_id)
				print("Init inventory: %d ms" % (Time.get_ticks_msec() - t3))
			else:
				var t4 = Time.get_ticks_msec()
				if market_type == "finite_instant":
					db_manager.regenerate_system_stock_instant(destination_id)
				elif market_type == "finite_turn":
					var new_jump_count = current_player_state.get("total_jumps", 0) + distance
					db_manager.regenerate_system_stock_turnbased(destination_id, new_jump_count)
				print("Regenerate: %d ms" % (Time.get_ticks_msec() - t4))
		
		var t5 = Time.get_ticks_msec()
		refresh_player_state()
		print("Refresh player state: %d ms" % (Time.get_ticks_msec() - t5))
		
		var t6 = Time.get_ticks_msec()
		refresh_current_system()
		print("Refresh current system: %d ms" % (Time.get_ticks_msec() - t6))
		
		var t7 = Time.get_ticks_msec()
		refresh_market()
		print("Refresh market: %d ms" % (Time.get_ticks_msec() - t7))
		
		var t8 = Time.get_ticks_msec()
		refresh_cargo()
		print("Refresh cargo: %d ms" % (Time.get_ticks_msec() - t8))
		
		var t9 = Time.get_ticks_msec()
		system_list_ui.update_system_distances(current_player_state)
		print("Update distances: %d ms" % (Time.get_ticks_msec() - t9))
		
		print("TOTAL TRAVEL TIME: %d ms" % (Time.get_ticks_msec() - t1))
	else:
		_show_error("Travel failed!")

# ============================================================================
# TRADING SYSTEM
# ============================================================================

func _on_item_purchased(item_id: int, item_name: String, quantity: float, price_per_ton: float):
	var start_time = Time.get_ticks_msec()
	
	var total_cost = quantity * price_per_ton
	var current_credits = current_player_state.get("credits", 0)
	var cargo_free = current_player_state.get("cargo_free_tons", 0)
	var system_id = current_player_state.get("current_system_id", 0)
	var market_type = current_player_state.get("market_type", "infinite")
	
	# Validate purchase
	if current_credits < total_cost:
		_show_error("Insufficient credits!")
		return
	
	if cargo_free < quantity:
		_show_error("Insufficient cargo space!")
		return
	
	# For finite markets, check stock availability
	if market_type != "infinite":
		var stock_info = db_manager.get_item_stock(system_id, item_id)
		var available = stock_info.get("current_stock_tons", 0)
		
		if quantity > available:
			_show_error("Insufficient stock! Only %.1f tons available." % available)
			return
	
	# Large purchase confirmation
	if total_cost > current_credits * 0.5:
		var confirm_text = "Purchase %s?\nQuantity: %.1f tons\nTotal Cost: %s (%d%% of credits)\nNew Balance: %s" % [
			item_name,
			quantity,
			db_manager.format_credits(total_cost),
			int((total_cost / current_credits) * 100),
			db_manager.format_credits(current_credits - total_cost)
		]
		
		var confirmed = await _show_confirmation(confirm_text)
		if not confirmed:
			return
	
	var t1 = Time.get_ticks_msec()
	
	# Execute purchase
	if db_manager.execute_purchase(item_id, quantity, total_cost, system_id, market_type):
		print("Execute purchase: %d ms" % (Time.get_ticks_msec() - t1))
		
		var t2 = Time.get_ticks_msec()
		refresh_player_state()
		print("Refresh player state: %d ms" % (Time.get_ticks_msec() - t2))
		
		var t3 = Time.get_ticks_msec()
		refresh_market()
		print("Refresh market: %d ms" % (Time.get_ticks_msec() - t3))
		
		var t4 = Time.get_ticks_msec()
		refresh_cargo()
		print("Refresh cargo: %d ms" % (Time.get_ticks_msec() - t4))
		
		print("TOTAL PURCHASE TIME: %d ms" % (Time.get_ticks_msec() - start_time))
		
		credits_changed.emit()
		cargo_changed.emit()
	else:
		_show_error("Purchase failed!")

func _on_item_sold(item_id: int, item_name: String, quantity: float, price_per_ton: float):
	var total_revenue = quantity * price_per_ton
	
	# Validate sale
	var owned_quantity = 0.0
	for item in player_inventory:
		if item.get("item_id") == item_id:
			owned_quantity = item.get("quantity_tons", 0)
			break
	
	if owned_quantity < quantity:
		_show_error("You don't have that much to sell!")
		return
	
	# Execute sale
	if db_manager.execute_sale(item_id, quantity, total_revenue):
		print("Sold %.1f tons of %s for %s" % [quantity, item_name, db_manager.format_credits(total_revenue)])
		refresh_player_state()
		refresh_cargo()
		credits_changed.emit()
		cargo_changed.emit()
	else:
		_show_error("Sale failed!")

# ============================================================================
# UI DIALOGS
# ============================================================================

func _show_confirmation(message: String) -> bool:
	var dialog = ConfirmationDialog.new()
	add_child(dialog)
	dialog.dialog_text = message
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	
	dialog.confirmed.connect(func():
		confirmation_result.emit(true)
		dialog.queue_free()
	)
	
	dialog.canceled.connect(func():
		confirmation_result.emit(false)
		dialog.queue_free()
	)
	
	dialog.close_requested.connect(func():
		confirmation_result.emit(false)
		dialog.queue_free()
	)
	
	dialog.popup_centered()
	
	# Wait for our custom signal
	var result = await confirmation_result
	return result

func _show_error(message: String):
	var dialog = AcceptDialog.new()
	add_child(dialog)
	dialog.dialog_text = message
	dialog.title = "Error"
	dialog.popup_centered()
	await dialog.confirmed
	dialog.queue_free()

func _show_victory():
	var stats_text = "Congratulations! You've reached your goal!\n\n"
	stats_text += "Final Credits: %s\n" % db_manager.format_credits(current_player_state.get("credits", 0))
	stats_text += "Total Jumps: %d\n" % current_player_state.get("total_jumps", 0)
	
	var jumps = current_player_state.get("total_jumps", 1)
	var profit = current_player_state.get("credits", 0) - 2000  # Assuming 2000 start
	var profit_per_jump = profit / jumps if jumps > 0 else 0
	stats_text += "Average Profit per Jump: %s\n" % db_manager.format_credits(profit_per_jump)
	
	win_dialog.dialog_text = stats_text
	win_dialog.popup_centered()
	game_won.emit()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func get_current_system_id() -> int:
	return current_player_state.get("current_system_id", 0)

func get_current_credits() -> float:
	return current_player_state.get("credits", 0)

func get_cargo_free() -> float:
	return current_player_state.get("cargo_free_tons", 0)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if db_manager:
			db_manager.close_database()
		get_tree().quit()
