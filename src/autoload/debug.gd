# src/autoload/debug.gd
# Immediate-mode debug drawing system — binary-packed edition.
#
# SERVER SIDE: Bot systems call draw_* helpers during _physics_process.
#   if Debug.follow_ship == self:
#       Debug.draw_arrow(pos, dir, 200.0, Color.GREEN)
#       Debug.draw_circle(pos, radius, Color.CYAN)
#   Commands are appended as raw floats into per-type PackedByteArrays
#   and flushed to the client at the end of each physics frame via a
#   single RPC carrying Dictionary[int, PackedByteArray].
#
# CLIENT SIDE: A retained mesh pool renders the commands. Meshes are keyed
#   by "type:index" so that adding/removing commands of one type never
#   invalidates meshes of another type. Meshes are only reconstructed when
#   the construction key changes.
extends Node
class_name _Debug

# ============================================================================
# Draw command types
# ============================================================================
enum DrawType {
	ARROW,    # 0
	SPHERE,   # 1
	CIRCLE,   # 2
	LINE,     # 3
	PATH,     # 4
	SQUARE,   # 5
	LABEL,    # 6
	CONE,     # 7
}

# Byte stride per command (fixed-size types only).
# ARROW:  pos(3) + dir(3) + length(1) + radius(1) + color(4) = 12 floats = 48 bytes
# SPHERE: pos(3) + radius(1) + color(4) = 8 floats = 32 bytes
# CIRCLE: pos(3) + radius(1) + color(4) + segments(1 int packed as float) = 9 floats = 36 bytes
# LINE:   from(3) + to(3) + color(4) = 10 floats = 40 bytes
# PATH:   variable — header: color(4) + sphere_interval(1) + sphere_radius(1) + point_count(1) = 7 floats, then point_count * 3 floats
# SQUARE: pos(3) + width(1) + height(1) + color(4) + filled(1 as float) = 10 floats = 40 bytes
# LABEL:  variable — pos(3) + color(4) + font_size(1) + text_byte_count(1i) = 36 bytes header, then text bytes (padded to 4)
# CONE:   pos(3) + rot(3) + cone_height(1) + top_radius(1) + bottom_radius(1) + color(4) + radial_segments(1) = 14 floats = 56 bytes

const STRIDE_ARROW  := 48  # 12 floats
const STRIDE_SPHERE := 32  #  8 floats
const STRIDE_CIRCLE := 36  #  9 floats
const STRIDE_LINE   := 40  # 10 floats
const STRIDE_SQUARE := 40  # 10 floats
const STRIDE_CONE   := 56  # 14 floats
# PATH and LABEL are variable-length

# ============================================================================
# Server-side state
# ============================================================================

# The ship the client is spectating. Set via RPC from the client.
var follow_ship: Ship = null

# Per-type byte buffers: Dictionary[int, PackedByteArray]
# IMPORTANT: PackedByteArray is a value type (copy-on-write) in GDScript.
# We must NEVER extract it into a local var and mutate the local — the
# dictionary entry would remain unchanged. All writes go through the
# _buf_* helpers which index into _draw_buffers directly.
var _draw_buffers: Dictionary = {}

# Which peer is following (server tracks this for RPC target).
var _follower_peer_id: int = 0

# ============================================================================
# Client-side state
# ============================================================================

# Reference to the player's camera (set by BattleCamera).
var battle_camera: BattleCamera = null

# Mesh pool keyed by "type:index_within_type" → Node3D.
# This means adding/removing squares won't invalidate arrow meshes, etc.
var _mesh_pool: Dictionary = {}  # String → Node3D

# Cached construction keys per pool slot. Same key space as _mesh_pool.
var _mesh_keys: Dictionary = {}  # String → String

# Set of pool keys that are active this frame. Used to cull stale meshes.
var _active_keys: Dictionary = {}  # String → true

# The most recently received packed buffers from the server.
# Dictionary[int, PackedByteArray]
var _client_buffers: Dictionary = {}

# Per-type decoded command arrays. Dictionary[int, Array[Array]].
# Each inner Array is a lightweight tuple like [pos, dir, length, radius, color].
# The draw type is implicit from which bucket it's in.
var _client_type_commands: Dictionary = {}

# Whether we are currently following a non-player ship (client-side flag).
var _following: bool = false

# Set after reconnect so the next set_follow_ship() re-sends the RPC
# even if the followed ship hasn't changed.
var _needs_reregister: bool = false

# Tracks whether we were connected last frame so we can detect
# disconnect → reconnect transitions without relying on signals.
var _was_connected: bool = false

# ============================================================================
# Standalone draw helpers (fire-and-forget, timer-based lifetime)
# These are the legacy helpers used by bot_controller.gd etc.
# They are NOT part of the new immediate-mode pipeline.
# ============================================================================

