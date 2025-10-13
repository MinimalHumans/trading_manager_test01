# database_manager.gd
# Handles all SQLite database operations for the trading prototype

extends Node

# Signal when database is ready
signal database_ready

# Database reference
var db: SQLite
var db_path: String = "res://data/trading_economy.db"

# Cached data for performance
var all_items: Array = []
var all_systems: Array = []
var all_categories: Array = []
var system_connections: Dictionary = {}

func _ready():
	initialize_database()

# Initialize database connection
func initialize_database() -> bool:
	db = SQLite.new()
	db.path = db_path
	
	if not db.open_db():
		push_error("Failed to open database at: " + db_path)
		return false
	
	print("Database opened successfully")
	cache_static_data()
	return true

# Cache frequently accessed data
func cache_static_data():
	all_items = get_all_items()
	all_systems = get_all_systems()
	all_categories = get_all_categories()
	system_connections = get_all_connections()
	print("Cached %d items, %d systems" % [all_items.size(), all_systems.size()])
	
	# Emit ready signal
	database_ready.emit()
	print("Database ready signal emitted")

# ============================================================================
# QUERY FUNCTIONS - Items and Categories
# ============================================================================

func get_all_items() -> Array:
	var query = """
	SELECT 
		i.item_id,
		i.item_name,
		i.base_price,
		i.description,
		c.category_id,
		c.category_name,
		r.rarity_id,
		r.rarity_name,
		r.price_multiplier
	FROM items i
	JOIN categories c ON i.category_id = c.category_id
	JOIN rarity_tiers r ON i.rarity_id = r.rarity_id
	ORDER BY c.category_name, r.rarity_id, i.item_name
	"""
	
	db.query(query)
	return db.query_result

func get_all_categories() -> Array:
	db.query("SELECT * FROM categories ORDER BY category_name")
	return db.query_result

# ============================================================================
# QUERY FUNCTIONS - Systems and Connections
# ============================================================================

func get_all_systems() -> Array:
	var query = """
	SELECT 
		s.system_id,
		s.system_name,
		s.description,
		s.planet_type_id,
		pt.planet_type_name
	FROM systems s
	JOIN planet_types pt ON s.planet_type_id = pt.planet_type_id
	ORDER BY s.system_name
	"""
	
	db.query(query)
	return db.query_result

func get_system_by_id(system_id: int) -> Dictionary:
	var query = """
	SELECT 
		s.system_id,
		s.system_name,
		s.description,
		s.planet_type_id,
		pt.planet_type_name
	FROM systems s
	JOIN planet_types pt ON s.planet_type_id = pt.planet_type_id
	WHERE s.system_id = %d
	""" % system_id
	
	db.query(query)
	if db.query_result.size() > 0:
		return db.query_result[0]
	return {}

func get_all_connections() -> Dictionary:
	var query = """
	SELECT 
		system_a_id,
		system_b_id,
		jump_distance
	FROM system_connections_bidirectional
	"""
	
	db.query(query)
	var connections = {}
	
	for row in db.query_result:
		var from_id = row["system_a_id"]
		if not connections.has(from_id):
			connections[from_id] = []
		connections[from_id].append({
			"to_id": row["system_b_id"],
			"distance": row["jump_distance"]
		})
	
	return connections

func get_connections_from_system(system_id: int) -> Array:
	if system_connections.has(system_id):
		return system_connections[system_id]
	return []

# ============================================================================
# QUERY FUNCTIONS - Market Data
# ============================================================================

func get_market_buy_items(system_id: int, market_type: String = "infinite") -> Array:
	var query = """
	SELECT 
		item_id,
		item_name,
		category_name,
		rarity_name,
		base_price,
		sell_price,
		availability_percent,
		price_category
	FROM system_market_buy
	WHERE system_id = %d
	ORDER BY category_name, rarity_name, item_name
	""" % system_id
	
	db.query(query)
	var items = db.query_result
	
	# If finite market, get actual stock info
	if market_type != "infinite":
		for item in items:
			var stock_info = get_item_stock(system_id, item["item_id"])
			item["current_stock"] = stock_info.get("current_stock_tons", 0)
			item["max_stock"] = stock_info.get("max_stock_tons", 0)
		
		print("Loaded market for system %d: %d items with stock data" % [system_id, items.size()])
	
	return items

