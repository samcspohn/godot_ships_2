extends Node

const PORT = 4242

var server: TCPServer
var client: StreamPeerTCP
var threads = []  # list of ConnectionThread for server
var broadcast_queue = []  # Array[PackedByteArray] queue for messages to broadcast to all clients
var broadcast_mutex: Mutex = Mutex.new()
var client_queue: Array[PackedByteArray] = []  # queue for background thread to main thread
var client_queue_mutex: Mutex = Mutex.new()
var guns = []
var gun_paths = []
var null_guns = []
var initialized = false
var client_ids: int = 0
var server_running: bool = false
var client_running: bool = false
var receive_thread: Thread

signal fire_gun(data: PackedByteArray) # gun_id: int, v: Vector3, p: Vector3, t: float, i: int
signal destroy_shell(data: PackedByteArray) # shell_id: int, pos: Vector3, hit_result: int
signal ricochet(data: PackedByteArray) # original_id: int, ricochet_id: int, position: Vector3, velocity: Vector3, time: float

# @rpc("authority", "reliable", "call_remote")

func initialize_guns(_gun_paths: Array[String]) -> void:
	guns.clear()
	gun_paths = _gun_paths
	var i = 0
	for path in gun_paths:
		var gun = get_node_or_null(path) as Gun
		guns.append(gun)
		if gun == null:
			null_guns.append(i)
			print("Failed to find gun at path: ", path)
		i += 1


func _ready() -> void:
	var args = OS.get_cmdline_args()
	print("Scene tree:")
	print_scene_tree(get_tree().root)
	fire_gun.connect(_on_fire_gun)
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

func _on_fire_gun(gun_id: int, v: Vector3, p: Vector3, t: float, i: int):
	fire_gun_client(gun_id, v, p, t, i)

func _on_destroy_shell(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	destroy_shell_client(shell_id, pos, hit_result, normal)

func _on_ricochet(_original_id: int, _ricochet_id: int, _position: Vector3, _velocity: Vector3, _time: float):
	# Handle ricochet event
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
			# Process send queue
			mutex.lock()
			while queue.size() > 0:
				var bytes = queue.pop_front()
				peer.put_u32(bytes.size())
				peer.put_data(bytes)
			mutex.unlock()
			OS.delay_msec(1)
		# Clean up when disconnected
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

func _process(delta: float) -> void:
	if server_running:
		if server.is_connection_available():
			var peer = server.take_connection()
			print("New connection from ", peer.get_connected_host())
			var conn_thread = ConnectionThread.new(peer)
			conn_thread.id = client_ids
			client_ids += 1
			threads.append(conn_thread)

	if client_running:
		# Process pending messages from the receive thread
		_process_client_messages()

		if null_guns.size() > 0:
			for i in null_guns:
				var path = gun_paths[i]
				var gun = get_node_or_null(path) as Gun
				if gun != null:
					guns[i] = gun
					null_guns.erase(i)

# Function to enqueue data to send to all clients (call this from server)
func enqueue_broadcast(data: PackedByteArray):
	# broadcast_mutex.lock()
	# broadcast_queue.append(data)
	# broadcast_mutex.unlock()
	for t in threads:
		t.enqueue(data)

# Send gun fire command as binary
func send_fire_gun(gun_id: int, velocity: Vector3, position: Vector3, time: float, id: int):
	var stream = StreamPeerBuffer.new()
	stream.put_u8(0)  # type 0 for fire gun
	stream.put_u32(gun_id)
	stream.put_float(velocity.x)
	stream.put_float(velocity.y)
	stream.put_float(velocity.z)
	stream.put_float(position.x)
	stream.put_float(position.y)
	stream.put_float(position.z)
	stream.put_double(time)
	stream.put_u32(id)
	enqueue_broadcast(stream.data_array)

# Send despawn shell command as binary
func send_destroy_shell(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	var stream = StreamPeerBuffer.new()
	stream.put_u8(1)  # type 1 for destroy shell
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
	stream.put_u8(2)  # type 2 for ricochet
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
	# Process pending messages from the receive thread (called from _process)
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
			continue  # corrupted
		var type = stream.get_u8()
		if type == 0:
			if stream.get_available_bytes() < 4 + 12 + 12 + 8 + 4:  # 40 bytes
				print("Corrupted fire gun data received")
				continue
			var gun_id = stream.get_u32()
			var v = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var p = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var t = stream.get_double()
			var i = stream.get_u32()
			fire_gun_client(gun_id, v, p, t, i)
		elif type == 1:
			if stream.get_available_bytes() < 4 + 12 + 4 + 12:  # 32 bytes
				print("Corrupted destroy shell data received")
				continue
			var shell_id = stream.get_u32()
			var pos = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var hit_result = stream.get_u32()
			var normal = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			destroy_shell_client(shell_id, pos, hit_result, normal)
		elif type == 2:
			if stream.get_available_bytes() < 4 + 4 + 12 + 12 + 8:  # 44 bytes
				print("Corrupted ricochet data received")
				continue
			var original_id = stream.get_u32()
			var ricochet_id = stream.get_u32()
			var position = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var velocity = Vector3(stream.get_float(), stream.get_float(), stream.get_float())
			var time = stream.get_double()
			ricochet_client(original_id, ricochet_id, position, velocity, time)

	# Check for disconnection
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

func destroy_shell_client(shell_id: int, pos: Vector3, hit_result: int, normal: Vector3):
	if shell_id == -1:
		print("No shell ID in data")
		return
	# Find the shell by ID and destroy it
	ProjectileManager.destroyBulletRpc2(shell_id, pos, hit_result, normal)

func fire_gun_client(gun_id: int, v: Vector3, p: Vector3, t: float, i: int):
	# print("Firing gun with data: ", gun_id, v, p, t, i)
	if gun_id == -1:
		print("No gun ID in data")
		return
	if gun_id >= guns.size():
		print("Gun ID out of range: ", gun_id)
		return
	var gun = guns[gun_id] as Gun
	if gun == null:
		print("Gun not found for ID: ", gun_id)
		return
	# fire_client(vel, pose, t, id)
	gun.fire_client(v, p, t, i)

func ricochet_client(original_id: int, ricochet_id: int, position: Vector3, velocity: Vector3, time: float):

	ProjectileManager.createRicochetRpc(original_id, ricochet_id, position, velocity, time)

func display_tree(node: Node, indent: String = "") -> void:
	print(indent, node.name, " (", node.get_class(), ")")
	for child in node.get_children():
		display_tree(child, indent + "  ")



func _exit_tree() -> void:
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
		if t.thread.is_active():
			t.thread.wait_to_finish()
	threads.clear()
	if client:
		client_running = false
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.disconnect_from_host()
		client = null
	if receive_thread and receive_thread.is_active():
		receive_thread.wait_to_finish()
	receive_thread = null
	client_queue_mutex.lock()
	client_queue.clear()
	client_queue_mutex.unlock()