## Draw a debug sphere at a global location. Can be called from anywhere.
func draw_sphere(location: Vector3, size: float = 10.0, color: Color = Color(1, 0, 0), duration: float = 3.0) -> void:
	_create_oneshot_sphere(location, size, color, duration)

## Static-style helper for drawing debug spheres from other scripts.
static func sphere(location: Vector3, size: float = 10.0, color: Color = Color(1, 0, 0), duration: float = 3.0) -> void:
	var debug_node = Engine.get_main_loop().root.get_node_or_null("/root/Debug")
	if debug_node:
		debug_node.draw_sphere(location, size, color, duration)

func _create_oneshot_sphere(location: Vector3, size: float, color: Color, duration: float) -> void:
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radial_segments = 4
	sphere_mesh.rings = 4
	sphere_mesh.radius = size
	sphere_mesh.height = size * 2

	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_mesh.surface_set_material(0, material)

	var node = MeshInstance3D.new()
	node.mesh = sphere_mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var t = Timer.new()
	t.wait_time = duration
	t.timeout.connect(func(): node.queue_free())
	t.autostart = true
	node.add_child(t)

	get_tree().root.add_child(node)
	node.global_transform.origin = location

func draw_circle_3d(center: Vector3, radius: float, orientation: Vector3 = Vector3.ZERO, color: Color = Color(0, 1, 0), line_width: float = 3.0, duration: float = 3.0) -> void:
	var node := _create_oneshot_circle_mesh(radius, color, line_width)
	node.global_position = center
	node.rotation = orientation
	_attach_oneshot_lifetime(node, duration)
	get_tree().root.add_child(node)

func draw_square_3d(center: Vector3, width: float, height: float, orientation: Vector3 = Vector3.ZERO, color: Color = Color(1, 1, 0), duration: float = 3.0, filled: bool = true) -> void:
	var node: MeshInstance3D
	if filled:
		node = _create_oneshot_filled_square(width, height, color)
	else:
		node = _create_oneshot_outline_square(width, height, color)
	node.global_position = center
	node.rotation = orientation
	_attach_oneshot_lifetime(node, duration)
	get_tree().root.add_child(node)

# ============================================================================
# Lifecycle
# ============================================================================

func _ready() -> void:
	set_process(true)
	set_physics_process(true)

var _signals_connected: bool = false

func _process(_delta: float) -> void:
	if not multiplayer.is_server():
		if not _signals_connected:
			_signals_connected = true
			multiplayer.server_disconnected.connect(_on_server_disconnected)
			multiplayer.connected_to_server.connect(_on_reconnected_to_server)

		_poll_connection_state()
		_update_mesh_pool()

func _physics_process(_delta: float) -> void:
	if multiplayer.is_server():
		_server_flush()

# ============================================================================
# Camera / follow registration (called by BattleCamera)
# ============================================================================

func register_camera(camera: BattleCamera) -> void:
	battle_camera = camera

## Called by BattleCamera each frame to update which ship we're following.
func set_follow_ship(ship: Ship, player_ship: Ship) -> void:
	if ship != null and ship != player_ship:
		if follow_ship != ship or _needs_reregister:
			follow_ship = ship
			_following = true
			_needs_reregister = false
			_set_server_follow.rpc_id(1, ship.get_path())
	else:
		if _following:
			_following = false
			follow_ship = null
			_set_server_follow.rpc_id(1, NodePath(""))
			_client_type_commands.clear()
			_client_buffers.clear()
			_clear_mesh_pool()

# ============================================================================
# Server: follow ship RPC
# ============================================================================

@rpc("any_peer", "call_remote", "reliable")
func _set_server_follow(ship_path: NodePath) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	_follower_peer_id = sender_id
	if ship_path == NodePath(""):
		follow_ship = null
		_clear_buffers()
		print("[Debug] Peer %d cleared follow ship" % sender_id)
		return
	var node = get_node_or_null(ship_path)
	if node is Ship:
		follow_ship = node as Ship
		print("[Debug] Peer %d now following %s" % [sender_id, node.name])
	else:
		follow_ship = null

# ============================================================================
# Client: disconnect / reconnect handlers
# ============================================================================

func _on_server_disconnected() -> void:
	_handle_disconnect()

func _on_reconnected_to_server() -> void:
	_handle_reconnect()

func _poll_connection_state() -> void:
	var peer = multiplayer.multiplayer_peer
	var connected_now: bool = (
		peer != null
		and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	)
	if _was_connected and not connected_now:
		_handle_disconnect()
	elif not _was_connected and connected_now:
		_handle_reconnect()
	_was_connected = connected_now

func _handle_disconnect() -> void:
	if not _needs_reregister:
		print("[Debug] Client disconnected — clearing mesh pool, will re-register on reconnect")
	_client_type_commands.clear()
	_client_buffers.clear()
	_clear_mesh_pool()
	_needs_reregister = true
	_was_connected = false