func get_market_sell_prices(system_id: int) -> Dictionary:
	var query = """
	SELECT 
		item_id,
		item_name,
		buy_price,
		price_category,
		will_buy
	FROM system_market_sell
	WHERE system_id = %d
	""" % system_id
	
	db.query(query)
	
	# Convert to dictionary for easy lookup
	var prices = {}
	for row in db.query_result:
		prices[row["item_id"]] = row
	
	return prices

# ============================================================================
# SYSTEM INVENTORY FUNCTIONS (Finite Markets)
# ============================================================================

func initialize_system_inventory(market_type: String):
	"""DEPRECATED - No longer used, keeping for reference"""
	print("WARNING: initialize_system_inventory called but lazy loading is now used")

func has_inventory_for_system(system_id: int) -> bool:
	"""Check if a system has inventory initialized"""
	var query = """
	SELECT COUNT(*) as count
	FROM system_inventory
	WHERE system_id = %d
	""" % system_id
	
	db.query(query)
	
	if db.query_result.size() > 0:
		return db.query_result[0]["count"] > 0
	
	return false

func initialize_system_inventory_lazy(system_id: int):
	"""Initialize inventory for a single system on first visit"""
	print("Lazy initializing inventory for system %d" % system_id)
	
	# Get all items available at this system
	var market_items = get_market_buy_items(system_id, "infinite")  # Get base list without stock
	
	print("  Found %d items for this system" % market_items.size())
	
	# Build one big INSERT with all items
	var values_list = []
	
	for item in market_items:
		var item_id = item["item_id"]
		var availability = item.get("availability_percent", 0.5)
		
		# Max stock = availability × 100 tons
		var max_stock = availability * 100.0
		var current_stock = max_stock  # Start fully stocked
		
		values_list.append("(%d, %d, %f, %f, 0)" % [system_id, item_id, current_stock, max_stock])
	
	if values_list.size() > 0:
		# Batch insert all items at once
		var insert_query = """
		INSERT INTO system_inventory (system_id, item_id, current_stock_tons, max_stock_tons, last_updated_jump)
		VALUES %s
		""" % ", ".join(values_list)
		
		db.query(insert_query)
		print("  Initialized %d items for system %d" % [values_list.size(), system_id])

func get_item_stock(system_id: int, item_id: int) -> Dictionary:
	"""Get current stock info for an item at a system"""
	var query = """
	SELECT current_stock_tons, max_stock_tons, last_updated_jump
	FROM system_inventory
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	db.query(query)
	
	if db.query_result.size() > 0:
		return db.query_result[0]
	
	return {"current_stock_tons": 0, "max_stock_tons": 0, "last_updated_jump": 0}

func update_item_stock(system_id: int, item_id: int, quantity_change: float) -> bool:
	"""Update stock after purchase (negative quantity_change)"""
	
	# First check current stock
	var check_query = """
	SELECT current_stock_tons 
	FROM system_inventory 
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	db.query(check_query)
	
	if db.query_result.size() == 0:
		print("ERROR: No inventory record for system %d, item %d" % [system_id, item_id])
		return false
	
	var current = db.query_result[0]["current_stock_tons"]
	var new_stock = current + quantity_change  # quantity_change will be negative for purchases
	
	print("Updating stock: system=%d, item=%d, current=%.1f, change=%.1f, new=%.1f" % [
		system_id, item_id, current, quantity_change, new_stock
	])
	
	if new_stock < 0:
		print("ERROR: Stock would go negative!")
		return false
	
	var query = """
	UPDATE system_inventory
	SET current_stock_tons = %f
	WHERE system_id = %d AND item_id = %d
	""" % [new_stock, system_id, item_id]
	
	var success = db.query(query)
	
	if success:
		print("Stock updated successfully")
	else:
		print("ERROR: Failed to update stock")
	
	return success

func regenerate_system_stock_instant(system_id: int):
	"""Instantly refill all stock at a system (for finite-instant mode)"""
	var query = """
	UPDATE system_inventory
	SET current_stock_tons = max_stock_tons
	WHERE system_id = %d
	""" % system_id
	
	db.query(query)
	print("System %d stock instantly regenerated" % system_id)

