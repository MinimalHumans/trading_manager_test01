# database_manager.gd
# Handles all SQLite database operations for the trading prototype
# UPDATED: Added planet demand system and deterministic item selection

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
var planet_demand_categories: Dictionary = {}  # NEW: {planet_type_id: {category_id: demand_level}}

# Tunable balance variables (loaded from database)
var rarity_multiplier_rare: float = 1.25
var rarity_multiplier_exotic: float = 1.50
var universe_market_modifier_strength: float = 0.03
var connection_discount_amount: float = 0.10

# NEW: Item variety variables
var items_per_category_common: int = 3
var items_per_category_rare: int = 2
var items_per_category_exotic: int = 1
var items_per_category_common_trade_hub: int = 5
var items_per_category_rare_trade_hub: int = 3
var items_per_category_exotic_trade_hub: int = 2

# NEW: Demand multipliers
var demand_multipliers: Dictionary = {}

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
		"connection_discount_amount",
		"items_per_category_common",
		"items_per_category_rare",
		"items_per_category_exotic",
		"items_per_category_common_trade_hub",
		"items_per_category_rare_trade_hub",
		"items_per_category_exotic_trade_hub",
		"demand_multiplier_high",
		"demand_multiplier_medium",
		"demand_multiplier_low",
		"demand_multiplier_none"
	]
	
	for var_name in variables_to_load:
		var query = "SELECT variable_value FROM global_variables WHERE variable_name = '%s'" % var_name
		game_db.query(query)
		if game_db.query_result.size() > 0:
			var value = game_db.query_result[0]["variable_value"]
			match var_name:
				"rarity_multiplier_rare":
					rarity_multiplier_rare = value
				"rarity_multiplier_exotic":
					rarity_multiplier_exotic = value
				"universe_market_modifier_strength":
					universe_market_modifier_strength = value
				"connection_discount_amount":
					connection_discount_amount = value
				"items_per_category_common":
					items_per_category_common = int(value)
				"items_per_category_rare":
					items_per_category_rare = int(value)
				"items_per_category_exotic":
					items_per_category_exotic = int(value)
				"items_per_category_common_trade_hub":
					items_per_category_common_trade_hub = int(value)
				"items_per_category_rare_trade_hub":
					items_per_category_rare_trade_hub = int(value)
				"items_per_category_exotic_trade_hub":
					items_per_category_exotic_trade_hub = int(value)
				"demand_multiplier_high":
					demand_multipliers["HIGH"] = value
				"demand_multiplier_medium":
					demand_multipliers["MEDIUM"] = value
				"demand_multiplier_low":
					demand_multipliers["LOW"] = value
				"demand_multiplier_none":
					demand_multipliers["NONE"] = value
	
	print("Loaded tunable variables: Rare x%.2f, Exotic x%.2f, Market ±%.0f%%, Connection -%d%%" % [
		rarity_multiplier_rare, 
		rarity_multiplier_exotic,
		universe_market_modifier_strength * 5 * 100,
		connection_discount_amount * 100
	])
	print("Item variety: Common=%d, Rare=%d, Exotic=%d (Trade Hub: %d/%d/%d)" % [
		items_per_category_common,
		items_per_category_rare,
		items_per_category_exotic,
		items_per_category_common_trade_hub,
		items_per_category_rare_trade_hub,
		items_per_category_exotic_trade_hub
	])
	print("Demand multipliers: HIGH=%.0f%%, MEDIUM=%.0f%%, LOW=%.0f%%, NONE=%.0f%%" % [
		demand_multipliers["HIGH"] * 100,
		demand_multipliers["MEDIUM"] * 100,
		demand_multipliers["LOW"] * 100,
		demand_multipliers["NONE"] * 100
	])

# Cache frequently accessed data
func cache_static_data():
	all_items = get_all_items()
	all_systems = get_all_systems()
	all_categories = get_all_categories()
	system_connections = get_all_connections()
	category_relationships = get_category_relationships()
	market_events = get_all_market_events()
	planet_demand_categories = get_planet_demand_categories()
	
	# Emit ready signal
	database_ready.emit()

# ============================================================================
# NEW: PLANET DEMAND SYSTEM
# ============================================================================

