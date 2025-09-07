extends Node

class_name TeamEntity

@export var team_id: int = -1  # Default to -1 indicating no team
var is_bot: bool = false

# Method to get current team information
func get_team_info() -> Dictionary:
	return {
		"name": name,
		"team_id": team_id,
		"is_bot": is_bot
	}
