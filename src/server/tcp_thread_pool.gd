extends Node

const PORT = 4242

var server: TCPServer
var client: StreamPeerTCP
var threads = []  # list of ConnectionThread for server
var broadcast_queue = []  # Array[PackedByteArray] queue for messages to broadcast to all clients
var broadcast_mutex: Mutex = Mutex.new()
var client_queue: Array[PackedByteArray] = []  # queue for background thread to main thread
var client_queue_mutex: Mutex = Mutex.new()
var initialized = false
var client_ids: int = 0
var server_running: bool = false
var client_running: bool = false
var receive_thread: Thread

signal destroy_shell(data: PackedByteArray) # shell_id: int, pos: Vector3, hit_result: int
signal ricochet(data: PackedByteArray) # original_id: int, ricochet_id: int, position: Vector3, velocity: Vector3, time: float

var _wake_template: ParticleTemplate = preload("res://src/particles/templates/torpedo_wake_template.tres")
var _fallback_sound: AudioStream = preload("res://audio/explosion1.wav")

# --- Server-side gun type registry ---
# Maps gun.scene_file_path -> assigned u8 type ID.
# A one-time register_gun_type packet (type 3) is broadcast the first time
# each scene type fires, so the client can resolve it.
var _gun_type_id_map: Dictionary = {}  # String -> int
var _next_gun_type_id: int = 0

# --- Client-side gun type registry ---
# Maps u8 type ID -> a Gun node instantiated from the scene file but never
# added to the tree — used solely to read exported audio properties.
var _gun_type_cache: Dictionary = {}   # int -> Gun
# Tracks type IDs already requested to avoid flooding the server.
var _pending_gun_type_requests: Dictionary = {}  # int -> bool
# Sounds queued while waiting for a gun type registration to arrive.
# int -> Array[{pos, caliber, is_secondary}]
var _pending_sounds: Dictionary = {}


func _ready() -> void:
	var args = OS.get_cmdline_args()
	print("Scene tree:")
	print_scene_tree(get_tree().root)
	destroy_shell.connect(_on_destroy_shell)
	ricochet.connect(_on_ricochet)
	if "--server" in args:
		start_server()
	# else:
	# 	start_client()

func print_scene_tree(node: Node, indent: String = ""):
	print(indent + node.name + " (" + node.get_class() + ")")
	for child in node.get_children():
		print_scene_tree(child, indent + "  ")