func get_planet_demand_categories() -> Dictionary:
	"""Load planet demand relationships into memory"""
	var query = """
	SELECT planet_type_id, category_id, demand_level
	FROM planet_demand_categories
	"""
	
	game_db.query(query)
	
	var demand_map = {}
	for row in game_db.query_result:
		var planet_type_id = row["planet_type_id"]
		var category_id = row["category_id"]
		var demand_level = row["demand_level"]
		
		if not demand_map.has(planet_type_id):
			demand_map[planet_type_id] = {}
		
		demand_map[planet_type_id][category_id] = demand_level
	
	print("Loaded planet demand categories for %d planet types" % demand_map.size())
	return demand_map

func get_demand_level(planet_type_id: int, category_id: int) -> String:
	"""Get demand level for a category at a planet type. Returns 'HIGH', 'MEDIUM', 'LOW', or 'NONE'"""
	if planet_demand_categories.has(planet_type_id):
		if planet_demand_categories[planet_type_id].has(category_id):
			return planet_demand_categories[planet_type_id][category_id]
	return "NONE"

func does_planet_produce_category(planet_type_id: int, category_id: int) -> bool:
	"""Check if a planet type produces items in this category (has negative price modifier)"""
	var query = """
	SELECT price_modifier
	FROM planet_category_modifiers
	WHERE planet_type_id = %d AND category_id = %d AND price_modifier < 0
	""" % [planet_type_id, category_id]
	
	game_db.query(query)
	return game_db.query_result.size() > 0

func get_trade_hub_demand_multiplier(category_name: String, universe_market: Dictionary) -> float:
	"""Calculate dynamic demand multiplier for Trade Hubs based on universe market"""
	var market_value = universe_market.get(category_name, 5.0)
	
	# Above average market - they want to buy
	if market_value > 5.5:
		return 1.0
	# Average market
	elif market_value >= 4.5:
		return 0.9
	# Below average market - they're cautious
	else:
		return 0.8

# ============================================================================
# NEW: DETERMINISTIC ITEM SELECTION WITH SMART COUNTS
# ============================================================================

func get_item_count_for_category(planet_type_id: int, category_id: int) -> Dictionary:
	"""Determine how many items of each rarity to show based on planet's production and demand"""
	
	print("DEBUG: Checking item count for planet_type=%d, category=%d" % [planet_type_id, category_id])
	
	# Trade Hub special case - lots of everything
	if planet_type_id == 11:
		print("  -> Trade Hub: 5/3/2")
		return {
			"common": items_per_category_common_trade_hub,
			"rare": items_per_category_rare_trade_hub,
			"exotic": items_per_category_exotic_trade_hub
		}
	
	# Check if planet produces this category
	var produces = does_planet_produce_category(planet_type_id, category_id)
	print("  -> Produces: %s" % produces)
	
	# Check demand level
	var demand = get_demand_level(planet_type_id, category_id)
	print("  -> Demand: %s" % demand)
	
	# No demand AND doesn't produce = don't show at all
	if demand == "NONE" and not produces:
		print("  -> HIDING CATEGORY (no demand, doesn't produce)")
		return {"common": 0, "rare": 0, "exotic": 0}
	
	# Primary production category (they make this) - most variety
	if produces:
		print("  -> PRIMARY PRODUCTION: 3/3/2")
		return {"common": 3, "rare": 3, "exotic": 2}
	
	# High demand categories - good variety
	if demand == "HIGH":
		print("  -> HIGH DEMAND: 2/1/1")
		return {"common": 2, "rare": 1, "exotic": 1}
	
	# Medium demand - moderate variety
	if demand == "MEDIUM":
		print("  -> MEDIUM DEMAND: 2/1/1")
		return {"common": 1, "rare": 0, "exotic": 0}
	
	# Low demand - minimal variety
	if demand == "LOW":
		print("  -> LOW DEMAND: 1/1/0")
		return {"common": 0, "rare": 0, "exotic": 0}
	
	# Default fallback (shouldn't reach here)
	print("  -> FALLBACK: 1/0/0")
	return {"common": 0, "rare": 0, "exotic": 0}

