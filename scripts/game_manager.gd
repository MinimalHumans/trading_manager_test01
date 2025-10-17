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

# Universe market system
var universe_market_values: Dictionary = {}
var market_fluctuation_amount: float = 0.3
var connected_planet_discount: float = 0.10
var market_value_per_point: float = 0.03  # Will be loaded from DB

# Event system
var current_event: Dictionary = {}
var last_event_jump: int = -999
var event_trigger_chance: float = 0.2
var event_cooldown_jumps: int = 5
var event_decay_rate: float = 0.25

# Signals
signal game_started
signal player_state_changed
signal system_changed
signal credits_changed
signal cargo_changed
signal game_won
signal confirmation_result(confirmed: bool)
signal market_values_changed

func _ready():
	await get_tree().process_frame
	connect_ui_signals()
	new_game_panel.visible = true
	game_panel.visible = false

func connect_ui_signals():
	if new_game_panel.has_signal("start_game"):
		new_game_panel.start_game.connect(_on_start_game)
	
	if system_list_ui.has_signal("system_selected"):
		system_list_ui.system_selected.connect(_on_system_selected)
	if system_list_ui.has_signal("travel_requested"):
		system_list_ui.travel_requested.connect(_on_travel_requested)
	
	if market_ui.has_signal("item_purchased"):
		market_ui.item_purchased.connect(_on_item_purchased)
	
	if cargo_ui.has_signal("item_sold"):
		cargo_ui.item_sold.connect(_on_item_sold)

# ============================================================================
# GAME INITIALIZATION
# ============================================================================

func _on_start_game(config: Dictionary):
	var start_time = Time.get_ticks_msec()
	
	if not db_manager.initialize_new_game(config):
		push_error("Failed to initialize new game")
		return
	print("Init DB: %d ms" % (Time.get_ticks_msec() - start_time))
	
	# Load tunable variables from database
	load_tunable_variables()
	
	initialize_universe_market()
	
	var t1 = Time.get_ticks_msec()
	refresh_player_state()
	print("Refresh player state: %d ms" % (Time.get_ticks_msec() - t1))
	
	var market_type = current_player_state.get("market_type", "infinite")
	
	new_game_panel.visible = false
	game_panel.visible = true
	
	var t3 = Time.get_ticks_msec()
	system_list_ui.initialize(db_manager, current_player_state)
	print("Init system list UI: %d ms" % (Time.get_ticks_msec() - t3))
	
	var t4 = Time.get_ticks_msec()
	refresh_current_system()
	print("Refresh current system: %d ms" % (Time.get_ticks_msec() - t4))
	
	var starting_system = current_player_state.get("current_system_id", 0)
	if market_type != "infinite" and not db_manager.has_inventory_for_system(starting_system):
		var t5 = Time.get_ticks_msec()
		db_manager.initialize_system_inventory_lazy(starting_system, 0)
		print("Init starting inventory: %d ms" % (Time.get_ticks_msec() - t5))
	
	var t6 = Time.get_ticks_msec()
	refresh_market()
	print("Refresh market: %d ms" % (Time.get_ticks_msec() - t6))
	
	var t7 = Time.get_ticks_msec()
	refresh_cargo()
	print("Refresh cargo: %d ms" % (Time.get_ticks_msec() - t7))
	
	print("TOTAL START TIME: %d ms" % (Time.get_ticks_msec() - start_time))
	
	game_started.emit()

func load_tunable_variables():
	# Get tunable variables from the database manager
	market_value_per_point = db_manager.universe_market_modifier_strength
	connected_planet_discount = db_manager.connection_discount_amount
	
	print("Loaded game balance variables: Market strength: ±%.0f%%, Connection discount: %d%%" % [
		market_value_per_point * 5 * 100,  # Convert to percentage range
		connected_planet_discount * 100
	])

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
	
	for cat in categories:
		universe_market_values[cat] = randf_range(3.0, 7.0)
	
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Universe market initialized: ", universe_market_values)

