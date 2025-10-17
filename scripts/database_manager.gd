# database_manager.gd
# Handles all SQLite database operations for the trading prototype

extends Node

# Signal when database is ready
signal database_ready

# Database references
var game_db: SQLite  # Read-only reference data
var save_db: SQLite  # Player save data (volatile)

var game_db_path: String = "res://data/trading_economy.db"
var save_db_path: String = "user://player_save.db"
var game_db_absolute_path: String = ""  # Cached absolute path for ATTACH

# Cached data for performance
var all_items: Array = []
var all_systems: Array = []
var all_categories: Array = []
var system_connections: Dictionary = {}
var category_relationships: Array = []  # Market relationships
var market_events: Array = []  # All possible events

# Tunable balance variables (loaded from database)
var rarity_multiplier_rare: float = 1.25
var rarity_multiplier_exotic: float = 1.50
var universe_market_modifier_strength: float = 0.03
var connection_discount_amount: float = 0.10

func _ready():
	initialize_database()

# Initialize database connection
func initialize_database() -> bool:
	# Open game database (read-only reference data)
	game_db = SQLite.new()
	game_db.path = game_db_path
	
	if not game_db.open_db():
		push_error("Failed to open game database at: " + game_db_path)
		return false
	
	# Cache the absolute path for ATTACH commands
	game_db_absolute_path = ProjectSettings.globalize_path(game_db_path)
	print("Game database opened successfully at: " + game_db_absolute_path)
	
	# Save database will be created on new game
	# For now, just initialize the variable
	save_db = SQLite.new()
	save_db.path = save_db_path
	
	# Load tunable variables
	load_tunable_variables()
	
	cache_static_data()
	return true

func load_tunable_variables():
	# Load balance variables from database
	var variables_to_load = [
		"rarity_multiplier_rare",
		"rarity_multiplier_exotic", 
		"universe_market_modifier_strength",
		"connection_discount_amount"
	]
	
	for var_name in variables_to_load:
		var query = "SELECT variable_value FROM global_variables WHERE variable_name = '%s'" % var_name
		game_db.query(query)
		if game_db.query_result.size() > 0:
			match var_name:
				"rarity_multiplier_rare":
					rarity_multiplier_rare = game_db.query_result[0]["variable_value"]
				"rarity_multiplier_exotic":
					rarity_multiplier_exotic = game_db.query_result[0]["variable_value"]
				"universe_market_modifier_strength":
					universe_market_modifier_strength = game_db.query_result[0]["variable_value"]
				"connection_discount_amount":
					connection_discount_amount = game_db.query_result[0]["variable_value"]
	
	print("Loaded tunable variables: Rare x%.2f, Exotic x%.2f, Market ±%.0f%%, Connection -%d%%" % [
		rarity_multiplier_rare, 
		rarity_multiplier_exotic,
		universe_market_modifier_strength * 5 * 100,  # Convert to percentage range
		connection_discount_amount * 100
	])

# Cache frequently accessed data
func cache_static_data():
	all_items = get_all_items()
	all_systems = get_all_systems()
	all_categories = get_all_categories()
	system_connections = get_all_connections()
	category_relationships = get_category_relationships()
	market_events = get_all_market_events()
	
	# Emit ready signal
	database_ready.emit()

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
	
	game_db.query(query)
	return game_db.query_result

func get_all_categories() -> Array:
	game_db.query("SELECT * FROM categories ORDER BY category_name")
	return game_db.query_result

func get_category_relationships() -> Array:
	var query = """
	SELECT 
		primary_category_id,
		influenced_category_id,
		correlation_strength
	FROM category_market_relationships
	"""
	
	game_db.query(query)
	return game_db.query_result

func get_all_market_events() -> Array:
	var query = """
	SELECT 
		event_id,
		event_text,
		category_name,
		impact_type,
		magnitude_min,
		magnitude_max
	FROM market_events
	ORDER BY category_name, event_id
	"""
	
	game_db.query(query)
	return game_db.query_result

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
	
	game_db.query(query)
	return game_db.query_result

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
	
	game_db.query(query)
	if game_db.query_result.size() > 0:
		return game_db.query_result[0]
	return {}

func get_all_connections() -> Dictionary:
	var query = """
	SELECT 
		system_a_id,
		system_b_id,
		jump_distance
	FROM system_connections_bidirectional
	"""
	
	game_db.query(query)
	var connections = {}
	
	for row in game_db.query_result:
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

