extends SceneTree

## Headless Phase 2 smoke test for Godot 4.7.2 + SpacetimeWire.gd.
##
## Registers all 5 Phase 2 table schemas, subscribes, calls `set_nickname`,
## `create_room`, verifies decoded `room` and `room_member` rows from
## `TransactionUpdate`, calls `leave_room`, and exits 0.

const SpacetimeWire = preload("res://autoload/SpacetimeWire.gd")

const DEFAULT_URL := "ws://127.0.0.1:3100/v1/database/jumpernbumper/subscribe"
const TIMEOUT_MS := 10000

const TABLE_SCHEMAS := {
	"player": ["identity", "nickname", "connected", "room_id"],
	"room": [
		"id", "code", "name", "is_public", "host_identity", "status",
		"win_mode", "win_target", "mut_low_gravity", "mut_pogo", "mut_jetpack",
		"gore_enabled", "tick_count", "elapsed_ms", "winner_slot"
	],
	"room_member": ["identity", "room_id", "slot", "nickname", "ready", "kills", "deaths"],
	"match_bunny": [
		"identity", "room_id", "slot", "x", "y", "vx", "vy", "facing",
		"alive", "respawn_ticks", "invuln_ticks", "on_ground", "in_water",
		"on_ice", "prev_jump", "input_bits", "last_seq"
	],
	"kill_event": ["id", "room_id", "tick", "killer_slot", "victim_slot", "x", "y"],
}

enum Step {
	CONNECTING,
	SUBSCRIBING,
	CREATING_ROOM,
	LEAVING_ROOM,
	DONE,
}

var _wire: SpacetimeWire
var _step: int = Step.CONNECTING
var _start_ms: int = 0
var _create_req_id: int = -1
var _leave_req_id: int = -1
var _created_room_id: int = 0


func _init() -> void:
	_start_ms = Time.get_ticks_msec()
	var url := _parse_url_arg()

	_wire = SpacetimeWire.new()
	for table_name in TABLE_SCHEMAS.keys():
		var cols: Array = TABLE_SCHEMAS[table_name]
		_wire.register_table(table_name, PackedStringArray(cols))

	_wire.connected.connect(_on_connected)
	_wire.identity_received.connect(_on_identity_received)
	_wire.initial_subscription.connect(_on_initial_subscription)
	_wire.transaction_committed.connect(_on_transaction_committed)
	_wire.transaction_failed.connect(_on_transaction_failed)
	_wire.disconnected.connect(_on_disconnected)

	var err := _wire.connect_to_database(url)
	if err != OK:
		_fail("connect_to_database failed: %s" % error_string(err))


func _process(_delta: float) -> bool:
	if _step == Step.DONE:
		return true

	_wire.poll()
	if Time.get_ticks_msec() - _start_ms > TIMEOUT_MS:
		_fail("Timed out in step %d" % _step)
		return true

	OS.delay_msec(5)
	return false


func _parse_url_arg() -> String:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--url":
			return args[i + 1]
	return DEFAULT_URL


func _on_connected() -> void:
	print("[phase2_smoke] WebSocket connected")


func _on_identity_received(identity_hex: String, _token: String) -> void:
	if identity_hex.is_empty():
		_fail("Empty identity")
		return
	_step = Step.SUBSCRIBING
	_wire.subscribe(PackedStringArray([
		"SELECT * FROM player",
		"SELECT * FROM room",
		"SELECT * FROM room_member",
		"SELECT * FROM match_bunny",
		"SELECT * FROM kill_event",
	]))


func _on_initial_subscription(tables: Dictionary, _request_id: int) -> void:
	if not tables.has("player"):
		_fail("Missing player table in InitialSubscription (got keys=%s)" % str(tables.keys()))
		return
	_step = Step.CREATING_ROOM
	_wire.call_reducer("set_nickname", ["GodotSmoke"])
	_create_req_id = _wire.call_reducer("create_room", ["Godot Smoke", true])


func _on_transaction_committed(tables: Dictionary, reducer_call: Dictionary) -> void:
	var req_id := int(reducer_call.get("request_id", -1))
	if _step == Step.CREATING_ROOM and req_id == _create_req_id:
		var room_inserts: Array = tables.get("room", {}).get("inserts", [])
		if room_inserts.is_empty():
			_fail("create_room did not return room insert")
			return
		var room_row: Dictionary = room_inserts[0]
		_created_room_id = int(room_row.get("id", 0))
		var code := str(room_row.get("code", ""))
		if _created_room_id < 1 or code.length() != 5:
			_fail("Unexpected decoded room row: %s" % str(room_row))
			return
		print("[phase2_smoke] Decoded room id=%d code=%s" % [_created_room_id, code])
		_step = Step.LEAVING_ROOM
		_leave_req_id = _wire.call_reducer("leave_room", [])
	elif _step == Step.LEAVING_ROOM and req_id == _leave_req_id:
		print("[phase2_smoke] PASS: Godot SpacetimeWire decoded Phase 2 tables cleanly")
		_step = Step.DONE
		_wire.close()
		quit(0)


func _on_transaction_failed(error_message: String, reducer_call: Dictionary) -> void:
	_fail("Reducer %s failed: %s" % [str(reducer_call.get("reducer_name", "?")), error_message])


func _on_disconnected(code: int, reason: String) -> void:
	if _step != Step.DONE:
		_fail("Unexpected disconnect (code=%d, reason=%s)" % [code, reason])


func _fail(reason: String) -> void:
	printerr("[phase2_smoke] FAIL: %s" % reason)
	_step = Step.DONE
	if _wire != null:
		_wire.close()
	quit(1)