func check_for_event_trigger():
	var current_jumps = current_player_state.get("total_jumps", 0)
	
	if current_jumps < 5:
		return
	
	var jumps_since_last_event = current_jumps - last_event_jump
	if jumps_since_last_event < event_cooldown_jumps:
		return
	
	if not current_event.is_empty():
		decay_active_event()
		return
	
	if randf() < event_trigger_chance:
		trigger_market_event()

func trigger_market_event():
	if db_manager.market_events.is_empty():
		return
	
	var random_event = db_manager.market_events[randi() % db_manager.market_events.size()]
	
	var magnitude = randf_range(random_event["magnitude_min"], random_event["magnitude_max"])
	
	current_event = {
		"text": random_event["event_text"],
		"category": random_event["category_name"],
		"impact_type": random_event["impact_type"],
		"magnitude": magnitude,
		"remaining_strength": magnitude
	}
	
	last_event_jump = current_player_state.get("total_jumps", 0)
	
	apply_event_to_market()
	show_event_popup(current_event["text"])
	
	print("Market event triggered: %s affects %s by %f" % [current_event["impact_type"], current_event["category"], magnitude])

func apply_event_to_market():
	if current_event.is_empty():
		return
	
	var category = current_event["category"]
	var impact_type = current_event["impact_type"]
	var strength = current_event["remaining_strength"]
	
	if impact_type == "spike":
		universe_market_values[category] += strength
	elif impact_type == "crash":
		universe_market_values[category] -= strength
	
	var categories = universe_market_values.keys()
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Market after event: ", universe_market_values)
	market_values_changed.emit()

func decay_active_event():
	if current_event.is_empty():
		return
	
	current_event["remaining_strength"] -= event_decay_rate
	
	if current_event["remaining_strength"] <= 0:
		print("Market event has fully decayed")
		current_event = {}
		return
	
	var category = current_event["category"]
	var impact_type = current_event["impact_type"]
	var old_strength = current_event["remaining_strength"] + event_decay_rate
	
	if impact_type == "spike":
		universe_market_values[category] -= old_strength
	elif impact_type == "crash":
		universe_market_values[category] += old_strength
	
	apply_event_to_market()
	
	print("Event decaying: %s remaining strength = %f" % [current_event["category"], current_event["remaining_strength"]])

func show_event_popup(event_text: String):
	var dialog = AcceptDialog.new()
	add_child(dialog)
	dialog.dialog_text = event_text
	dialog.title = "BREAKING NEWS"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	dialog.min_size = Vector2(500, 200)
	
	dialog.confirmed.connect(func():
		dialog.queue_free()
	)
	
	dialog.close_requested.connect(func():
		dialog.queue_free()
	)
	
	dialog.popup_centered()

func fluctuate_universe_market():
	var categories = universe_market_values.keys()
	
	var num_to_change = randi_range(2, 3)
	var changed_categories = []
	
	for i in range(num_to_change):
		var random_cat = categories[randi() % categories.size()]
		if not changed_categories.has(random_cat):
			changed_categories.append(random_cat)
	
	var changes = {}
	for cat in changed_categories:
		var change = randf_range(-market_fluctuation_amount, market_fluctuation_amount)
		changes[cat] = change
	
	for relationship in db_manager.category_relationships:
		var primary_cat_id = relationship["primary_category_id"]
		var influenced_cat_id = relationship["influenced_category_id"]
		var strength = relationship["correlation_strength"]
		
		var primary_cat_name = _get_category_name_by_id(primary_cat_id)
		var influenced_cat_name = _get_category_name_by_id(influenced_cat_id)
		
		if changes.has(primary_cat_name):
			var primary_change = changes[primary_cat_name]
			var influenced_change = primary_change * strength
			
			if changes.has(influenced_cat_name):
				changes[influenced_cat_name] += influenced_change
			else:
				changes[influenced_cat_name] = influenced_change
	
	for cat in changes.keys():
		universe_market_values[cat] += changes[cat]
	
	var total = 0.0
	for cat in categories:
		total += universe_market_values[cat]
	
	var scale_factor = 35.0 / total
	for cat in categories:
		universe_market_values[cat] *= scale_factor
	
	print("Market fluctuated: ", universe_market_values)
	market_values_changed.emit()

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
	
	# Get buy items first (this includes player-sold items)
	market_buy_items = db_manager.get_market_buy_items(
		system_id, 
		market_type, 
		universe_market_values, 
		connected_planet_discount,
		market_value_per_point
	)
	
	player_inventory = db_manager.get_player_inventory()
	
	# Get sell prices based on what the system wants to buy
	market_sell_prices = db_manager.get_market_sell_prices(
		system_id,
		universe_market_values,
		connected_planet_discount,
		market_value_per_point
	)
	
	if market_ui:
		market_ui.update_market(market_buy_items, current_player_state, market_type)