func _on_destroy_shell(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	destroy_shell_client(shell_id, pos, hit_result, normal)

func _on_ricochet(_original_id: int, _ricochet_id: int, _position: Vector3, _velocity: Vector3, _time: float):
	pass

class ConnectionThread:
	var peer: StreamPeerTCP
	var queue: Array[PackedByteArray] = []
	var mutex: Mutex = Mutex.new()
	var thread: Thread
	var init: bool = false
	var id: int = -1
	var stop_requested: bool = false

	func _init(p: StreamPeerTCP):
		peer = p
		thread = Thread.new()
		thread.start(Callable(self, "_run"))
		init = false

	func _run():
		while not stop_requested and peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			mutex.lock()
			while queue.size() > 0:
				var bytes = queue.pop_front()
				peer.put_u32(bytes.size())
				peer.put_data(bytes)
			mutex.unlock()
			OS.delay_msec(1)
		print("Connection closed")
		mutex.lock()
		queue.clear()
		mutex.unlock()
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()

	func enqueue(data: PackedByteArray):
		if stop_requested:
			return
		mutex.lock()
		queue.append(data)
		mutex.unlock()

	func request_stop():
		stop_requested = true
		mutex.lock()
		queue.clear()
		mutex.unlock()
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()

func start_server():
	if server_running:
		print("Server already running")
		return
	server = TCPServer.new()
	var err = server.listen(PORT, "*")
	if err != OK:
		print("Failed to start server: ", err)
		return
	server_running = true
	print("Server listening on port ", PORT)

func _process(_delta: float) -> void:
	if server_running:
		if server.is_connection_available():
			var peer = server.take_connection()
			print("New connection from ", peer.get_connected_host())
			var conn_thread = ConnectionThread.new(peer)
			conn_thread.id = client_ids
			client_ids += 1
			threads.append(conn_thread)



	if client_running:
		_process_client_messages()

# Function to enqueue data to send to all clients (call this from server)
func enqueue_broadcast(data: PackedByteArray):
	for t in threads:
		t.enqueue(data)

# --- Server-side: gun type registration ---

# Returns the u8 type ID for the given gun's scene type, registering it on
# first use and broadcasting a type-3 packet to all current clients.
func _get_or_register_gun_type(gun: Gun) -> int:
	var path := gun.scene_file_path
	if _gun_type_id_map.has(path):
		return _gun_type_id_map[path]
	var type_id := _next_gun_type_id
	_next_gun_type_id += 1
	_gun_type_id_map[path] = type_id
	# Broadcast: type(u8) + type_id(u8) + path_len(u16) + path(utf8)
	var reg := StreamPeerBuffer.new()
	reg.put_u8(3)
	reg.put_u8(type_id)
	var path_bytes := path.to_utf8_buffer()
	reg.put_u16(path_bytes.size())
	reg.put_data(path_bytes)
	enqueue_broadcast(reg.data_array)
	return type_id

# Called by a client over RPC when it receives a display_shell for a gun type
# it has not yet registered. Responds directly to the requesting peer.
@rpc("any_peer", "reliable", "call_remote")
func request_gun_type(gun_type_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	for path in _gun_type_id_map:
		if _gun_type_id_map[path] == gun_type_id:
			receive_gun_type.rpc_id(peer_id, gun_type_id, path)
			return

# Called by the server on the requesting client with the scene path so it can
# instantiate the gun off-tree and cache its exported audio properties.
@rpc("authority", "reliable", "call_remote")
func receive_gun_type(gun_type_id: int, scene_path: String) -> void:
	var gun: Gun = null
	if not _gun_type_cache.has(gun_type_id) and ResourceLoader.exists(scene_path):
		var packed := ResourceLoader.load(scene_path) as PackedScene
		if packed != null:
			gun = packed.instantiate() as Gun
			if gun != null:
				_gun_type_cache[gun_type_id] = gun
	else:
		gun = _gun_type_cache.get(gun_type_id, null) as Gun
	_pending_gun_type_requests.erase(gun_type_id)
	# Drain any sounds that were queued while we were waiting for this type.
	if gun != null and _pending_sounds.has(gun_type_id):
		for entry in _pending_sounds[gun_type_id]:
			_play_shell_sound(entry.pos, entry.caliber, gun, entry.is_secondary)
		_pending_sounds.erase(gun_type_id)


# --- Server-side: send display shell ---
#
# Packet layout (type 0) — fixed 52 bytes after the type byte:
#   u32 shell_id
#   f32 pos.x, pos.y, pos.z      (12 bytes)
#   f32 vel.x, vel.y, vel.z      (12 bytes)
#   f64 time                     ( 8 bytes)
#   u8  shell_type               ( 1 byte )
#   f32 drag                     ( 4 bytes)
#   f32 size                     ( 4 bytes)
#   f32 caliber                  ( 4 bytes)
#   u8  flags (bit0=play_sound, bit1=is_secondary) ( 1 byte )
#   u8  gun_type_id                                ( 1 byte )
#                                            total  51 bytes payload
func send_display_shell(shell_id: int, position: Vector3, velocity: Vector3,
		time: float, shell_params: ShellParams, gun: Gun, play_sound: bool = true) -> void:
	var gun_type_id := _get_or_register_gun_type(gun)
	var stream := StreamPeerBuffer.new()
	stream.put_u8(0)  # type 0: display_shell
	stream.put_u32(shell_id)
	stream.put_float(position.x)
	stream.put_float(position.y)
	stream.put_float(position.z)
	stream.put_float(velocity.x)
	stream.put_float(velocity.y)
	stream.put_float(velocity.z)
	stream.put_double(time)
	stream.put_u8(int(shell_params.type))  # ShellType enum: 0=HE, 1=AP
	stream.put_float(shell_params.drag)
	stream.put_float(shell_params.size)
	stream.put_float(shell_params.caliber)
	var flags := (1 if play_sound else 0) | (2 if shell_params._secondary else 0)
	stream.put_u8(flags)
	stream.put_u8(gun_type_id)
	enqueue_broadcast(stream.data_array)

# Send despawn shell command as binary
func send_destroy_shell(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	var stream = StreamPeerBuffer.new()
	stream.put_u8(1)  # type 1: destroy shell
	stream.put_u32(shell_id)
	stream.put_float(pos.x)
	stream.put_float(pos.y)
	stream.put_float(pos.z)
	stream.put_u32(hit_result)
	stream.put_float(normal.x)
	stream.put_float(normal.y)
	stream.put_float(normal.z)
	enqueue_broadcast(stream.data_array)

func send_ricochet(original_id: int, ricochet_id: int, position: Vector3, velocity: Vector3, time: float):
	var stream = StreamPeerBuffer.new()
	stream.put_u8(2)  # type 2: ricochet
	stream.put_u32(original_id)
	stream.put_u32(ricochet_id)
	stream.put_float(position.x)
	stream.put_float(position.y)
	stream.put_float(position.z)
	stream.put_float(velocity.x)
	stream.put_float(velocity.y)
	stream.put_float(velocity.z)
	stream.put_double(time)
	enqueue_broadcast(stream.data_array)

### Client ###
func start_client():
	if client_running:
		print("Client already running")
		return
	client = StreamPeerTCP.new()
	var err = client.connect_to_host("127.0.0.1", PORT)
	if err != OK:
		print("Failed to connect: ", err)
		return
	print("Connecting to server...")
	while client.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		client.poll()
		OS.delay_msec(10)
	if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		print("Connected to server")
		client_running = true
		receive_thread = Thread.new()
		receive_thread.start(Callable(self, "_receive_loop"))
	else:
		print("Failed to connect")
		client_running = false
		client = null
		return

func _process_client_messages():
	if not client_running:
		return

	var pending: Array[PackedByteArray] = []
	client_queue_mutex.lock()
	while client_queue.size() > 0:
		pending.append(client_queue.pop_front())
	client_queue_mutex.unlock()

	for bytes in pending:
		var stream = StreamPeerBuffer.new()
		stream.data_array = bytes
		if stream.get_available_bytes() < 1:
			print("Corrupted data received")
			continue
		var type = stream.get_u8()
		if type == 0:
			# display_shell payload: 4+12+12+8+1+4+4+4+1+1 = 51 bytes
			if stream.get_available_bytes() < 51:
				print("Corrupted display shell data received")
				continue
			var shell_id    = stream.get_u32()
			var pos         = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var vel         = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var t           = stream.get_double()
			var shell_type  = stream.get_u8()
			var drag        = stream.get_float()
			var size        = stream.get_float()
			var caliber     = stream.get_float()
			var flags        = stream.get_u8()
			var play_sound   = (flags & 1) != 0
			var is_secondary = (flags & 2) != 0
			var gun_type_id  = stream.get_u8()
			display_shell_client(shell_id, pos, vel, t, shell_type, drag, size, caliber,
					gun_type_id, play_sound, is_secondary)
		elif type == 1:
			if stream.get_available_bytes() < 4 + 12 + 4 + 12:
				print("Corrupted destroy shell data received")
				continue
			var shell_id  = stream.get_u32()
			var pos       = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var hit_result = stream.get_u32()
			var normal    = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			destroy_shell_client(shell_id, pos, hit_result, normal)
		elif type == 2:
			if stream.get_available_bytes() < 4 + 4 + 12 + 12 + 8:
				print("Corrupted ricochet data received")
				continue
			var original_id = stream.get_u32()
			var ricochet_id = stream.get_u32()
			var position    = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var velocity    = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var time        = stream.get_double()
			ricochet_client(original_id, ricochet_id, position, velocity, time)
		elif type == 3:
			# register_gun_type: type_id(u8) + path_len(u16) + path(utf8)
			if stream.get_available_bytes() < 3:
				print("Corrupted register_gun_type data received")
				continue
			var gun_type_id = stream.get_u8()
			var path_len    = stream.get_u16()
			if stream.get_available_bytes() < path_len:
				print("Corrupted register_gun_type path received")
				continue
			var path_data  = stream.get_data(path_len)
			var scene_path: String = path_data[1].get_string_from_utf8()
			# Instantiate the gun scene off-tree so exported audio properties
			# (_sound, pitch, volume, variance) are available without _ready().
			if not _gun_type_cache.has(gun_type_id) and ResourceLoader.exists(scene_path):
				var packed := ResourceLoader.load(scene_path) as PackedScene
				if packed != null:
					var gun := packed.instantiate() as Gun
					if gun != null:
						_gun_type_cache[gun_type_id] = gun
						_pending_gun_type_requests.erase(gun_type_id)

	if client and client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_stop_client()

func _stop_client():
	client_running = false
	if receive_thread and receive_thread.is_alive():
		receive_thread.wait_to_finish()
		receive_thread = null
	if client and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		client.disconnect_from_host()
	client = null

func _receive_loop():
	while client_running and client and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		client.poll()
		while client.get_available_bytes() >= 4:
			var length = client.get_u32()
			while client.get_available_bytes() < length and client_running:
				OS.delay_msec(10)
			if not client_running:
				break
			var data = client.get_data(length)
			if data[0] == OK:
				client_queue_mutex.lock()
				client_queue.append(data[1])
				client_queue_mutex.unlock()
		OS.delay_msec(10)
	print("Disconnected from server")
	client_running = false

# Ask the server to send the type-3 registration for a gun type we missed.
# Uses a reliable RPC so no custom TCP plumbing is needed.
func _request_gun_type(gun_type_id: int) -> void:
	if _pending_gun_type_requests.has(gun_type_id):
		return
	_pending_gun_type_requests[gun_type_id] = true
	request_gun_type.rpc_id(1, gun_type_id)


# --- Client-side helpers ---

# Return the off-tree Gun instance for the given type ID, or null if the
# type-3 registration packet has not yet been received.
func _get_representative(gun_type_id: int) -> Gun:
	return _gun_type_cache.get(gun_type_id, null) as Gun

# --- Client-side handlers ---

func display_shell_client(shell_id: int, pos: Vector3, vel: Vector3, t: float,
		shell_type: int, drag: float, size: float, caliber: float,
		gun_type_id: int, play_sound: bool = true, is_secondary: bool = false) -> void:
	var gun := _get_representative(gun_type_id)
	if gun == null:
		_request_gun_type(gun_type_id)
		if play_sound:
			if not _pending_sounds.has(gun_type_id):
				_pending_sounds[gun_type_id] = []
			_pending_sounds[gun_type_id].append({
				"pos": pos, "caliber": caliber, "is_secondary": is_secondary
			})

	# Reconstruct a minimal ShellParams for fireBulletClient.
	var shell := ShellParams.new()
	shell.type = shell_type as ShellParams.ShellType
	shell.drag = drag
	shell.size = size
	shell.caliber = caliber
	shell._secondary = is_secondary

	# Derive a muzzle-blast orientation from the velocity vector.
	var forward := vel.normalized()
	var right := forward.cross(Vector3.UP)
	if right.length_squared() < 0.001:
		right = forward.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(forward).normalized()
	var vel_basis := Basis(right, up, -forward)

	ProjectileManager.fireBulletClient(pos, vel, t, shell_id, shell, null, true, vel_basis)

	if play_sound:
		_play_shell_sound(pos, caliber, gun, is_secondary)
	_emit_shell_wake(pos, vel, caliber)

# Play a positioned gun-fire sound using the audio settings exported on the
# representative gun's scene (stream, pitch, volume, variance, bus).
# Creates a short-lived AudioStreamPlayer3D at the muzzle position so that
# every shell has accurate 3D audio regardless of which instance fired it.
func _play_shell_sound(pos: Vector3, caliber: float, gun: Gun, is_secondary: bool) -> void:
	if gun == null:
		return
	if get_viewport() == null:
		return
	var listener := get_viewport().get_audio_listener_3d()
	if listener == null:
		return
	if listener.global_position.distance_to(pos) > gun.volume * 2000.0:
		return

	var stream: AudioStream = gun._sound if gun._sound != null else _fallback_sound

	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.max_polyphony = 4
	player.unit_size = 100.0 * sqrt(caliber / 100.0) + 100.0
	player.max_db = linear_to_db(gun.volume * (1.0 + gun.variance))
	player.pitch_scale = gun.pitch * randf_range(1.0 - gun.variance, 1.0 + gun.variance)
	player.volume_db = linear_to_db(gun.volume * randf_range(1.0 - gun.variance, 1.0 + gun.variance))
	player.bus = "Sec" if is_secondary else "Main"
	add_child(player)
	player.global_position = pos
	player.play()
	player.finished.connect(player.queue_free)

func _emit_shell_wake(pos: Vector3, vel: Vector3, caliber: float) -> void:
	if _wake_template == null:
		return
	var size := (caliber / 100.0) ** 2 * 2.0
	var dir := vel
	dir.y = 0.0
	var wake_pos := pos
	wake_pos.y = 0.01
	if dir.length_squared() > 0.001:
		wake_pos += dir.normalized() * size * 0.5
	var time_mod: float = lerp(3.0, 1.2, size / 50.0)
	_wake_template.emit(wake_pos, dir, size, 1, time_mod)

func destroy_shell_client(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	if shell_id == -1:
		print("No shell ID in data")
		return
	ProjectileManager.destroyBulletRpc2(shell_id, pos, hit_result, normal)

func ricochet_client(original_id: int, ricochet_id: int, position: Vector3, velocity: Vector3, time: float):
	ProjectileManager.createRicochetRpc(original_id, ricochet_id, position, velocity, time)

func display_tree(node: Node, indent: String = "") -> void:
	print(indent, node.name, " (", node.get_class(), ")")
	for child in node.get_children():
		display_tree(child, indent + "  ")

func _exit_tree() -> void:
	for gun in _gun_type_cache.values():
		if is_instance_valid(gun):
			gun.free()
	_gun_type_cache.clear()
	server_running = false
	if server:
		server.stop()
		server = null
	broadcast_mutex.lock()
	broadcast_queue.clear()
	broadcast_mutex.unlock()
	for t in threads:
		t.request_stop()
	for t in threads:
		if t.thread.is_alive():
			t.thread.wait_to_finish()
	threads.clear()
	if client:
		client_running = false
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.disconnect_from_host()
		client = null
	if receive_thread and receive_thread.is_alive():
		receive_thread.wait_to_finish()
	receive_thread = null
	client_queue_mutex.lock()
	client_queue.clear()
	client_queue_mutex.unlock()
