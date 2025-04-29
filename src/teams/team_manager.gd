extends Node

class_name TeamManager

var teams = {}
var team_count = 0

func create_team(team_id: int) -> void:
    if not teams.has(team_id):
        teams[team_id] = {}
        team_count += 1

func assign_player_to_team(player: Node, team_id: int, port: String) -> void:
    if teams.has(team_id):
        teams[team_id][port] = player

func remove_player_from_team(player: Node, team_id: int) -> void:
    if teams.has(team_id):
        teams[team_id].erase(player)

func get_team_members(team_id: int) -> Array:
    if teams.has(team_id):
        return teams[team_id]
    return []

func get_all_teams() -> Dictionary:
    return teams

func get_team_count() -> int:
    return team_count