func get_items_for_system(system_id: int, planet_type_id: int, category_id: int) -> Array:
	"""Get deterministic subset of items for a system. Same system always returns same items."""
	
	# Determine item counts based on planet's relationship to this category
	var item_counts = get_item_count_for_category(planet_type_id, category_id)
	var common_count = item_counts["common"]
	var rare_count = item_counts["rare"]
	var exotic_count = item_counts["exotic"]
	
	# If no items should be shown, return empty
	if common_count == 0 and rare_count == 0 and exotic_count == 0:
		return []
	
	# Get all items in this category
	var category_items = []
	for item in all_items:
		if item["category_id"] == category_id:
			category_items.append(item)
	
	# Separate by rarity AND SORT BY ID for consistency
	var common_items = []
	var rare_items = []
	var exotic_items = []
	
	for item in category_items:
		match item["rarity_name"]:
			"Common":
				common_items.append(item)
			"Rare":
				rare_items.append(item)
			"Exotic":
				exotic_items.append(item)
	
	# CRITICAL: Sort by item_id for consistent input to RNG
	common_items.sort_custom(func(a, b): return a["item_id"] < b["item_id"])
	rare_items.sort_custom(func(a, b): return a["item_id"] < b["item_id"])
	exotic_items.sort_custom(func(a, b): return a["item_id"] < b["item_id"])
	
	# Create deterministic seed
	var seed_value = hash(str(system_id) + "_" + str(category_id))
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	
	print("  -> System %d seed for category %d: %d" % [system_id, category_id, seed_value])
	
	# Select subsets using ONLY the seeded RNG
	var selected = []
	selected += _select_random_subset_deterministic(common_items, common_count, rng)
	selected += _select_random_subset_deterministic(rare_items, rare_count, rng)
	selected += _select_random_subset_deterministic(exotic_items, exotic_count, rng)
	
	print("  -> Selected %d items total" % selected.size())
	
	return selected

func _select_random_subset_deterministic(items: Array, count: int, rng: RandomNumberGenerator) -> Array:
	"""Select a random subset of items using ONLY the provided RNG - TRUE determinism"""
	if items.size() <= count:
		return items  # Return all if not enough
	
	var shuffled = items.duplicate()
	
	# Manual Fisher-Yates shuffle with seeded RNG
	# DO NOT use shuffled.shuffle() - it uses Godot's global RNG!
	for i in range(shuffled.size() - 1, 0, -1):
		var j = rng.randi_range(0, i)
		var temp = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = temp
	
	return shuffled.slice(0, count)

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
# QUERY FUNCTIONS - Market Data (COMPLETELY REWRITTEN)
# ============================================================================

