# ui_system_list.gd
# Left column - System navigation controller

extends PanelContainer

@onready var sort_by_name_button: Button = $VBoxContainer/SystemListFilter/SortByNameButton
@onready var sort_by_distance_button: Button = $VBoxContainer/SystemListFilter/SortByDistanceButton
@onready var sort_by_type_button: Button = $VBoxContainer/SystemListFilter/SortByTypeButton
@onready var system_list_vbox: VBoxContainer = $VBoxContainer/SystemList/SystemListVbox

# Signals
signal system_selected(system_id: int)
signal travel_requested(destination_id: int, distance: int)

# State
var db_manager
var player_state: Dictionary = {}
var all_systems: Array = []
var system_connections: Dictionary = {}
var system_distances: Dictionary = {}
var current_system_id: int = 0
var selected_system_id: int = 0
var current_sort: String = "name"

# System button tracking
var system_buttons: Dictionary = {}

func _ready():
	# Connect sort buttons
	sort_by_name_button.toggled.connect(_on_sort_by_name)
	sort_by_distance_button.toggled.connect(_on_sort_by_distance)
	sort_by_type_button.toggled.connect(_on_sort_by_type)
	
	# Set default sort
	sort_by_name_button.button_pressed = true

func initialize(db_mgr, player_data: Dictionary):
	db_manager = db_mgr
	player_state = player_data
	current_system_id = player_state.get("current_system_id", 0)
	
	# Load data
	all_systems = db_manager.all_systems
	system_connections = db_manager.system_connections
	
	# Calculate distances
	_calculate_distances()
	
	# Build system list
	_rebuild_system_list()

func update_system_distances(player_data: Dictionary):
	player_state = player_data
	current_system_id = player_state.get("current_system_id", 0)
	_calculate_distances()
	_rebuild_system_list()

func _calculate_distances():
	system_distances.clear()
	
	# Current system has distance 0
	system_distances[current_system_id] = 0
	
	# Use BFS to find shortest paths
	var queue = [current_system_id]
	var visited = {current_system_id: 0}
	
	while queue.size() > 0:
		var current = queue.pop_front()
		var current_dist = visited[current]
		
		# Check all connections from current system
		if system_connections.has(current):
			for connection in system_connections[current]:
				var neighbor = connection["to_id"]
				var edge_dist = connection["distance"]
				var new_dist = current_dist + edge_dist
				
				# If we haven't visited this neighbor, or found a shorter path
				if not visited.has(neighbor) or new_dist < visited[neighbor]:
					visited[neighbor] = new_dist
					queue.append(neighbor)
	
	# Copy visited distances to system_distances
	system_distances = visited
	
	print("Calculated distances from system %d:" % current_system_id)
	print("Total reachable systems: %d" % system_distances.size())

func _get_distance_to_system(target_id: int) -> int:
	return system_distances.get(target_id, 999)

func _rebuild_system_list():
	# Clear existing buttons
	for child in system_list_vbox.get_children():
		child.queue_free()
	system_buttons.clear()
	
	# Sort systems
	var sorted_systems = all_systems.duplicate()
	match current_sort:
		"name":
			sorted_systems.sort_custom(_sort_by_name)
		"distance":
			sorted_systems.sort_custom(_sort_by_distance)
		"type":
			sorted_systems.sort_custom(_sort_by_type)
	
	# Create system buttons
	for system in sorted_systems:
		var sys_id = system["system_id"]
		var button = _create_system_button(system)
		system_list_vbox.add_child(button)
		system_buttons[sys_id] = button

func _create_system_button(system: Dictionary) -> Control:
	var sys_id = system["system_id"]
	var sys_name = system["system_name"]
	var planet_type = system["planet_type_name"]
	var distance = system_distances.get(sys_id, 999)
	
	# Create container
	var container = VBoxContainer.new()
	container.custom_minimum_size = Vector2(0, 80)
	
	# Create button
	var button = Button.new()
	button.custom_minimum_size = Vector2(0, 60)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	
	# Button text
	var button_text = sys_name + "\n"
	button_text += planet_type
	
	if sys_id == current_system_id:
		button_text += "\n[Current Location]"
		button.modulate = Color(1.2, 1.2, 0.8)  # Highlight current
	else:
		var fuel_cost = distance * player_state.get("base_fuel_cost", 25)
		button_text += "\n%d jumps (%s fuel)" % [distance, db_manager.format_credits(fuel_cost)]
	
	button.text = button_text
	
	# Color code by planet type
	var type_color = db_manager.get_planet_type_color(planet_type)
	var style = StyleBoxFlat.new()
	style.bg_color = type_color * 0.3  # Darker version
	style.border_color = type_color
	style.border_width_left = 4
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	button.add_theme_stylebox_override("normal", style)
	
	# Connect signals
	button.pressed.connect(_on_system_button_pressed.bind(sys_id))
	button.gui_input.connect(_on_system_button_input.bind(sys_id, distance))
	
	container.add_child(button)
	return container

func _on_system_button_pressed(sys_id: int):
	selected_system_id = sys_id
	system_selected.emit(sys_id)

func _on_system_button_input(event: InputEvent, sys_id: int, distance: int):
	if event is InputEventMouseButton:
		if event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
			if sys_id != current_system_id:
				travel_requested.emit(sys_id, distance)

# Sorting functions
func _sort_by_name(a, b):
	return a["system_name"] < b["system_name"]

func _sort_by_distance(a, b):
	var dist_a = system_distances.get(a["system_id"], 999)
	var dist_b = system_distances.get(b["system_id"], 999)
	if dist_a == dist_b:
		return a["system_name"] < b["system_name"]
	return dist_a < dist_b

func _sort_by_type(a, b):
	if a["planet_type_name"] == b["planet_type_name"]:
		return a["system_name"] < b["system_name"]
	return a["planet_type_name"] < b["planet_type_name"]

func _on_sort_by_name(toggled: bool):
	if toggled:
		current_sort = "name"
		sort_by_distance_button.button_pressed = false
		sort_by_type_button.button_pressed = false
		_rebuild_system_list()

func _on_sort_by_distance(toggled: bool):
	if toggled:
		current_sort = "distance"
		sort_by_name_button.button_pressed = false
		sort_by_type_button.button_pressed = false
		_rebuild_system_list()

func _on_sort_by_type(toggled: bool):
	if toggled:
		current_sort = "type"
		sort_by_name_button.button_pressed = false
		sort_by_distance_button.button_pressed = false
		_rebuild_system_list()