func get_nearby_produced_categories(system_id: int) -> Array:
	var connections = get_connections_from_system(system_id)
	var nearby_categories = []
	
	for connection in connections:
		if connection["distance"] == 1:  # Only 1-jump neighbors
			var neighbor_id = connection["to_id"]
			var produced = get_system_produced_categories(neighbor_id)
			for cat_id in produced:
				if not nearby_categories.has(cat_id):
					nearby_categories.append(cat_id)
	
	return nearby_categories

func get_system_produced_categories(system_id: int) -> Array:
	var system_info = get_system_by_id(system_id)
	if system_info.is_empty():
		return []
	
	var planet_type_id = system_info["planet_type_id"]
	
	var query = """
	SELECT category_id
	FROM planet_category_modifiers
	WHERE planet_type_id = %d
	AND price_modifier < 0
	""" % planet_type_id
	
	game_db.query(query)
	
	var categories = []
	for row in game_db.query_result:
		categories.append(row["category_id"])
	
	return categories

# ============================================================================
# QUERY FUNCTIONS - Market Data
# ============================================================================

func get_market_buy_items(system_id: int, market_type: String = "infinite", universe_market: Dictionary = {}, connected_discount: float = 0.10, market_modifier_per_point: float = 0.05) -> Array:
	var base_items = []
	
	if market_type == "infinite":
		var query = """
		SELECT 
			smb.item_id,
			smb.item_name,
			c.category_id,
			smb.category_name,
			smb.rarity_name,
			smb.base_price,
			smb.sell_price,
			smb.availability_percent,
			smb.price_category
		FROM system_market_buy smb
		JOIN categories c ON smb.category_name = c.category_name
		WHERE smb.system_id = %d
		ORDER BY smb.category_name, smb.rarity_name, smb.item_name
		""" % system_id
		
		game_db.query(query)
		base_items = game_db.query_result
	else:
		if not save_db or not save_db.query("SELECT 1"):
			push_error("Save database not available for finite market query")
			return []
		
		var attach_query = "ATTACH DATABASE '%s' AS game_db" % game_db_absolute_path
		if not save_db.query(attach_query):
			push_error("Failed to attach game database for finite market query")
			return []
		
		var finite_query = """
		SELECT 
			i.item_id,
			i.item_name,
			i.category_id,
			c.category_name,
			r.rarity_name,
			i.base_price,
			ROUND(i.base_price * r.price_multiplier * (1 + COALESCE(pcm.price_modifier, 0)), 2) as sell_price,
			si.current_stock_tons as current_stock,
			si.max_stock_tons as max_stock,
			CASE 
				WHEN COALESCE(pcm.price_modifier, 0) <= -0.40 THEN 'Very Low'
				WHEN COALESCE(pcm.price_modifier, 0) <= -0.20 THEN 'Low'
				WHEN COALESCE(pcm.price_modifier, 0) <= -0.05 THEN 'Below Average'
				WHEN COALESCE(pcm.price_modifier, 0) <= 0.05 THEN 'Average'
				WHEN COALESCE(pcm.price_modifier, 0) <= 0.20 THEN 'Above Average'
				WHEN COALESCE(pcm.price_modifier, 0) <= 0.40 THEN 'High'
				ELSE 'Very High'
			END as price_category
		FROM system_inventory si
	
		JOIN game_db.items i ON si.item_id = i.item_id
		JOIN game_db.categories c ON i.category_id = c.category_id
		JOIN game_db.rarity_tiers r ON i.rarity_id = r.rarity_id
		JOIN game_db.systems s ON si.system_id = s.system_id
		LEFT JOIN game_db.planet_category_modifiers pcm ON 
			s.planet_type_id = pcm.planet_type_id AND
			i.category_id = pcm.category_id AND
			pcm.price_modifier < 0
		WHERE si.system_id = %d
		ORDER BY c.category_name, r.rarity_name, i.item_name
		""" % system_id
		
		save_db.query(finite_query)
		base_items = save_db.query_result
		save_db.query("DETACH DATABASE game_db")
	
	# Apply universe market modifiers and connection discounts
	if not universe_market.is_empty():
		var nearby_categories = get_nearby_produced_categories(system_id)
		
		for item in base_items:
			var category_id = item.get("category_id", 0)
			var category_name = item.get("category_name", "")
			var base_sell_price = item.get("sell_price", 0)
			
			var market_value = universe_market.get(category_name, 5.0)
			var market_modifier = 1.0 + ((market_value - 5.0) * market_modifier_per_point)
			
			var connection_modifier = 1.0
			if nearby_categories.has(category_id):
				connection_modifier = 1.0 - connected_discount
			
			var final_price = base_sell_price * market_modifier * connection_modifier
			item["sell_price"] = round(final_price * 100.0) / 100.0
			
			var base_price = item.get("base_price", 1.0)
			var total_price_ratio = final_price / base_price

			if total_price_ratio <= 0.60:
				item["price_category"] = "Very Low"
			elif total_price_ratio <= 0.80:
				item["price_category"] = "Low"
			elif total_price_ratio <= 0.95:
				item["price_category"] = "Below Average"
			elif total_price_ratio <= 1.05:
				item["price_category"] = "Average"
			elif total_price_ratio <= 1.20:
				item["price_category"] = "Above Average"
			elif total_price_ratio <= 1.40:
				item["price_category"] = "High"
			else:
				item["price_category"] = "Very High"
	
	# Add player-sold items to the market
	var player_sold_items = get_player_sold_items_at_system(system_id)
	
	for sold_item in player_sold_items:
		var item_id = sold_item["item_id"]
		
		var existing_index = -1
		for i in range(base_items.size()):
			if base_items[i]["item_id"] == item_id:
				existing_index = i
				break
		
		if existing_index >= 0:
			if market_type != "infinite":
				var current_stock = base_items[existing_index].get("current_stock", 0)
				base_items[existing_index]["current_stock"] = current_stock + sold_item["quantity_tons"]
				base_items[existing_index]["max_stock"] = base_items[existing_index].get("max_stock", current_stock)
		else:
			var category_id = sold_item.get("category_id", 0)
			var category_name = sold_item.get("category_name", "")
			var base_price = sold_item.get("base_price", 100.0)
			
			var sell_price = base_price
			if not universe_market.is_empty():
				var nearby_categories = get_nearby_produced_categories(system_id)
				var market_value = universe_market.get(category_name, 5.0)
				var market_modifier = 1.0 + ((market_value - 5.0) * market_modifier_per_point)
				
				var connection_modifier = 1.0
				if nearby_categories.has(category_id):
					connection_modifier = 1.0 - connected_discount
				
				sell_price = base_price * market_modifier * connection_modifier
			
			var new_item = {
				"item_id": item_id,
				"item_name": sold_item["item_name"],
				"category_id": category_id,
				"category_name": category_name,
				"rarity_name": sold_item.get("rarity_name", "Common"),
				"base_price": base_price,
				"sell_price": round(sell_price * 100.0) / 100.0,
				"price_category": "Average"
			}
			
			if market_type != "infinite":
				new_item["current_stock"] = sold_item["quantity_tons"]
				new_item["max_stock"] = sold_item["quantity_tons"]
			else:
				new_item["availability_percent"] = 1.0
			
			base_items.append(new_item)
	
	return base_items