func regenerate_system_stock_turnbased(system_id: int, current_jump: int):
	"""Regenerate stock based on jumps since last update (15% per jump)"""
	var query = """
	SELECT item_id, current_stock_tons, max_stock_tons, last_updated_jump
	FROM system_inventory
	WHERE system_id = %d
	""" % system_id
	
	db.query(query)
	
	for row in db.query_result:
		var item_id = row["item_id"]
		var current = row["current_stock_tons"]
		var max_stock = row["max_stock_tons"]
		var last_jump = row["last_updated_jump"]
		
		# Calculate jumps since last update
		var jumps_passed = current_jump - last_jump
		
		if jumps_passed > 0 and current < max_stock:
			# Regenerate 15% per jump
			var regen_amount = max_stock * 0.15 * jumps_passed
			var new_stock = min(current + regen_amount, max_stock)
			
			var update_query = """
			UPDATE system_inventory
			SET current_stock_tons = %f, last_updated_jump = %d
			WHERE system_id = %d AND item_id = %d
			""" % [new_stock, current_jump, system_id, item_id]
			
			db.query(update_query)
	
	print("System %d stock regenerated (turn-based)" % system_id)

# ============================================================================
# QUERY FUNCTIONS - Player State
# ============================================================================

func initialize_new_game(config: Dictionary) -> bool:
	# Clear existing game
	db.query("DELETE FROM player_inventory WHERE player_id = 1")
	db.query("DELETE FROM player_state WHERE player_id = 1")
	
	# Create new game state
	var query = """
	INSERT INTO player_state 
	(player_id, current_system_id, credits, cargo_capacity_tons, base_fuel_cost, win_goal, total_jumps, market_type)
	VALUES (1, %d, %f, %d, %f, %f, 0, '%s')
	""" % [
		config["starting_system"],
		config["starting_credits"],
		config["cargo_capacity"],
		config["base_fuel_cost"],
		config["win_goal"],
		config["market_type"]
	]
	
	return db.query(query)

func get_player_state() -> Dictionary:
	db.query("SELECT * FROM player_status WHERE player_id = 1")
	if db.query_result.size() > 0:
		return db.query_result[0]
	return {}

func get_player_inventory() -> Array:
	var query = """
	SELECT 
		pi.item_id,
		i.item_name,
		c.category_name,
		pi.quantity_tons
	FROM player_inventory pi
	JOIN items i ON pi.item_id = i.item_id
	JOIN categories c ON i.category_id = c.category_id
	WHERE pi.player_id = 1
	ORDER BY i.item_name
	"""
	
	db.query(query)
	return db.query_result

# ============================================================================
# TRANSACTION FUNCTIONS
# ============================================================================

func execute_travel(destination_system_id: int, jump_distance: int, fuel_cost: float) -> bool:
	var query = """
	UPDATE player_state 
	SET 
		current_system_id = %d,
		credits = credits - %f,
		total_jumps = total_jumps + %d
	WHERE player_id = 1
	""" % [destination_system_id, fuel_cost, jump_distance]
	
	return db.query(query)

func execute_purchase(item_id: int, quantity: float, total_cost: float, system_id: int = -1, market_type: String = "infinite") -> bool:
	print("execute_purchase called: item=%d, qty=%.1f, system=%d, market=%s" % [item_id, quantity, system_id, market_type])
	
	# Deduct credits
	var update_credits = """
	UPDATE player_state 
	SET credits = credits - %f 
	WHERE player_id = 1
	""" % total_cost
	
	if not db.query(update_credits):
		print("Failed to deduct credits")
		return false
	
	# For finite markets, deduct from system stock
	if market_type != "infinite" and system_id > 0:
		print("Finite market - updating stock")
		if not update_item_stock(system_id, item_id, -quantity):
			print("Failed to update system stock")
			# Rollback credits
			var rollback = """
			UPDATE player_state 
			SET credits = credits + %f 
			WHERE player_id = 1
			""" % total_cost
			db.query(rollback)
			return false
	
	# Check if item already in inventory
	var check_query = "SELECT quantity_tons FROM player_inventory WHERE player_id = 1 AND item_id = %d" % item_id
	db.query(check_query)
	
	if db.query_result.size() > 0:
		# Update existing
		var current_qty = db.query_result[0]["quantity_tons"]
		var new_qty = current_qty + quantity
		var update_inventory = """
		UPDATE player_inventory 
		SET quantity_tons = %f
		WHERE player_id = 1 AND item_id = %d
		""" % [new_qty, item_id]
		
		if not db.query(update_inventory):
			print("Failed to update inventory")
			return false
	else:
		# Insert new
		var insert_inventory = """
		INSERT INTO player_inventory (player_id, item_id, quantity_tons)
		VALUES (1, %d, %f)
		""" % [item_id, quantity]
		
		if not db.query(insert_inventory):
			print("Failed to insert into inventory")
			return false
	
	print("Purchase successful: %f units of item %d" % [quantity, item_id])
	return true