func _handle_reconnect() -> void:
	print("[Debug] Client reconnected — will re-register follow ship with new peer ID")
	_needs_reregister = true
	_was_connected = true

# ============================================================================
# Server: buffer management helpers
# ============================================================================

func _ensure_buffer(draw_type: int) -> void:
	if not _draw_buffers.has(draw_type):
		_draw_buffers[draw_type] = PackedByteArray()

func _clear_buffers() -> void:
	for key in _draw_buffers:
		var buf: PackedByteArray = _draw_buffers[key]
		buf.resize(0)
		_draw_buffers[key] = buf

## Append a float to the buffer for draw_type (avoids CoW detach).
func _buf_f32(draw_type: int, value: float) -> void:
	var buf: PackedByteArray = _draw_buffers[draw_type]
	var idx := buf.size()
	buf.resize(idx + 4)
	buf.encode_float(idx, value)
	_draw_buffers[draw_type] = buf

## Append an int32 to the buffer for draw_type.
func _buf_i32(draw_type: int, value: int) -> void:
	var buf: PackedByteArray = _draw_buffers[draw_type]
	var idx := buf.size()
	buf.resize(idx + 4)
	buf.encode_s32(idx, value)
	_draw_buffers[draw_type] = buf

## Append Vector3 (3 floats) to buffer for draw_type.
func _buf_vec3(draw_type: int, v: Vector3) -> void:
	_buf_f32(draw_type, v.x)
	_buf_f32(draw_type, v.y)
	_buf_f32(draw_type, v.z)

## Append Color (4 floats: r, g, b, a) to buffer for draw_type.
func _buf_color(draw_type: int, c: Color) -> void:
	_buf_f32(draw_type, c.r)
	_buf_f32(draw_type, c.g)
	_buf_f32(draw_type, c.b)
	_buf_f32(draw_type, c.a)

## Append raw bytes to the buffer for draw_type.
func _buf_bytes(draw_type: int, data: PackedByteArray) -> void:
	var buf: PackedByteArray = _draw_buffers[draw_type]
	buf.append_array(data)
	_draw_buffers[draw_type] = buf

## Append a single zero byte to the buffer for draw_type.
func _buf_pad(draw_type: int) -> void:
	var buf: PackedByteArray = _draw_buffers[draw_type]
	buf.append(0)
	_draw_buffers[draw_type] = buf

# ============================================================================
# Server: immediate-mode draw API
#
# Call these from any system during _physics_process. They only record
# commands when follow_ship is set; nothing is drawn on the server.
# ============================================================================

## Arrow (cone pointing in direction) at position.
## Layout: pos(3f) + dir(3f) + length(1f) + radius(1f) + color(4f) = 12 floats = 48 bytes
func draw_arrow(position: Vector3, direction: Vector3, length: float = 200.0, color: Color = Color.GREEN, radius: float = 10.0) -> void:
	var dt := DrawType.ARROW
	_ensure_buffer(dt)
	var d := direction.normalized()
	_buf_vec3(dt, position)
	_buf_vec3(dt, d)
	_buf_f32(dt, length)
	_buf_f32(dt, radius)
	_buf_color(dt, color)

## Sphere at position with given radius (immediate-mode, not oneshot).
## Layout: pos(3f) + radius(1f) + color(4f) = 8 floats = 32 bytes
func draw_im_sphere(position: Vector3, radius: float = 20.0, color: Color = Color.RED) -> void:
	var dt := DrawType.SPHERE
	_ensure_buffer(dt)
	_buf_vec3(dt, position)
	_buf_f32(dt, radius)
	_buf_color(dt, color)

## Flat circle (ring) on the XZ plane at position with given radius.
## Layout: pos(3f) + radius(1f) + color(4f) + segments(1f) = 9 floats = 36 bytes
func draw_circle(position: Vector3, radius: float = 100.0, color: Color = Color.CYAN, segments: int = 48) -> void:
	var dt := DrawType.CIRCLE
	_ensure_buffer(dt)
	_buf_vec3(dt, position)
	_buf_f32(dt, radius)
	_buf_color(dt, color)
	_buf_f32(dt, float(segments))

## Line from point A to point B.
## Layout: from(3f) + to(3f) + color(4f) = 10 floats = 40 bytes
func draw_line(from: Vector3, to: Vector3, color: Color = Color.WHITE) -> void:
	var dt := DrawType.LINE
	_ensure_buffer(dt)
	_buf_vec3(dt, from)
	_buf_vec3(dt, to)
	_buf_color(dt, color)