func get_market_sell_prices(system_id: int, universe_market: Dictionary = {}, connected_discount: float = 0.10, market_modifier_per_point: float = 0.05) -> Dictionary:
	"""Get what the system is willing to buy (check for same-market resale penalty)"""
	
	# Get the market type from the save database
	var market_type = "infinite"  # default
	if save_db and save_db.query("SELECT market_type FROM player_state WHERE player_id = 1"):
		if save_db.query_result.size() > 0:
			market_type = save_db.query_result[0]["market_type"]
	
	# Get the ACTUAL current buy prices from the market
	var current_buy_items = get_market_buy_items(
		system_id, 
		market_type,
		universe_market,
		connected_discount,
		market_modifier_per_point
	)
	
	# Convert to sell prices
	var prices = {}
	
	for item in current_buy_items:
		var item_id = item["item_id"]
		var current_buy_price = item["sell_price"]  # This is what player pays to buy
		
		# Check if this item was purchased at THIS system
		var was_purchased_here = false
		if save_db and save_db.query("SELECT purchase_system_id FROM player_inventory WHERE player_id = 1 AND item_id = %d" % item_id):
			if save_db.query_result.size() > 0:
				var purchase_system = save_db.query_result[0].get("purchase_system_id", null)
				was_purchased_here = (purchase_system == system_id)
		
		# Apply 5% penalty ONLY if selling back where purchased in same session
		var sell_multiplier = 1.0 if not was_purchased_here else 0.95
		var sell_back_price = current_buy_price * sell_multiplier
		
		prices[item_id] = {
			"item_id": item_id,
			"item_name": item["item_name"],
			"buy_price": round(sell_back_price * 100.0) / 100.0,  # What system pays player
			"price_category": item["price_category"],
			"will_buy": 1,
			"resale_penalty": was_purchased_here  # Track if penalty applied
		}
	
	return prices