func refresh_cargo():
	if cargo_ui:
		cargo_ui.update_cargo(player_inventory, market_sell_prices, current_player_state)
		cargo_ui.update_market_graph(universe_market_values)

# ============================================================================
# TRAVEL SYSTEM
# ============================================================================

func _on_system_selected(system_id: int):
	pass

func _on_travel_requested(destination_id: int, distance: int):
	var start_time = Time.get_ticks_msec()
	
	var fuel_cost = distance * current_player_state.get("base_fuel_cost", 25)
	var current_credits = current_player_state.get("credits", 0)
	var market_type = current_player_state.get("market_type", "infinite")
	var current_sys_id = current_player_state.get("current_system_id", 0)
	
	if current_credits < fuel_cost:
		_show_error("Insufficient credits for fuel!")
		return
	
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
	
	if db_manager.execute_travel(destination_id, distance, fuel_cost, current_sys_id):
		print("Execute travel: %d ms" % (Time.get_ticks_msec() - t1))
		
		fluctuate_universe_market()
		check_for_event_trigger()
		
		if market_type != "infinite":
			var t2 = Time.get_ticks_msec()
			var has_inventory = db_manager.has_inventory_for_system(destination_id)
			print("Check inventory: %d ms" % (Time.get_ticks_msec() - t2))
			
			if not has_inventory:
				var t3 = Time.get_ticks_msec()
				var current_jumps = current_player_state.get("total_jumps", 0)
				db_manager.initialize_system_inventory_lazy(destination_id, current_jumps + distance)
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
	
	if current_credits < total_cost:
		_show_error("Insufficient credits!")
		return
	
	if cargo_free < quantity:
		_show_error("Insufficient cargo space!")
		return
	
	if market_type != "infinite":
		# Check total available stock (system + player-sold)
		var available = db_manager.get_total_available_stock(system_id, item_id)
		
		if quantity > available:
			_show_error("Insufficient stock! Only %.1f tons available." % available)
			return
	
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
	print("=== SELLING DEBUG ===")
	print("Item: %s (ID: %d)" % [item_name, item_id])
	print("Sell price offered: %f cr/ton" % price_per_ton)
	
	# Check if resale penalty was applied
	if market_sell_prices.has(item_id):
		var price_info = market_sell_prices[item_id]
		if price_info.get("resale_penalty", false):
			print("Resale penalty applied (selling at same market)")
		else:
			print("No penalty - selling at different market")
	
	for item in market_buy_items:
		if item["item_id"] == item_id:
			print("Current buy price: %f cr/ton" % item["sell_price"])
			print("Ratio: sell/buy = %f" % (price_per_ton / item["sell_price"]))
			break
	print("====================")
	
	var total_revenue = quantity * price_per_ton
	var system_id = current_player_state.get("current_system_id", 0)
	
	var owned_quantity = 0.0
	for item in player_inventory:
		if item.get("item_id") == item_id:
			owned_quantity = item.get("quantity_tons", 0)
			break
	
	if owned_quantity < quantity:
		_show_error("You don't have that much to sell!")
		return
	
	if db_manager.execute_sale(item_id, quantity, total_revenue, system_id):
		print("Sold %.1f tons of %s for %s (added to system market)" % [quantity, item_name, db_manager.format_credits(total_revenue)])
		refresh_player_state()
		refresh_market()
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
	var profit = current_player_state.get("credits", 0) - 2000
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