## Connected path (line strip) through an array of points.
## Variable layout: color(4f) + sphere_interval(1f) + sphere_radius(1f) + point_count(1f) = 7 floats header, then point_count * 3 floats
func draw_path(points: PackedVector3Array, color: Color = Color.MAGENTA, sphere_interval: int = 0, sphere_radius: float = 12.0) -> void:
	if points.size() < 2:
		return
	var dt := DrawType.PATH
	_ensure_buffer(dt)
	_buf_color(dt, color)
	_buf_f32(dt, float(sphere_interval))
	_buf_f32(dt, sphere_radius)
	_buf_f32(dt, float(points.size()))
	for pt in points:
		_buf_vec3(dt, pt)

## Flat filled or outline square/rectangle on the XZ plane.
## Layout: pos(3f) + width(1f) + height(1f) + color(4f) + filled(1f) = 10 floats = 40 bytes
func draw_square(position: Vector3, width: float, height: float, color: Color = Color.YELLOW, filled: bool = true) -> void:
	var dt := DrawType.SQUARE
	_ensure_buffer(dt)
	_buf_vec3(dt, position)
	_buf_f32(dt, width)
	_buf_f32(dt, height)
	_buf_color(dt, color)
	_buf_f32(dt, 1.0 if filled else 0.0)

## 3D label (billboard text) at position.
## Variable layout: pos(3f) + color(4f) + font_size(1f) + text_byte_len(1i) = 36 bytes header, then text bytes (padded to 4-byte boundary)
func draw_label(position: Vector3, text: String, color: Color = Color.WHITE, font_size: int = 16) -> void:
	var dt := DrawType.LABEL
	_ensure_buffer(dt)
	_buf_vec3(dt, position)
	_buf_color(dt, color)
	_buf_f32(dt, float(font_size))
	var text_bytes := text.to_utf8_buffer()
	_buf_i32(dt, text_bytes.size())
	_buf_bytes(dt, text_bytes)
	# Pad to 4-byte boundary
	var remainder := text_bytes.size() % 4
	if remainder != 0:
		var padding := 4 - remainder
		for _i in range(padding):
			_buf_pad(dt)

## Cone (like arrow but with explicit top/bottom radii).
## Layout: pos(3f) + rot(3f) + cone_height(1f) + top_radius(1f) + bottom_radius(1f) + color(4f) + radial_segments(1f) = 14 floats = 56 bytes
func draw_cone(position: Vector3, rotation_euler: Vector3 = Vector3.ZERO, cone_height: float = 80.0, top_radius: float = 0.0, bottom_radius: float = 40.0, color: Color = Color.RED, radial_segments: int = 8) -> void:
	var dt := DrawType.CONE
	_ensure_buffer(dt)
	_buf_vec3(dt, position)
	_buf_vec3(dt, rotation_euler)
	_buf_f32(dt, cone_height)
	_buf_f32(dt, top_radius)
	_buf_f32(dt, bottom_radius)
	_buf_color(dt, color)
	_buf_f32(dt, float(radial_segments))

# ============================================================================
# Server: flush draw commands to client
# ============================================================================

func _server_flush() -> void:
	if follow_ship == null or not is_instance_valid(follow_ship):
		_clear_buffers()
		return

	if _follower_peer_id <= 0:
		_clear_buffers()
		return

	var connected_peers := multiplayer.get_peers()
	if _follower_peer_id not in connected_peers:
		_follower_peer_id = 0
		follow_ship = null
		_clear_buffers()
		return

	# Build the payload: only include types that have data
	var payload: Dictionary = {}
	for draw_type in _draw_buffers:
		var buf: PackedByteArray = _draw_buffers[draw_type]
		if buf.size() > 0:
			payload[draw_type] = buf

	_receive_draw_buffers.rpc_id(_follower_peer_id, payload)
	_clear_buffers()

# ============================================================================
# Client: receive + decode
# ============================================================================

@rpc("authority", "call_remote", "unreliable")
func _receive_draw_buffers(payload: Dictionary) -> void:
	_client_buffers = payload
	_decode_client_buffers()

## Decode all packed buffers into per-type command lists.
func _decode_client_buffers() -> void:
	_client_type_commands.clear()

	for draw_type in _client_buffers:
		var buf: PackedByteArray = _client_buffers[draw_type]
		if buf.size() == 0:
			continue

		match draw_type:
			DrawType.ARROW:
				_decode_fixed_stride(buf, draw_type, STRIDE_ARROW)
			DrawType.SPHERE:
				_decode_fixed_stride(buf, draw_type, STRIDE_SPHERE)
			DrawType.CIRCLE:
				_decode_fixed_stride(buf, draw_type, STRIDE_CIRCLE)
			DrawType.LINE:
				_decode_fixed_stride(buf, draw_type, STRIDE_LINE)
			DrawType.PATH:
				_decode_paths(buf)
			DrawType.SQUARE:
				_decode_fixed_stride(buf, draw_type, STRIDE_SQUARE)
			DrawType.LABEL:
				_decode_labels(buf)
			DrawType.CONE:
				_decode_fixed_stride(buf, draw_type, STRIDE_CONE)