# ============================================================================
# SYSTEM INVENTORY FUNCTIONS (Finite Markets)
# ============================================================================

func verify_inventory_integrity() -> Dictionary:
	if not save_db or not save_db.query("SELECT 1"):
		print("Save database not available")
		return {}
	
	var query = """
	SELECT 
		system_id,
		COUNT(*) as item_count,
		SUM(CASE WHEN current_stock_tons > 0 THEN 1 ELSE 0 END) as items_with_stock
	FROM system_inventory
	GROUP BY system_id
	"""
	
	save_db.query(query)
	
	var results = {}
	for row in save_db.query_result:
		results[row["system_id"]] = {
			"items": row["item_count"],
			"with_stock": row["items_with_stock"]
		}
	
	print("=== INVENTORY INTEGRITY CHECK ===")
	print("Systems with inventory: %d" % results.size())
	for sys_id in results.keys():
		var data = results[sys_id]
		print("  System %d: %d items, %d with stock" % [sys_id, data["items"], data["with_stock"]])
	
	return results

func has_inventory_for_system(system_id: int) -> bool:
	if not save_db or not save_db.query("SELECT 1"):
		return false
	
	var query = """
	SELECT COUNT(*) as count
	FROM system_inventory
	WHERE system_id = %d
	""" % system_id
	
	save_db.query(query)
	
	if save_db.query_result.size() > 0:
		return save_db.query_result[0]["count"] > 0
	
	return false

func initialize_system_inventory_lazy(system_id: int):
	if has_inventory_for_system(system_id):
		return
	
	var market_items = get_market_buy_items(system_id, "infinite")
	
	if market_items.size() == 0:
		push_error("No market items found for system %d" % system_id)
		return
	
	save_db.query("BEGIN TRANSACTION")
	
	for item in market_items:
		var item_id = item["item_id"]
		var availability = item.get("availability_percent", 0.5)
		var max_stock = availability * 100.0
		var current_stock = max_stock
		
		var insert_query = """
		INSERT INTO system_inventory (system_id, item_id, current_stock_tons, max_stock_tons, last_updated_jump)
		VALUES (%d, %d, %f, %f, 0)
		""" % [system_id, item_id, current_stock, max_stock]
		
		save_db.query(insert_query)
	
	save_db.query("COMMIT")

func get_item_stock(system_id: int, item_id: int) -> Dictionary:
	if not save_db or not save_db.query("SELECT 1"):
		return {"current_stock_tons": 0, "max_stock_tons": 0, "last_updated_jump": 0}
	
	var query = """
	SELECT current_stock_tons, max_stock_tons, last_updated_jump
	FROM system_inventory
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(query)
	
	if save_db.query_result.size() > 0:
		return save_db.query_result[0]
	
	return {"current_stock_tons": 0, "max_stock_tons": 0, "last_updated_jump": 0}

func get_total_available_stock(system_id: int, item_id: int) -> float:
	"""Get total available stock including both system inventory and player-sold market"""
	if not save_db or not save_db.query("SELECT 1"):
		return 0.0
	
	var total = 0.0
	
	# Get system inventory stock
	var system_query = """
	SELECT current_stock_tons
	FROM system_inventory
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(system_query)
	if save_db.query_result.size() > 0:
		total += save_db.query_result[0]["current_stock_tons"]
	
	# Get player-sold market stock
	var player_sold_query = """
	SELECT quantity_tons
	FROM player_sold_market
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(player_sold_query)
	if save_db.query_result.size() > 0:
		total += save_db.query_result[0]["quantity_tons"]
	
	return total

func update_item_stock(system_id: int, item_id: int, quantity_change: float) -> bool:
	var check_query = """
	SELECT current_stock_tons 
	FROM system_inventory 
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(check_query)
	
	if save_db.query_result.size() == 0:
		push_error("No inventory record for system %d, item %d" % [system_id, item_id])
		return false
	
	var current = save_db.query_result[0]["current_stock_tons"]
	var new_stock = current + quantity_change
	
	if new_stock < 0:
		push_error("Stock would go negative!")
		return false
	
	var query = """
	UPDATE system_inventory
	SET current_stock_tons = %f
	WHERE system_id = %d AND item_id = %d
	""" % [new_stock, system_id, item_id]
	
	return save_db.query(query)