func get_market_buy_items(system_id: int, market_type: String = "infinite", universe_market: Dictionary = {}, connected_discount: float = 0.10, market_modifier_per_point: float = 0.05) -> Array:
	"""Get items available for purchase at this system using deterministic selection"""
	print("\n=== BUILDING MARKET FOR SYSTEM %d ===" % system_id)
	
	var system_info = get_system_by_id(system_id)
	if system_info.is_empty():
		return []
	
	var planet_type_id = system_info["planet_type_id"]
	var planet_name = system_info.get("planet_type_name", "Unknown")
	print("Planet type: %s (ID: %d)" % [planet_name, planet_type_id])
	
	var base_items = []
	
	# Use deterministic selection - iterate through all categories
	for category in all_categories:
		var category_id = category["category_id"]
		var category_name = category["category_name"]
		
		print("\nProcessing category: %s (ID: %d)" % [category_name, category_id])
		
		# Get deterministic item selection for this system and category
		var selected_items = get_items_for_system(system_id, planet_type_id, category_id)
		
		# If no items selected for this category, skip it
		if selected_items.is_empty():
			print("  -> No items selected, skipping")
			continue
		
		print("  -> Building market entries for %d items" % selected_items.size())
		
		# Build market entries for selected items
		for item in selected_items:
			var item_id = item["item_id"]
			var item_name = item["item_name"]
			var base_price = item["base_price"]
			var rarity_name = item["rarity_name"]
			var price_multiplier = item["price_multiplier"]
			
			# Calculate base sell price (what player pays to buy)
			var sell_price = base_price * price_multiplier
			
			# Apply planet category modifier
			var planet_modifier_query = """
			SELECT price_modifier
			FROM planet_category_modifiers
			WHERE planet_type_id = %d AND category_id = %d
			""" % [planet_type_id, category_id]
			
			game_db.query(planet_modifier_query)
			if game_db.query_result.size() > 0:
				var planet_modifier = game_db.query_result[0]["price_modifier"]
				sell_price *= (1.0 + planet_modifier)
			
			# Apply universe market modifiers and connection discounts
			if not universe_market.is_empty():
				var nearby_categories = get_nearby_produced_categories(system_id)
				
				var market_value = universe_market.get(category_name, 5.0)
				var market_modifier = 1.0 + ((market_value - 5.0) * market_modifier_per_point)
				
				var connection_modifier = 1.0
				if nearby_categories.has(category_id):
					connection_modifier = 1.0 - connected_discount
				
				sell_price *= market_modifier * connection_modifier
			
			# Calculate price category for display
			var total_price_ratio = sell_price / base_price
			var price_category = "Average"
			if total_price_ratio <= 0.60:
				price_category = "Very Low"
			elif total_price_ratio <= 0.80:
				price_category = "Low"
			elif total_price_ratio <= 0.95:
				price_category = "Below Average"
			elif total_price_ratio <= 1.05:
				price_category = "Average"
			elif total_price_ratio <= 1.20:
				price_category = "Above Average"
			elif total_price_ratio <= 1.40:
				price_category = "High"
			else:
				price_category = "Very High"
			
			var market_item = {
				"item_id": item_id,
				"item_name": item_name,
				"category_id": category_id,
				"category_name": category_name,
				"rarity_name": rarity_name,
				"base_price": base_price,
				"sell_price": round(sell_price * 100.0) / 100.0,
				"price_category": price_category
			}
			
			# Add stock info for finite markets
			if market_type != "infinite":
				var stock = get_item_stock(system_id, item_id)
				var current_stock = stock.get("current_stock_tons", 0)
				var max_stock = stock.get("max_stock_tons", 0)
				
				# CRITICAL: Only show items that have been initialized (max_stock > 0)
				if max_stock == 0:
					print("    -> Skipping %s (not initialized in inventory)" % item_name)
					continue
				
				market_item["current_stock"] = current_stock
				market_item["max_stock"] = max_stock
			else:
				market_item["availability_percent"] = 1.0
			
			base_items.append(market_item)
	
	# Add player-sold items to the market (these appear even if not in deterministic list)
	var player_sold_items = get_player_sold_items_at_system(system_id)
	
	print("\nAdding %d player-sold items" % player_sold_items.size())
	
	for sold_item in player_sold_items:
		var item_id = sold_item["item_id"]
		
		# Check if item already in market
		var existing_index = -1
		for i in range(base_items.size()):
			if base_items[i]["item_id"] == item_id:
				existing_index = i
				break
		
		if existing_index >= 0:
			# Item already in market - add to stock
			if market_type != "infinite":
				var current_stock = base_items[existing_index].get("current_stock", 0)
				base_items[existing_index]["current_stock"] = current_stock + sold_item["quantity_tons"]
		else:
			# New item - add to market
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
	
	print("\n=== TOTAL MARKET ITEMS: %d ===" % base_items.size())
	return base_items