func _decode_fixed_stride(buf: PackedByteArray, draw_type: int, stride: int) -> void:
	if not _client_type_commands.has(draw_type):
		_client_type_commands[draw_type] = []
	var cmds: Array = _client_type_commands[draw_type]

	var offset := 0
	while offset + stride <= buf.size():
		match draw_type:
			DrawType.ARROW:
				var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var dir := Vector3(buf.decode_float(offset + 12), buf.decode_float(offset + 16), buf.decode_float(offset + 20))
				var cmd_length := buf.decode_float(offset + 24)
				var cmd_radius := buf.decode_float(offset + 28)
				var color := Color(buf.decode_float(offset + 32), buf.decode_float(offset + 36), buf.decode_float(offset + 40), buf.decode_float(offset + 44))
				cmds.append([pos, dir, cmd_length, cmd_radius, color])
			DrawType.SPHERE:
				var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var cmd_radius := buf.decode_float(offset + 12)
				var color := Color(buf.decode_float(offset + 16), buf.decode_float(offset + 20), buf.decode_float(offset + 24), buf.decode_float(offset + 28))
				cmds.append([pos, cmd_radius, color])
			DrawType.CIRCLE:
				var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var cmd_radius := buf.decode_float(offset + 12)
				var color := Color(buf.decode_float(offset + 16), buf.decode_float(offset + 20), buf.decode_float(offset + 24), buf.decode_float(offset + 28))
				var segments := int(buf.decode_float(offset + 32))
				cmds.append([pos, cmd_radius, color, segments])
			DrawType.LINE:
				var from_pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var to_pos := Vector3(buf.decode_float(offset + 12), buf.decode_float(offset + 16), buf.decode_float(offset + 20))
				var color := Color(buf.decode_float(offset + 24), buf.decode_float(offset + 28), buf.decode_float(offset + 32), buf.decode_float(offset + 36))
				cmds.append([from_pos, to_pos, color])
			DrawType.SQUARE:
				var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var w := buf.decode_float(offset + 12)
				var h := buf.decode_float(offset + 16)
				var color := Color(buf.decode_float(offset + 20), buf.decode_float(offset + 24), buf.decode_float(offset + 28), buf.decode_float(offset + 32))
				var filled := buf.decode_float(offset + 36) > 0.5
				cmds.append([pos, w, h, color, filled])
			DrawType.CONE:
				var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
				var rot := Vector3(buf.decode_float(offset + 12), buf.decode_float(offset + 16), buf.decode_float(offset + 20))
				var cone_height := buf.decode_float(offset + 24)
				var top_r := buf.decode_float(offset + 28)
				var bottom_r := buf.decode_float(offset + 32)
				var color := Color(buf.decode_float(offset + 36), buf.decode_float(offset + 40), buf.decode_float(offset + 44), buf.decode_float(offset + 48))
				var segs := int(buf.decode_float(offset + 52))
				cmds.append([pos, rot, cone_height, top_r, bottom_r, color, segs])
		offset += stride

func _decode_paths(buf: PackedByteArray) -> void:
	if not _client_type_commands.has(DrawType.PATH):
		_client_type_commands[DrawType.PATH] = []
	var cmds: Array = _client_type_commands[DrawType.PATH]

	var offset := 0
	while offset < buf.size():
		# Header: color(4f) + sphere_interval(1f) + sphere_radius(1f) + point_count(1f) = 28 bytes
		if offset + 28 > buf.size():
			break
		var color := Color(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8), buf.decode_float(offset + 12))
		var sphere_interval := int(buf.decode_float(offset + 16))
		var sphere_radius := buf.decode_float(offset + 20)
		var point_count := int(buf.decode_float(offset + 24))
		offset += 28
		# Points: point_count * 12 bytes
		var points_size := point_count * 12
		if offset + points_size > buf.size():
			break
		var points := PackedVector3Array()
		points.resize(point_count)
		for i in range(point_count):
			var po := offset + i * 12
			points[i] = Vector3(buf.decode_float(po), buf.decode_float(po + 4), buf.decode_float(po + 8))
		offset += points_size
		cmds.append([points, color, sphere_interval, sphere_radius])

