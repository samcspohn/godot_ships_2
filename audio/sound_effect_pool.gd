extends Node
@export var explosion: AudioStream
@export var splash: AudioStream

var players: Dictionary
var free_players: Array[AudioStreamPlayer3D] = []

func play_explosion(pos: Vector3, pitch: float, vol: float):
	var player: AudioStreamPlayer3D = _get_free_player()
	player.stream = explosion
	player.unit_size = 1500.0
	player.pitch_scale = pitch * 3.0
	player.volume_linear = vol * 1.5
	player.transform.origin = pos
	player.play()
	players[player.get_instance_id()] = player

func play_splash(pos: Vector3, pitch: float, vol: float):
	var player: AudioStreamPlayer3D = _get_free_player()
	player.stream = splash
	player.unit_size = 800.0
	player.pitch_scale = pitch
	player.volume_linear = vol
	player.transform.origin = pos
	player.play()
	players[player.get_instance_id()] = player

func _get_free_player() -> AudioStreamPlayer3D:
	if free_players.size() > 0:
		return free_players.pop_back()

	var new_player = AudioStreamPlayer3D.new()
	add_child(new_player)
	new_player.finished.connect(func():
		free_players.append(new_player)
		players.erase(new_player.get_instance_id())
	)
	return new_player
