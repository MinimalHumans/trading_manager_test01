# ui_new_game.gd
# New game setup screen controller

extends Panel

@onready var starting_credits_input: SpinBox = $VBoxContainer/GridContainer/StartingCreditsInput
@onready var cargo_capacity_input: SpinBox = $VBoxContainer/GridContainer/CargoCapacityInput
@onready var fuel_cost_input: SpinBox = $VBoxContainer/GridContainer/FuelCostInput
@onready var win_goal_input: SpinBox = $VBoxContainer/GridContainer/WinGoalInput
@onready var start_system_dropdown: OptionButton = $VBoxContainer/GridContainer/StartSystemDropdown
@onready var market_type_dropdown: OptionButton = $VBoxContainer/GridContainer/MarketTypeDropdown
@onready var new_game_button: Button = $VBoxContainer/NewGameButton

# Signal emitted when starting a new game
signal start_game(config: Dictionary)

# Available systems for dropdown
var available_systems: Array = []

func _ready():
	# Connect button
	new_game_button.pressed.connect(_on_new_game_pressed)
	
	# Populate dropdowns
	await get_tree().process_frame  # Wait for database to initialize
	_populate_system_dropdown()
	_populate_market_type_dropdown()

func _populate_system_dropdown():
	var db_manager = get_node("/root/Main/GameManager/DatabaseManager")
	if not db_manager:
		push_error("DatabaseManager not found!")
		return
	
	available_systems = db_manager.get_all_systems()
	
	# Clear existing items
	start_system_dropdown.clear()
	
	# Add "Random" option
	start_system_dropdown.add_item("Random", -1)
	start_system_dropdown.set_item_metadata(0, -1)
	
	# Add all systems
	for i in range(available_systems.size()):
		var system = available_systems[i]
		var display_text = "%s (%s)" % [system["system_name"], system["planet_type_name"]]
		start_system_dropdown.add_item(display_text, system["system_id"])
		start_system_dropdown.set_item_metadata(i + 1, system["system_id"])
	
	# Set default to Random
	start_system_dropdown.select(0)

func _populate_market_type_dropdown():
	market_type_dropdown.clear()
	market_type_dropdown.add_item("Infinite Supply", 0)
	market_type_dropdown.add_item("Finite-Instant Regen", 1)
	market_type_dropdown.add_item("Finite-Turn Based", 2)
	
	# Set default to Infinite Supply
	market_type_dropdown.select(0)

func _on_new_game_pressed():
	# Get selected system
	var selected_system_id = start_system_dropdown.get_selected_metadata()
	
	# If Random, pick a random system
	if selected_system_id == -1:
		var random_index = randi() % available_systems.size()
		selected_system_id = available_systems[random_index]["system_id"]
		print("Random system selected: %d" % selected_system_id)
	
	# Get market type
	var market_type_names = ["infinite", "finite_instant", "finite_turn"]
	var selected_index = market_type_dropdown.get_selected_id()
	var market_type = market_type_names[selected_index]
	
	print("Market type dropdown selected index: %d" % selected_index)
	print("Market type string: %s" % market_type)
	
	# Build config dictionary
	var config = {
		"starting_credits": starting_credits_input.value,
		"cargo_capacity": int(cargo_capacity_input.value),
		"base_fuel_cost": fuel_cost_input.value,
		"win_goal": win_goal_input.value,
		"starting_system": selected_system_id,
		"market_type": market_type
	}
	
	print("Config being sent: ", config)
	
	# Emit signal
	start_game.emit(config)

# Allow resetting to defaults
func reset_to_defaults():
	starting_credits_input.value = 2000
	cargo_capacity_input.value = 50
	fuel_cost_input.value = 25
	win_goal_input.value = 25000
	start_system_dropdown.select(0)
	market_type_dropdown.select(0)