func _decode_labels(buf: PackedByteArray) -> void:
	if not _client_type_commands.has(DrawType.LABEL):
		_client_type_commands[DrawType.LABEL] = []
	var cmds: Array = _client_type_commands[DrawType.LABEL]

	var offset := 0
	while offset < buf.size():
		# Header: pos(3f) + color(4f) + font_size(1f) + text_byte_len(1i) = 36 bytes
		if offset + 36 > buf.size():
			break
		var pos := Vector3(buf.decode_float(offset), buf.decode_float(offset + 4), buf.decode_float(offset + 8))
		var color := Color(buf.decode_float(offset + 12), buf.decode_float(offset + 16), buf.decode_float(offset + 20), buf.decode_float(offset + 24))
		var font_size := int(buf.decode_float(offset + 28))
		var text_len := buf.decode_s32(offset + 32)
		offset += 36
		if offset + text_len > buf.size():
			break
		var text_bytes := buf.slice(offset, offset + text_len)
		var text := text_bytes.get_string_from_utf8()
		# Advance past text + padding
		var padded_len := text_len
		var remainder := text_len % 4
		if remainder != 0:
			padded_len += 4 - remainder
		offset += padded_len
		cmds.append([pos, text, color, font_size])

# ============================================================================
# Client: mesh pool management
#
# The pool is a Dictionary keyed by "type:index" (e.g. "5:42" for the 43rd
# SQUARE command). This means that if the number of ARROW commands changes
# between frames, SQUARE meshes remain stable and are not rebuilt.
# ============================================================================

func _update_mesh_pool() -> void:
	if not _following:
		return

	_active_keys.clear()

	# Iterate each type's commands and update/create mesh nodes
	for draw_type in _client_type_commands:
		var cmds: Array = _client_type_commands[draw_type]
		for i in range(cmds.size()):
			var cmd: Array = cmds[i]
			var pool_key := "%d:%d" % [draw_type, i]
			_active_keys[pool_key] = true

			var construction_key := _build_key(draw_type, cmd)

			# Check if we need to rebuild the mesh
			var existing_key: String = _mesh_keys.get(pool_key, "")
			var node: Node3D = _mesh_pool.get(pool_key)

			if existing_key != construction_key or node == null or not is_instance_valid(node):
				# Destroy old node
				if node != null and is_instance_valid(node):
					node.queue_free()
				# Build new node
				node = _build_node(draw_type, cmd, pool_key.hash())
				_mesh_pool[pool_key] = node
				_mesh_keys[pool_key] = construction_key
				if node != null:
					get_tree().root.add_child(node)

			# Update transform / dynamic properties
			if node != null and is_instance_valid(node):
				_update_node(draw_type, cmd, node)

	# Remove meshes for keys that are no longer active
	var stale_keys: Array = []
	for pool_key in _mesh_pool:
		if not _active_keys.has(pool_key):
			stale_keys.append(pool_key)

	for pool_key in stale_keys:
		var node: Node3D = _mesh_pool[pool_key]
		if node != null and is_instance_valid(node):
			node.queue_free()
		_mesh_pool.erase(pool_key)
		_mesh_keys.erase(pool_key)

func _clear_mesh_pool() -> void:
	for pool_key in _mesh_pool:
		var node: Node3D = _mesh_pool[pool_key]
		if node != null and is_instance_valid(node):
			node.queue_free()
	_mesh_pool.clear()
	_mesh_keys.clear()
	_active_keys.clear()

## Build a construction key from an array-based command.
## Encodes shape type + params that require mesh reconstruction when they change.
## Transform-only params are excluded so we can update without rebuilding.
func _build_key(draw_type: int, cmd: Array) -> String:
	match draw_type:
		DrawType.ARROW:
			# cmd: [pos, dir, length, radius, color]
			return "arrow:%.0f:%.0f" % [cmd[2], cmd[3]]
		DrawType.SPHERE:
			# cmd: [pos, radius, color]
			return "sphere:%.1f" % cmd[1]
		DrawType.CIRCLE:
			# cmd: [pos, radius, color, segments]
			return "circle:%.1f:%d" % [cmd[1], cmd[3]]
		DrawType.LINE:
			# cmd: [from, to, color]
			var f: Vector3 = cmd[0]
			var t: Vector3 = cmd[1]
			return "line:%.0f,%.0f,%.0f:%.0f,%.0f,%.0f" % [f.x, f.y, f.z, t.x, t.y, t.z]
		DrawType.PATH:
			# cmd: [points, color, sphere_interval, sphere_radius]
			var pts: PackedVector3Array = cmd[0]
			var pc := pts.size()
			if pc >= 2:
				return "path:%d:%.0f,%.0f:%.0f,%.0f:%d:%.1f" % [pc, pts[0].x, pts[0].z, pts[pc-1].x, pts[pc-1].z, cmd[2], cmd[3]]
			return "path:%d" % pc
		DrawType.SQUARE:
			# cmd: [pos, width, height, color, filled]
			return "square:%.1f:%.1f:%s" % [cmd[1], cmd[2], "f" if cmd[4] else "o"]
		DrawType.LABEL:
			# cmd: [pos, text, color, font_size]
			return "label:%s:%d" % [cmd[1], cmd[3]]
		DrawType.CONE:
			# cmd: [pos, rot, cone_height, top_radius, bottom_radius, color, radial_segments]
			return "cone:%.1f:%.1f:%.1f:%d" % [cmd[2], cmd[3], cmd[4], cmd[6]]
	return "unknown:%d" % draw_type

