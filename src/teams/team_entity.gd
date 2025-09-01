extends Node

class_name TeamEntity

@export var team_id: int = -1  # Default to -1 indicating no team
var is_bot: bool = false

# Method to join a team
func join_team(team_id: int):
	self.team_id = team_id

# Method to leave the current team
func leave_team():
	self.team_id = -1

# Method to get current team information
func get_team_info() -> Dictionary:
	return {
		"name": name,
		"team_id": team_id,
		"is_bot": is_bot
	}
