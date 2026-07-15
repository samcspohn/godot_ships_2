extends Node
@export var explosion: AudioStream
@export var splash: AudioStream

var players: Dictionary
var player_started_at: Dictionary
var free_players: Array[AudioStreamPlayer3D] = []

func play_explosion(pos: Vector3, pitch: float, vol: float):
	var player: AudioStreamPlayer3D = _get_free_player()
	player.stream = explosion
	player.unit_size = 1500.0
	player.pitch_scale = pitch * 3.0
	player.volume_linear = vol * 1.5
	player.transform.origin = pos
	player.play()
	var player_id := player.get_instance_id()
	players[player_id] = player
	player_started_at[player_id] = Time.get_ticks_usec()

func play_splash(pos: Vector3, pitch: float, vol: float):
	var player: AudioStreamPlayer3D = _get_free_player()
	player.stream = splash
	player.unit_size = 800.0
	player.pitch_scale = pitch
	player.volume_linear = vol
	player.transform.origin = pos
	player.play()
	var player_id := player.get_instance_id()
	players[player_id] = player
	player_started_at[player_id] = Time.get_ticks_usec()

func _get_free_player() -> AudioStreamPlayer3D:
	if free_players.size() > 0:
		return free_players.pop_back()

	if get_children().size() >= 64:
		var oldest_player_id: int = player_started_at.keys()[0]
		var oldest_started_at: int = player_started_at[oldest_player_id]
		for player_id: int in player_started_at:
			var started_at: int = player_started_at[player_id]
			if started_at < oldest_started_at:
				oldest_player_id = player_id
				oldest_started_at = started_at
		var oldest_player: AudioStreamPlayer3D = players[oldest_player_id]
		players.erase(oldest_player_id)
		player_started_at.erase(oldest_player_id)
		oldest_player.stop()
		return oldest_player

	var new_player = AudioStreamPlayer3D.new()
	add_child(new_player)
	new_player.finished.connect(func():
		free_players.append(new_player)
		var player_id := new_player.get_instance_id()
		players.erase(player_id)
		player_started_at.erase(player_id)
	)
	return new_player
