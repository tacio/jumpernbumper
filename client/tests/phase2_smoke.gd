extends SceneTree

## Headless Phase 2 smoke test for Godot 4.7.2 + SpacetimeWire.gd.
##
## Registers the client-visible view schemas from `res://data/table_schemas.json`,
## subscribes, calls `set_nickname`, `create_room`, verifies the decoded `my_room`
## row from `TransactionUpdate`, calls `leave_room`, and exits 0.

const SpacetimeWire = preload("res://autoload/SpacetimeWire.gd")

const DEFAULT_URL := "ws://127.0.0.1:3100/v1/database/jumpernbumper/subscribe"
const TIMEOUT_MS := 10000

const SCHEMAS_PATH := "res://data/table_schemas.json"
const VIEW_NAMES: Array[String] = [
	"my_player", "my_room", "my_room_member", "my_match_bunny", "my_kill_event", "public_room",
]

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
	var schemas: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SCHEMAS_PATH)).get("tables", {})
	for view_name in VIEW_NAMES:
		if not schemas.has(view_name):
			_fail("Missing schema for view %s in %s" % [view_name, SCHEMAS_PATH])
			return
		_wire.register_table(view_name, PackedStringArray(schemas[view_name]))

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
	var queries := PackedStringArray()
	for view_name in VIEW_NAMES:
		queries.append("SELECT * FROM %s" % view_name)
	_wire.subscribe(queries)


func _on_initial_subscription(tables: Dictionary, _request_id: int) -> void:
	if not tables.has("my_player"):
		_fail("Missing my_player view in InitialSubscription (got keys=%s)" % str(tables.keys()))
		return
	_step = Step.CREATING_ROOM
	_wire.call_reducer("set_nickname", ["GodotSmoke"])
	_create_req_id = _wire.call_reducer("create_room", ["Godot Smoke", true])


func _on_transaction_committed(tables: Dictionary, reducer_call: Dictionary) -> void:
	var req_id := int(reducer_call.get("request_id", -1))
	if _step == Step.CREATING_ROOM and req_id == _create_req_id:
		var room_inserts: Array = tables.get("my_room", {}).get("inserts", [])
		if room_inserts.is_empty():
			_fail("create_room did not return my_room insert")
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