func regenerate_system_stock_instant(system_id: int):
	if not has_inventory_for_system(system_id):
		return
	
	var query = """
	UPDATE system_inventory
	SET current_stock_tons = max_stock_tons
	WHERE system_id = %d
	""" % system_id
	
	save_db.query(query)

func regenerate_system_stock_turnbased(system_id: int, current_jump: int):
	if not has_inventory_for_system(system_id):
		return
	
	var query = """
	UPDATE system_inventory
	SET 
		current_stock_tons = MIN(
			current_stock_tons + (max_stock_tons * 0.15 * (%d - last_updated_jump)),
			max_stock_tons
		),
		last_updated_jump = %d
	WHERE system_id = %d 
		AND (%d - last_updated_jump) > 0
		AND current_stock_tons < max_stock_tons
	""" % [current_jump, current_jump, system_id, current_jump]
	
	save_db.query(query)

# ============================================================================
# PLAYER SOLD MARKET FUNCTIONS
# ============================================================================

func add_to_player_sold_market(system_id: int, item_id: int, quantity: float) -> bool:
	if not save_db or not save_db.query("SELECT 1"):
		return false
	
	var check_query = """
	SELECT quantity_tons FROM player_sold_market
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(check_query)
	
	if save_db.query_result.size() > 0:
		var current = save_db.query_result[0]["quantity_tons"]
		var new_qty = current + quantity
		
		var update_query = """
		UPDATE player_sold_market
		SET quantity_tons = %f
		WHERE system_id = %d AND item_id = %d
		""" % [new_qty, system_id, item_id]
		
		return save_db.query(update_query)
	else:
		var insert_query = """
		INSERT INTO player_sold_market (system_id, item_id, quantity_tons)
		VALUES (%d, %d, %f)
		""" % [system_id, item_id, quantity]
		
		return save_db.query(insert_query)

func get_player_sold_items_at_system(system_id: int) -> Array:
	if not save_db or not save_db.query("SELECT 1"):
		return []
	
	var attach_query = "ATTACH DATABASE '%s' AS game_db" % game_db_absolute_path
	if not save_db.query(attach_query):
		return []
	
	var query = """
	SELECT 
		psm.item_id,
		i.item_name,
		i.base_price,
		c.category_id,
		c.category_name,
		r.rarity_name,
		psm.quantity_tons
	FROM player_sold_market psm
	JOIN game_db.items i ON psm.item_id = i.item_id
	JOIN game_db.categories c ON i.category_id = c.category_id
	JOIN game_db.rarity_tiers r ON i.rarity_id = r.rarity_id
	WHERE psm.system_id = %d
	ORDER BY c.category_name, i.item_name
	""" % system_id
	
	save_db.query(query)
	var result = save_db.query_result
	
	save_db.query("DETACH DATABASE game_db")
	
	return result

func clear_player_sold_market_at_system(system_id: int):
	if not save_db or not save_db.query("SELECT 1"):
		return
	
	# Also clear purchase location tracking when leaving a system
	var query = """
	UPDATE player_inventory
	SET purchase_system_id = NULL
	WHERE player_id = 1 AND purchase_system_id = %d
	""" % system_id
	
	save_db.query(query)
	
	var clear_query = """
	DELETE FROM player_sold_market
	WHERE system_id = %d
	""" % system_id
	
	save_db.query(clear_query)
	print("Cleared player-sold market and purchase tracking at system %d" % system_id)

func remove_from_player_sold_market(system_id: int, item_id: int, quantity: float) -> bool:
	if not save_db or not save_db.query("SELECT 1"):
		return false
	
	var check_query = """
	SELECT quantity_tons FROM player_sold_market
	WHERE system_id = %d AND item_id = %d
	""" % [system_id, item_id]
	
	save_db.query(check_query)
	
	if save_db.query_result.size() == 0:
		return true
	
	var current = save_db.query_result[0]["quantity_tons"]
	var new_qty = current - quantity
	
	if new_qty <= 0.01:
		var delete_query = """
		DELETE FROM player_sold_market
		WHERE system_id = %d AND item_id = %d
		""" % [system_id, item_id]
		
		return save_db.query(delete_query)
	else:
		var update_query = """
		UPDATE player_sold_market
		SET quantity_tons = %f
		WHERE system_id = %d AND item_id = %d
		""" % [new_qty, system_id, item_id]
		
		return save_db.query(update_query)

# ============================================================================
# QUERY FUNCTIONS - Player State
# ============================================================================

func initialize_new_game(config: Dictionary) -> bool:
	if save_db.path and FileAccess.file_exists(save_db.path):
		DirAccess.remove_absolute(save_db.path)
		print("Deleted old save database")
	
	if not save_db.open_db():
		push_error("Failed to create save database at: " + save_db_path)
		return false
	
	print("Save database opened at: " + ProjectSettings.globalize_path(save_db_path))
	
	var schema_queries = [
		"""CREATE TABLE player_state (
			player_id INTEGER PRIMARY KEY DEFAULT 1,
			current_system_id INTEGER NOT NULL,
			credits REAL NOT NULL,
			cargo_capacity_tons INTEGER NOT NULL,
			base_fuel_cost REAL NOT NULL,
			win_goal REAL NOT NULL,
			total_jumps INTEGER DEFAULT 0,
			game_start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			market_type TEXT DEFAULT 'infinite' CHECK (market_type IN ('infinite', 'finite_instant', 'finite_turn'))
		)""",
		"""CREATE TABLE player_inventory (
			player_id INTEGER DEFAULT 1,
			item_id INTEGER NOT NULL,
			quantity_tons REAL NOT NULL,
			purchase_system_id INTEGER DEFAULT NULL,
			PRIMARY KEY (player_id, item_id),
			CHECK (quantity_tons > 0)
		)""",
		"""CREATE TABLE system_inventory (
			system_id INTEGER NOT NULL,
			item_id INTEGER NOT NULL,
			current_stock_tons REAL NOT NULL DEFAULT 0,
			max_stock_tons REAL NOT NULL DEFAULT 100,
			last_updated_jump INTEGER DEFAULT 0,
			PRIMARY KEY (system_id, item_id),
			CHECK (current_stock_tons >= 0),
			CHECK (current_stock_tons <= max_stock_tons)
		)""",
		"""CREATE TABLE player_sold_market (
			system_id INTEGER NOT NULL,
			item_id INTEGER NOT NULL,
			quantity_tons REAL NOT NULL DEFAULT 0,
			PRIMARY KEY (system_id, item_id),
			CHECK (quantity_tons >= 0)
		)""",
		"CREATE INDEX idx_system_inventory ON system_inventory(system_id, item_id)",
		"CREATE INDEX idx_player_inv_item ON player_inventory(item_id)",
		"CREATE INDEX idx_player_sold_market ON player_sold_market(system_id, item_id)"
	]
	
	for i in range(schema_queries.size()):
		if not save_db.query(schema_queries[i]):
			push_error("Failed to create save database schema at step %d" % i)
			return false
	
	print("Save database schema created successfully")
	
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
	
	if not save_db.query(query):
		push_error("Failed to insert initial player state")
		return false
	
	print("Initial player state created: System %d, Credits %f" % [config["starting_system"], config["starting_credits"]])
	
	save_db.query("SELECT * FROM player_state WHERE player_id = 1")
	if save_db.query_result.size() == 0:
		push_error("Player state insert verification failed!")
		return false
	
	print("Player state verified in database")
	return true

func get_player_state() -> Dictionary:
	if not save_db or not save_db.query("SELECT 1"):
		push_error("Save database not open in get_player_state()")
		return {}
	
	var attach_query = "ATTACH DATABASE '%s' AS game_db" % game_db_absolute_path
	if not save_db.query(attach_query):
		push_error("Failed to attach game database in get_player_state()")
		return {}
	
	var query = """
	SELECT 
		ps.player_id,
		ps.credits,
		ps.cargo_capacity_tons,
		ps.total_jumps,
		ps.win_goal,
		ps.base_fuel_cost,
		ps.market_type,
		COALESCE(SUM(pi.quantity_tons), 0) AS cargo_used_tons,
		ps.cargo_capacity_tons - COALESCE(SUM(pi.quantity_tons), 0) AS cargo_free_tons,
		ROUND((COALESCE(SUM(pi.quantity_tons), 0) / ps.cargo_capacity_tons) * 100, 1) AS cargo_percent_full,
		ps.current_system_id,
		s.system_name AS current_system_name,
		pt.planet_type_name AS current_planet_type
	FROM player_state ps
	JOIN game_db.systems s ON ps.current_system_id = s.system_id
	JOIN game_db.planet_types pt ON s.planet_type_id = pt.planet_type_id
	LEFT JOIN player_inventory pi ON ps.player_id = pi.player_id
	WHERE ps.player_id = 1
	GROUP BY ps.player_id
	"""
	
	if not save_db.query(query):
		push_error("Failed to query player state")
		save_db.query("DETACH DATABASE game_db")
		return {}
	
	var result = {}
	if save_db.query_result.size() > 0:
		result = save_db.query_result[0]
	
	save_db.query("DETACH DATABASE game_db")
	
	return result

func get_player_inventory() -> Array:
	if not save_db or not save_db.query("SELECT 1"):
		return []
	
	var attach_query = "ATTACH DATABASE '%s' AS game_db" % game_db_absolute_path
	if not save_db.query(attach_query):
		push_error("Failed to attach game database in get_player_inventory()")
		return []
	
	var query = """
	SELECT 
		pi.item_id,
		i.item_name,
		c.category_name,
		pi.quantity_tons,
		pi.purchase_system_id
	FROM player_inventory pi
	JOIN game_db.items i ON pi.item_id = i.item_id
	JOIN game_db.categories c ON i.category_id = c.category_id
	WHERE pi.player_id = 1
	ORDER BY i.item_name
	"""
	
	save_db.query(query)
	var result = save_db.query_result
	
	save_db.query("DETACH DATABASE game_db")
	
	return result

# ============================================================================
# TRANSACTION FUNCTIONS
# ============================================================================

func execute_travel(destination_system_id: int, jump_distance: int, fuel_cost: float, current_system_id: int) -> bool:
	save_db.query("BEGIN TRANSACTION")
	
	var query = """
	UPDATE player_state 
	SET 
		current_system_id = %d,
		credits = credits - %f,
		total_jumps = total_jumps + %d
	WHERE player_id = 1
	""" % [destination_system_id, fuel_cost, jump_distance]
	
	if not save_db.query(query):
		save_db.query("ROLLBACK")
		return false
	
	clear_player_sold_market_at_system(current_system_id)
	
	save_db.query("COMMIT")
	return true

func execute_purchase(item_id: int, quantity: float, total_cost: float, system_id: int = -1, market_type: String = "infinite") -> bool:
	save_db.query("BEGIN TRANSACTION")
	
	var update_credits = """
	UPDATE player_state 
	SET credits = credits - %f 
	WHERE player_id = 1
	""" % total_cost
	
	if not save_db.query(update_credits):
		save_db.query("ROLLBACK")
		return false
	
	var bought_from_player_market = false
	if system_id > 0:
		var player_sold_check = """
		SELECT quantity_tons FROM player_sold_market
		WHERE system_id = %d AND item_id = %d
		""" % [system_id, item_id]
		
		save_db.query(player_sold_check)
		
		if save_db.query_result.size() > 0:
			var available = save_db.query_result[0]["quantity_tons"]
			
			if available >= quantity:
				if not remove_from_player_sold_market(system_id, item_id, quantity):
					save_db.query("ROLLBACK")
					return false
				bought_from_player_market = true
			else:
				if not remove_from_player_sold_market(system_id, item_id, available):
					save_db.query("ROLLBACK")
					return false
				
				var remaining = quantity - available
				if market_type != "infinite":
					if not update_item_stock(system_id, item_id, -remaining):
						save_db.query("ROLLBACK")
						return false
				bought_from_player_market = true
	
	if market_type != "infinite" and system_id > 0 and not bought_from_player_market:
		if not update_item_stock(system_id, item_id, -quantity):
			save_db.query("ROLLBACK")
			return false
	
	var check_query = "SELECT quantity_tons, purchase_system_id FROM player_inventory WHERE player_id = 1 AND item_id = %d" % item_id
	save_db.query(check_query)
	
	if save_db.query_result.size() > 0:
		var current_qty = save_db.query_result[0]["quantity_tons"]
		var existing_purchase_system = save_db.query_result[0].get("purchase_system_id", null)
		var new_qty = current_qty + quantity
		
		# If we already have some from a different system or no system recorded, don't update purchase_system_id
		# This preserves the ability to sell without penalty at other locations
		if existing_purchase_system == null or existing_purchase_system != system_id:
			var update_inventory = """
			UPDATE player_inventory 
			SET quantity_tons = %f
			WHERE player_id = 1 AND item_id = %d
			""" % [new_qty, item_id]
			
			if not save_db.query(update_inventory):
				save_db.query("ROLLBACK")
				return false
		else:
			# Same system - just update quantity
			var update_inventory = """
			UPDATE player_inventory 
			SET quantity_tons = %f
			WHERE player_id = 1 AND item_id = %d
			""" % [new_qty, item_id]
			
			if not save_db.query(update_inventory):
				save_db.query("ROLLBACK")
				return false
	else:
		# New item - record purchase location
		var insert_inventory = """
		INSERT INTO player_inventory (player_id, item_id, quantity_tons, purchase_system_id)
		VALUES (1, %d, %f, %d)
		""" % [item_id, quantity, system_id]
		
		if not save_db.query(insert_inventory):
			save_db.query("ROLLBACK")
			return false
	
	save_db.query("COMMIT")
	return true

func execute_sale(item_id: int, quantity: float, total_revenue: float, system_id: int) -> bool:
	save_db.query("BEGIN TRANSACTION")
	
	var update_credits = """
	UPDATE player_state 
	SET credits = credits + %f 
	WHERE player_id = 1
	""" % total_revenue
	
	if not save_db.query(update_credits):
		save_db.query("ROLLBACK")
		return false
	
	var check_query = "SELECT quantity_tons FROM player_inventory WHERE player_id = 1 AND item_id = %d" % item_id
	save_db.query(check_query)
	
	if save_db.query_result.size() == 0:
		save_db.query("ROLLBACK")
		return false
	
	var current_qty = save_db.query_result[0]["quantity_tons"]
	var new_qty = current_qty - quantity
	
	if new_qty <= 0.01:
		var delete_query = """
		DELETE FROM player_inventory 
		WHERE player_id = 1 AND item_id = %d
		""" % item_id
		
		if not save_db.query(delete_query):
			save_db.query("ROLLBACK")
			return false
	else:
		# Keep the item but don't change purchase_system_id
		var update_inventory = """
		UPDATE player_inventory 
		SET quantity_tons = %f
		WHERE player_id = 1 AND item_id = %d
		""" % [new_qty, item_id]
		
		if not save_db.query(update_inventory):
			save_db.query("ROLLBACK")
			return false
	
	if not add_to_player_sold_market(system_id, item_id, quantity):
		save_db.query("ROLLBACK")
		return false
	
	save_db.query("COMMIT")
	return true

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# In get_price_color() function, replace with:
func get_price_color(price_category: String) -> Color:
	match price_category:
		"Very Low":
			return Color(0.0, 1.0, 0.0)  # Bright green
		"Low":
			return Color(0.56, 0.93, 0.56)  # Light green
		"Below Average":
			return Color(0.75, 1.0, 0.75)  # Very light green
		"Average":
			return Color(1.0, 1.0, 1.0)  # White
		"Above Average":
			return Color(1.0, 0.85, 0.5)  # Light orange
		"High":
			return Color(1.0, 0.65, 0.0)  # Orange
		"Very High":
			return Color(1.0, 0.27, 0.0)  # Red-orange
		_:
			return Color(1.0, 1.0, 1.0)

func get_planet_type_color(planet_type: String) -> Color:
	match planet_type:
		"Agricultural":
			return Color(0.3, 0.69, 0.31)
		"Mining":
			return Color(0.62, 0.62, 0.62)
		"Manufacturing":
			return Color(0.13, 0.59, 0.95)
		"Medical":
			return Color(0.96, 0.26, 0.21)
		"Military":
			return Color(0.55, 0.0, 0.0)
		"Research":
			return Color(0.61, 0.15, 0.69)
		"Trade Hub":
			return Color(1.0, 0.84, 0.0)
		"Colony":
			return Color(0.53, 0.81, 0.92)
		"Frontier":
			return Color(0.55, 0.27, 0.07)
		"Pirate Haven":
			return Color(0.13, 0.13, 0.13)
		_:
			return Color(0.5, 0.5, 0.5)

func get_category_color(category_name: String) -> Color:
	match category_name:
		"Food & Agriculture":
			return Color(0.3, 0.69, 0.31)
		"Raw Materials":
			return Color(0.62, 0.62, 0.62)
		"Manufactured Goods":
			return Color(0.13, 0.59, 0.95)
		"Technology":
			return Color(0.61, 0.15, 0.69)
		"Medical Supplies":
			return Color(0.96, 0.26, 0.21)
		"Luxury Goods":
			return Color(1.0, 0.84, 0.0)
		"Weapons & Ordnance":
			return Color(0.55, 0.0, 0.0)
		_:
			return Color(0.7, 0.7, 0.7)

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
	if game_db:
		game_db.close_db()
		print("Game database closed")
	if save_db:
		save_db.close_db()
		print("Save database closed")
