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

# Signals
signal game_started
signal player_state_changed
signal system_changed
signal credits_changed
signal cargo_changed
signal game_won
signal confirmation_result(confirmed: bool)

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
	
	# Load initial state
	var t1 = Time.get_ticks_msec()
	refresh_player_state()
	print("Refresh player state: %d ms" % (Time.get_ticks_msec() - t1))
	
	var market_type = current_player_state.get("market_type", "infinite")
	
	# For finite markets, clear any old inventory data
	if market_type != "infinite":
		var t2 = Time.get_ticks_msec()
		db_manager.db.query("DELETE FROM system_inventory")
		print("Clear inventory: %d ms" % (Time.get_ticks_msec() - t2))
	
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
	
	market_buy_items = db_manager.get_market_buy_items(system_id, market_type)
	market_sell_prices = db_manager.get_market_sell_prices(system_id)
	
	if market_ui:
		market_ui.update_market(market_buy_items, current_player_state, market_type)

func refresh_cargo():
	player_inventory = db_manager.get_player_inventory()
	
	if cargo_ui:
		cargo_ui.update_cargo(player_inventory, market_sell_prices, current_player_state)

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