func execute_sale(item_id: int, quantity: float, total_revenue: float) -> bool:
	# Add credits
	var update_credits = """
	UPDATE player_state 
	SET credits = credits + %f 
	WHERE player_id = 1
	""" % total_revenue
	
	if not db.query(update_credits):
		print("Failed to add credits")
		return false
	
	# Get current quantity
	var check_query = "SELECT quantity_tons FROM player_inventory WHERE player_id = 1 AND item_id = %d" % item_id
	db.query(check_query)
	
	if db.query_result.size() == 0:
		print("Item not in inventory")
		return false
	
	var current_qty = db.query_result[0]["quantity_tons"]
	var new_qty = current_qty - quantity
	
	if new_qty <= 0.01:
		# Remove item completely
		var delete_query = """
		DELETE FROM player_inventory 
		WHERE player_id = 1 AND item_id = %d
		""" % item_id
		
		if not db.query(delete_query):
			print("Failed to delete from inventory")
			return false
	else:
		# Update quantity
		var update_inventory = """
		UPDATE player_inventory 
		SET quantity_tons = %f
		WHERE player_id = 1 AND item_id = %d
		""" % [new_qty, item_id]
		
		if not db.query(update_inventory):
			print("Failed to update inventory")
			return false
	
	print("Sale successful: %f units of item %d for %f credits" % [quantity, item_id, total_revenue])
	return true

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func get_price_color(price_category: String) -> Color:
	match price_category:
		"Very Low":
			return Color(0.0, 1.0, 0.0)  # Bright green
		"Low":
			return Color(0.56, 0.93, 0.56)  # Light green
		"Average":
			return Color(1.0, 1.0, 1.0)  # White
		"High":
			return Color(1.0, 0.65, 0.0)  # Orange
		"Very High":
			return Color(1.0, 0.27, 0.0)  # Red-orange
		_:
			return Color(1.0, 1.0, 1.0)

func get_planet_type_color(planet_type: String) -> Color:
	match planet_type:
		"Agricultural":
			return Color(0.3, 0.69, 0.31)  # Green
		"Mining":
			return Color(0.62, 0.62, 0.62)  # Gray
		"Manufacturing":
			return Color(0.13, 0.59, 0.95)  # Blue
		"Medical":
			return Color(0.96, 0.26, 0.21)  # Red
		"Military":
			return Color(0.55, 0.0, 0.0)  # Dark red
		"Research":
			return Color(0.61, 0.15, 0.69)  # Purple
		"Trade Hub":
			return Color(1.0, 0.84, 0.0)  # Gold
		"Colony":
			return Color(0.53, 0.81, 0.92)  # Light blue
		"Frontier":
			return Color(0.55, 0.27, 0.07)  # Brown
		"Pirate Haven":
			return Color(0.13, 0.13, 0.13)  # Black
		_:
			return Color(0.5, 0.5, 0.5)

func format_credits(amount: float) -> String:
	return "%s cr" % [_format_number_with_commas(int(amount))]

func _format_number_with_commas(number: int) -> String:
	var string = str(number)
	var result = ""
	var count = 0
	
	for i in range(string.length() - 1, -1, -1):
		if count == 3:
			result = "," + result
			count = 0
		result = string[i] + result
		count += 1
	
	return result

func close_database():
	if db:
		db.close_db()
		print("Database closed")