# ============================================================================
# Client: node builders
# ============================================================================

func _build_node(draw_type: int, cmd: Array, idx: int) -> Node3D:
	match draw_type:
		DrawType.ARROW:
			return _build_arrow(cmd, idx)
		DrawType.SPHERE:
			return _build_sphere_node(cmd, idx)
		DrawType.CIRCLE:
			return _build_circle_node(cmd, idx)
		DrawType.LINE:
			return _build_line_node(cmd, idx)
		DrawType.PATH:
			return _build_path_node(cmd, idx)
		DrawType.SQUARE:
			return _build_square_node(cmd, idx)
		DrawType.LABEL:
			return _build_label_node(cmd, idx)
		DrawType.CONE:
			return _build_cone_node(cmd, idx)
	return null

func _make_unshaded_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

func _build_arrow(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [pos, dir, length, radius, color]
	var arrow_length: float = cmd[2]
	var r: float = cmd[3]
	var color: Color = cmd[4]

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = r
	mesh.height = arrow_length
	mesh.radial_segments = 8

	var node := MeshInstance3D.new()
	node.name = "DebugArrow_%d" % idx
	node.mesh = mesh
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _build_sphere_node(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [pos, radius, color]
	var r: float = cmd[1]
	var color: Color = cmd[2]

	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4

	var node := MeshInstance3D.new()
	node.name = "DebugSphere_%d" % idx
	node.mesh = mesh
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _build_circle_node(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [pos, radius, color, segments]
	var r: float = cmd[1]
	var color: Color = cmd[2]
	var segments: int = cmd[3]

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(segments + 1):
		var angle = TAU * float(i) / float(segments)
		im.surface_add_vertex(Vector3(cos(angle) * r, 0.0, sin(angle) * r))
	im.surface_end()

	var node := MeshInstance3D.new()
	node.name = "DebugCircle_%d" % idx
	node.mesh = im
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _build_line_node(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [from, to, color]
	var from_pos: Vector3 = cmd[0]
	var to_pos: Vector3 = cmd[1]
	var color: Color = cmd[2]

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(from_pos)
	im.surface_add_vertex(to_pos)
	im.surface_end()

	var node := MeshInstance3D.new()
	node.name = "DebugLine_%d" % idx
	node.mesh = im
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _build_path_node(cmd: Array, idx: int) -> Node3D:
	# cmd: [points, color, sphere_interval, sphere_radius]
	var points: PackedVector3Array = cmd[0]
	var color: Color = cmd[1]
	var sphere_interval: int = cmd[2]
	var sphere_radius: float = cmd[3]

	var parent := Node3D.new()
	parent.name = "DebugPath_%d" % idx

	if points.size() >= 2:
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for pt in points:
			im.surface_add_vertex(pt)
		im.surface_end()

		var line_node := MeshInstance3D.new()
		line_node.name = "PathLine"
		line_node.mesh = im
		line_node.material_override = _make_unshaded_material(color)
		line_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(line_node)

	if sphere_interval > 0 and points.size() > 0:
		var pt_count := points.size()
		for i in range(0, pt_count, sphere_interval):
			var sp_mesh := SphereMesh.new()
			sp_mesh.radius = sphere_radius
			sp_mesh.height = sphere_radius * 2.0
			sp_mesh.radial_segments = 6
			sp_mesh.rings = 3

			var sp_node := MeshInstance3D.new()
			sp_node.name = "PathSphere_%d" % i
			sp_node.mesh = sp_mesh
			var grad_t := float(i) / float(maxi(pt_count - 1, 1))
			var sp_color := Color(color.r, color.g * (1.0 - grad_t * 0.3), color.b * (1.0 - grad_t * 0.3), color.a)
			sp_node.material_override = _make_unshaded_material(sp_color)
			sp_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			sp_node.position = points[i]
			parent.add_child(sp_node)

	return parent

func _build_square_node(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [pos, width, height, color, filled]
	var width: float = cmd[1]
	var height: float = cmd[2]
	var color: Color = cmd[3]
	var filled: bool = cmd[4]

	var im := ImmediateMesh.new()
	var hw := width * 0.5
	var hh := height * 0.5

	if filled:
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
		im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
		im.surface_add_vertex(Vector3( hw, 0.0, -hh))
		im.surface_add_vertex(Vector3( hw, 0.0,  hh))
		im.surface_end()
	else:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
		im.surface_add_vertex(Vector3( hw, 0.0, -hh))
		im.surface_add_vertex(Vector3( hw, 0.0,  hh))
		im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
		im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
		im.surface_end()

	var mat := _make_unshaded_material(color)
	if filled:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var node := MeshInstance3D.new()
	node.name = "DebugSquare_%d" % idx
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _build_label_node(cmd: Array, idx: int) -> Label3D:
	# cmd: [pos, text, color, font_size]
	var color: Color = cmd[2]
	var font_size: int = cmd[3]
	var text: String = cmd[1]

	var label := Label3D.new()
	label.name = "DebugLabel_%d" % idx
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.001
	label.font_size = font_size
	label.modulate = color
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	label.outline_size = 4
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.text = text
	return label

func _build_cone_node(cmd: Array, idx: int) -> MeshInstance3D:
	# cmd: [pos, rot, cone_height, top_radius, bottom_radius, color, radial_segments]
	var cone_height: float = cmd[2]
	var top_r: float = cmd[3]
	var bottom_r: float = cmd[4]
	var color: Color = cmd[5]
	var segs: int = cmd[6]

	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = cone_height
	mesh.radial_segments = segs

	var node := MeshInstance3D.new()
	node.name = "DebugCone_%d" % idx
	node.mesh = mesh
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

# ============================================================================
# Client: node updaters — set transform / dynamic props without rebuilding
# ============================================================================

func _update_node(draw_type: int, cmd: Array, node: Node3D) -> void:
	match draw_type:
		DrawType.ARROW:
			_update_arrow(cmd, node)
		DrawType.SPHERE:
			_update_sphere_node(cmd, node)
		DrawType.CIRCLE:
			_update_circle_node(cmd, node)
		DrawType.LINE:
			_update_color_only(cmd, node, 2)  # color at index 2
		DrawType.PATH:
			pass  # Paths are baked in world space
		DrawType.SQUARE:
			_update_square_node(cmd, node)
		DrawType.LABEL:
			_update_label_node(cmd, node)
		DrawType.CONE:
			_update_cone_node(cmd, node)
	node.visible = true

func _update_arrow(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, dir, length, radius, color]
	var pos: Vector3 = cmd[0]
	var dir: Vector3 = cmd[1]
	var arrow_length: float = cmd[2]
	var color: Color = cmd[4]

	var end_pos := pos + dir.normalized() * arrow_length
	var mid_pos := (pos + end_pos) * 0.5
	node.global_position = mid_pos

	var heading_angle := atan2(dir.x, dir.z)
	node.rotation = Vector3(PI / 2.0, heading_angle, 0)

	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

func _update_sphere_node(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, radius, color]
	node.global_position = cmd[0]
	var color: Color = cmd[2]
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

func _update_circle_node(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, radius, color, segments]
	node.global_position = cmd[0]
	var color: Color = cmd[2]
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

func _update_color_only(cmd: Array, node: Node3D, color_idx: int) -> void:
	var color: Color = cmd[color_idx]
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

func _update_square_node(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, width, height, color, filled]
	node.global_position = cmd[0]
	var color: Color = cmd[3]
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

func _update_label_node(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, text, color, font_size]
	node.global_position = cmd[0]
	if node is Label3D:
		var lbl := node as Label3D
		var text: String = cmd[1]
		var color: Color = cmd[2]
		if lbl.text != text:
			lbl.text = text
		if lbl.modulate != color:
			lbl.modulate = color

func _update_cone_node(cmd: Array, node: Node3D) -> void:
	# cmd: [pos, rot, cone_height, top_radius, bottom_radius, color, radial_segments]
	node.global_position = cmd[0]
	node.rotation = cmd[1]
	var color: Color = cmd[5]
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override as StandardMaterial3D
		if mat and mat.albedo_color != color:
			mat.albedo_color = color

# ============================================================================
# Oneshot mesh helpers (legacy standalone draws)
# ============================================================================

func _create_oneshot_circle_mesh(radius: float, color: Color, _line_width: float = 3.0, segments: int = 48) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(segments + 1):
		var angle = TAU * float(i) / float(segments)
		im.surface_add_vertex(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	im.surface_end()

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _create_oneshot_filled_square(width: float, height: float, color: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var hw := width * 0.5
	var hh := height * 0.5
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
	im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
	im.surface_add_vertex(Vector3( hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0,  hh))
	im.surface_end()

	var mat := _make_unshaded_material(color)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _create_oneshot_outline_square(width: float, height: float, color: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var hw := width * 0.5
	var hh := height * 0.5
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0, -hh))
	im.surface_add_vertex(Vector3( hw, 0.0,  hh))
	im.surface_add_vertex(Vector3(-hw, 0.0,  hh))
	im.surface_add_vertex(Vector3(-hw, 0.0, -hh))
	im.surface_end()

	var node := MeshInstance3D.new()
	node.mesh = im
	node.material_override = _make_unshaded_material(color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _attach_oneshot_lifetime(node: Node3D, duration: float) -> void:
	var t := Timer.new()
	t.wait_time = duration
	t.one_shot = true
	t.autostart = true
	t.timeout.connect(func(): node.queue_free())
	node.add_child(t)