func get_market_sell_prices(system_id: int, universe_market: Dictionary = {}, connected_discount: float = 0.10, market_modifier_per_point: float = 0.05) -> Dictionary:
	"""Get what the system is willing to pay for items (COMPLETE OVERHAUL for demand system)"""
	var system_info = get_system_by_id(system_id)
	if system_info.is_empty():
		return {}
	
	var planet_type_id = system_info["planet_type_id"]
	var prices = {}
	
	# Get player inventory - we need to offer prices for EVERYTHING they have
	var player_inv = get_player_inventory()
	
	for inv_item in player_inv:
		var item_id = inv_item["item_id"]
		var item_name = inv_item.get("item_name", "Unknown")
		
		# Find this item's details
		var item_details = null
		for item in all_items:
			if item["item_id"] == item_id:
				item_details = item
				break
		
		if not item_details:
			continue
		
		var category_id = item_details["category_id"]
		var category_name = item_details["category_name"]
		var base_price = item_details["base_price"]
		var rarity_multiplier = item_details["price_multiplier"]
		
		# Calculate base market price (what player would pay to buy this)
		var base_market_price = base_price * rarity_multiplier
		
		# Apply planet category modifier
		var planet_modifier_query = """
		SELECT price_modifier
		FROM planet_category_modifiers
		WHERE planet_type_id = %d AND category_id = %d
		""" % [planet_type_id, category_id]
		
		game_db.query(planet_modifier_query)
		if game_db.query_result.size() > 0:
			var planet_modifier = game_db.query_result[0]["price_modifier"]
			base_market_price *= (1.0 + planet_modifier)
		
		# Apply universe market modifiers
		if not universe_market.is_empty():
			var market_value = universe_market.get(category_name, 5.0)
			var market_modifier = 1.0 + ((market_value - 5.0) * market_modifier_per_point)
			base_market_price *= market_modifier
			
			var nearby_categories = get_nearby_produced_categories(system_id)
			if nearby_categories.has(category_id):
				base_market_price *= (1.0 - connected_discount)
		
		# Now apply demand-based multipliers
		var produces_this = does_planet_produce_category(planet_type_id, category_id)
		var production_multiplier = 1.0
		
		# Get demand level (special case for Trade Hubs)
		var demand_multiplier = 1.0
		if planet_type_id == 7:  # Trade Hub
			demand_multiplier = get_trade_hub_demand_multiplier(category_name, universe_market)
		else:
			var demand_level = get_demand_level(planet_type_id, category_id)
			demand_multiplier = demand_multipliers.get(demand_level, 0.70)
		
		# Check same-market resale penalty
		var was_purchased_here = false
		var purchase_system_query = """
		SELECT purchase_system_id FROM player_inventory 
		WHERE player_id = 1 AND item_id = %d
		""" % item_id
		
		if save_db and save_db.query(purchase_system_query):
			if save_db.query_result.size() > 0:
				var purchase_system = save_db.query_result[0].get("purchase_system_id", null)
				was_purchased_here = (purchase_system == system_id)
		
		var resale_multiplier = 0.95 if was_purchased_here else 1.0
		
		# Calculate final sell price (what planet pays player)
		var final_price = base_market_price * production_multiplier * demand_multiplier * resale_multiplier
		
		# Determine price category
		var price_ratio = final_price / base_price
		var price_category = "Average"
		if price_ratio <= 0.70:
			price_category = "Very Low"
		elif price_ratio <= 0.85:
			price_category = "Low"
		elif price_ratio <= 0.95:
			price_category = "Below Average"
		elif price_ratio <= 1.05:
			price_category = "Average"
		elif price_ratio <= 1.20:
			price_category = "Above Average"
		elif price_ratio <= 1.40:
			price_category = "High"
		else:
			price_category = "Very High"
		
		# Determine demand indicator for UI
		var demand_indicator = ""
		if planet_type_id == 7:  # Trade Hub
			demand_indicator = "MARKET-BASED"
		else:
			var demand_level = get_demand_level(planet_type_id, category_id)
			demand_indicator = demand_level
		
		prices[item_id] = {
			"item_id": item_id,
			"item_name": item_name,
			"buy_price": round(final_price * 100.0) / 100.0,
			"price_category": price_category,
			"will_buy": 1,
			"resale_penalty": was_purchased_here,
			"produces_this": produces_this,
			"demand_level": demand_indicator,
			"demand_multiplier": demand_multiplier
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
	"""Initialize inventory using deterministic item selection"""
	if has_inventory_for_system(system_id):
		print("System %d already has inventory" % system_id)
		return
	
	var system_info = get_system_by_id(system_id)
	if system_info.is_empty():
		push_error("System not found: %d" % system_id)
		return
	
	# Get deterministic list of items for this system
	var market_items = get_market_buy_items(system_id, "infinite")
	
	if market_items.size() == 0:
		push_error("No market items found for system %d" % system_id)
		return
	
	print("\n=== INITIALIZING INVENTORY for system %d ===" % system_id)
	print("Creating inventory for %d items" % market_items.size())
	
	save_db.query("BEGIN TRANSACTION")
	
	for item in market_items:
		var item_id = item["item_id"]
		var item_name = item.get("item_name", "Unknown")
		var rarity = item.get("rarity_name", "Common")
		
		# Stock amounts based on rarity
		var max_stock = 100.0  # Default
		match rarity:
			"Common":
				max_stock = 150.0
			"Rare":
				max_stock = 75.0
			"Exotic":
				max_stock = 30.0
		
		var current_stock = max_stock  # Start at full stock
		
		var insert_query = """
		INSERT INTO system_inventory (system_id, item_id, current_stock_tons, max_stock_tons, last_updated_jump)
		VALUES (%d, %d, %f, %f, 0)
		""" % [system_id, item_id, current_stock, max_stock]
		
		if not save_db.query(insert_query):
			push_error("Failed to insert inventory for item %d (%s)" % [item_id, item_name])
		else:
			print("  Added %s: %.0f tons" % [item_name, max_stock])
	
	save_db.query("COMMIT")
	print("=== INVENTORY INITIALIZED ===\n")

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
			var update_inventory = """
			UPDATE player_inventory 
			SET quantity_tons = %f
			WHERE player_id = 1 AND item_id = %d
			""" % [new_qty, item_id]
			
			if not save_db.query(update_inventory):
				save_db.query("ROLLBACK")
				return false
	else:
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
