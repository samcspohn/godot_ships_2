## ReplayEvent — event-type constants, file-format magic/version,
## ship manifest entry, and StreamPeerBuffer read/write helpers.
## No scene required.  Used by both the recorder (server) and future
## replayer (client).
extends RefCounted
class_name ReplayEvent

# ---------------------------------------------------------------------------
# Event type constants
# ---------------------------------------------------------------------------
const MATCH_START       = 0x00
const MATCH_END         = 0x01
const SNAPSHOT          = 0x02
const SHELL_FIRED       = 0x10
const SHELL_HIT         = 0x11
const SHELL_DAMAGE      = 0x12
const TORPEDO_FIRED     = 0x20
const TORPEDO_ARMED     = 0x21
const TORPEDO_DETECTED  = 0x22
const TORPEDO_DESTROYED = 0x23
const FIRE_STARTED      = 0x30
const FIRE_ENDED        = 0x31
const FLOOD_STARTED     = 0x32
const FLOOD_ENDED       = 0x33
const FIRE_DAMAGE       = 0x34
const FLOOD_DAMAGE      = 0x35
const CONSUMABLE_USED   = 0x40
const CONSUMABLE_ENDED  = 0x41
const DETECTION_CHANGED = 0x50
const SHIP_SUNK         = 0x60

# ---------------------------------------------------------------------------
# File format magic / version
# ---------------------------------------------------------------------------
const MAGIC: int   = 0x52455050  # "REPP"
const VERSION: int = 4

# ---------------------------------------------------------------------------
# Ship manifest entry (populated from the header when reading a replay)
# ---------------------------------------------------------------------------
class ShipManifestEntry:
	var ship_id: int            ## 0-based index into the ships array
	var team_id: int
	var is_bot: bool
	var player_name: String     ## ship.name  (node / peer identifier)
	var ship_name: String       ## ship.ship_name  e.g. "Yamato"
	var scene_path: String      ## e.g. "res://Ships/Yamato/Yamato.tscn"
	var gun_count: int
	var fire_count: int
	var flood_count: int
	var consumable_count: int
	var consumable_types: Array   ## Array[int]  — ConsumableItem.ConsumableType
	var consumable_labels: Array  ## Array[String]

# ---------------------------------------------------------------------------
# StreamPeerBuffer helpers  (all arguments use explicit StreamPeerBuffer type)
# ---------------------------------------------------------------------------

## Write a string as [u8 byte-length][UTF-8 bytes].
## Strings longer than 255 bytes are silently truncated.
static func write_string(w: StreamPeerBuffer, s: String) -> void:
	var bytes: PackedByteArray = s.to_utf8_buffer()
	if bytes.size() > 255:
		bytes.resize(255)
	w.put_u8(bytes.size())
	for b in bytes:
		w.put_u8(b)

## Read a string previously written by write_string.
static func read_string(r: StreamPeerBuffer) -> String:
	var length: int = r.get_u8()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(length)
	for i in range(length):
		bytes[i] = r.get_u8()
	return bytes.get_string_from_utf8()

## Write a Vector3 using only x and z (y is omitted — for 2-D world positions).
static func write_v3_xz(w: StreamPeerBuffer, v: Vector3) -> void:
	w.put_float(v.x)
	w.put_float(v.z)

## Write a full Vector3 (x, y, z) — for velocities, shell launch vectors, etc.
static func write_v3(w: StreamPeerBuffer, v: Vector3) -> void:
	w.put_float(v.x)
	w.put_float(v.y)
	w.put_float(v.z)

## Read a Vector3 that was written with write_v3_xz.  Returns Vector3 with y=0.
static func read_v3_xz(r: StreamPeerBuffer) -> Vector3:
	var x: float = r.get_float()
	var z: float = r.get_float()
	return Vector3(x, 0.0, z)

## Read a full Vector3 (x, y, z).
static func read_v3(r: StreamPeerBuffer) -> Vector3:
	var x: float = r.get_float()
	var y: float = r.get_float()
	var z: float = r.get_float()
	return Vector3(x, y, z)
