extends Node

## Authoritative SpacetimeDB client singleton for Jumper 'n Bumper.
##
## Wraps `SpacetimeWire`, mirrors all 5 public server tables (`player`, `room`,
## `room_member`, `match_bunny`, `kill_event`) using schemas from
## `res://data/table_schemas.json`, exposes query helpers, and provides typed
## reducer RPC methods.

const SpacetimeWireScript = preload("res://autoload/SpacetimeWire.gd")

const SCHEMAS_PATH := "res://data/table_schemas.json"
const DEFAULT_WS_URL := "ws://127.0.0.1:3000/v1/database/jumpernbumper/subscribe"
const CONNECT_TIMEOUT_SEC := 8.0

const STATUS_WAITING := 0
const STATUS_IN_PROGRESS := 1
const STATUS_FINISHED := 2

const WIN_MODE_KILLS := 0
const WIN_MODE_TIME := 1

const INPUT_LEFT := 1
const INPUT_RIGHT := 2
const INPUT_JUMP := 4

const BUNNY_NAMES: Array[String] = ["Dott", "Jiffy", "Fizz", "Mijji"]

const TABLE_NAMES: Array[String] = [
	"player",
	"room",
	"room_member",
	"match_bunny",
	"kill_event",
]

signal connected_and_ready()
signal connection_lost(reason: String)
signal state_updated()
signal kill_event_received(event: Dictionary)
signal reducer_error(reducer_name: String, error_message: String, request_id: int)

var _wire: SpacetimeWire
var _schemas: Dictionary = {}
var _tables: Dictionary = {}

var _is_connecting: bool = false
var _is_ready: bool = false
var _intentional_disconnect: bool = false
var _connect_elapsed: float = 0.0
var _pending_nickname: String = ""
var _sub_request_id: int = -1
var _last_url: String = DEFAULT_WS_URL


func _init() -> void:
	_load_schemas()
	_reset_tables()
	_create_wire()


func _process(delta: float) -> void:
	poll(delta)


## Pumps the underlying WebSocket connection and enforces connect timeout.
func poll(delta: float = 0.0) -> void:
	if _wire == null:
		return
	if _is_connecting and not _is_ready:
		_connect_elapsed += delta
		if _connect_elapsed >= CONNECT_TIMEOUT_SEC:
			_handle_disconnect("Connection timed out")
			return
	_wire.poll()


## Connects to SpacetimeDB at `ws_url` and optionally sets `nickname` once ready.
func connect_to_server(ws_url: String = DEFAULT_WS_URL, nickname: String = "") -> Error:
	var trimmed_url := ws_url.strip_edges()
	if trimmed_url.is_empty():
		trimmed_url = DEFAULT_WS_URL

	if _is_connecting or _is_ready or (_wire != null and _wire.is_open()):
		_intentional_disconnect = true
		_wire.close(1000, "reconnect")

	_reset_tables()
	_create_wire()

	_last_url = trimmed_url
	_pending_nickname = nickname.strip_edges()
	_is_connecting = true
	_is_ready = false
	_intentional_disconnect = false
	_connect_elapsed = 0.0
	_sub_request_id = -1

	var err := _wire.connect_to_database(trimmed_url)
	if err != OK:
		_is_connecting = false
		connection_lost.emit("Connect failed: %s" % error_string(err))
	return err


## Cleanly disconnects from SpacetimeDB and clears local table mirrors.
func disconnect_from_server() -> void:
	_intentional_disconnect = true
	_is_connecting = false
	_is_ready = false
	_pending_nickname = ""
	if _wire != null:
		_wire.close(1000, "client_disconnect")
	_reset_tables()
	state_updated.emit()


## Returns true once WebSocket, IdentityToken, and InitialSubscription have completed.
func is_client_connected() -> bool:
	return _is_ready and _wire != null and _wire.is_open()


## Returns true while a connection / initial subscription handshake is in flight.
func is_connecting() -> bool:
	return _is_connecting and not _is_ready


## Returns the active WebSocket URL used for the current/last connection attempt.
func get_server_url() -> String:
	return _last_url


## Returns this client's 0x-prefixed SpacetimeDB identity hex string.
func my_identity() -> String:
	return _wire.identity_hex if _wire != null else ""


## Returns this client's `player` row, or an empty Dictionary if absent.
func get_my_player() -> Dictionary:
	var id := my_identity()
	if id.is_empty():
		return {}
	var players: Dictionary = _tables.get("player", {})
	if not players.has(id):
		return {}
	return (players[id] as Dictionary).duplicate()


## Returns this client's active `room` row, or an empty Dictionary if not in a room.
func get_my_room() -> Dictionary:
	var me := get_my_player()
	var room_id := int(me.get("room_id", 0))
	if room_id <= 0:
		return {}
	return get_room_by_id(room_id)


## Returns a `room` row by `room_id`, or an empty Dictionary.
func get_room_by_id(room_id: int) -> Dictionary:
	if room_id <= 0:
		return {}
	var rooms: Dictionary = _tables.get("room", {})
	if not rooms.has(room_id):
		return {}
	return (rooms[room_id] as Dictionary).duplicate()


## Returns this client's `room_member` row, or an empty Dictionary.
func get_my_room_member() -> Dictionary:
	var id := my_identity()
	if id.is_empty():
		return {}
	var members: Dictionary = _tables.get("room_member", {})
	if not members.has(id):
		return {}
	return (members[id] as Dictionary).duplicate()


## Returns all public rooms currently in `Waiting` status, sorted by room id ascending.
func get_public_waiting_rooms() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var rooms: Dictionary = _tables.get("room", {})
	for r in rooms.values():
		var row: Dictionary = r
		if bool(row.get("is_public", false)) and int(row.get("status", -1)) == STATUS_WAITING:
			result.append(row.duplicate())
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	return result


## Returns all `room_member` rows for `room_id`, sorted by bunny slot ascending.
func get_room_members(room_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if room_id <= 0:
		return result
	var members: Dictionary = _tables.get("room_member", {})
	for m in members.values():
		var row: Dictionary = m
		if int(row.get("room_id", 0)) == room_id:
			result.append(row.duplicate())
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("slot", 0)) < int(b.get("slot", 0))
	)
	return result


## Returns all `match_bunny` rows for `room_id`, sorted by bunny slot ascending.
func get_room_bunnies(room_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if room_id <= 0:
		return result
	var bunnies: Dictionary = _tables.get("match_bunny", {})
	for b in bunnies.values():
		var row: Dictionary = b
		if int(row.get("room_id", 0)) == room_id:
			result.append(row.duplicate())
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("slot", 0)) < int(b.get("slot", 0))
	)
	return result


## Returns true if this client is the host of its current room.
func is_host() -> bool:
	var room := get_my_room()
	if room.is_empty():
		return false
	var id := my_identity()
	return not id.is_empty() and str(room.get("host_identity", "")) == id


## Returns a snapshot dictionary of a mirrored table for diagnostics/testing.
func get_table_rows(table_name: String) -> Dictionary:
	return (_tables.get(table_name, {}) as Dictionary).duplicate(true)


# ---------------------------------------------------------------------------
# Typed Reducer RPCs
# ---------------------------------------------------------------------------

func set_nickname(nickname: String) -> int:
	return _call("set_nickname", [nickname])


func create_room(room_name: String, is_public: bool) -> int:
	return _call("create_room", [room_name, is_public])


func join_room_by_code(code: String) -> int:
	return _call("join_room_by_code", [code])


func join_public_room(room_id: int) -> int:
	return _call("join_public_room", [room_id])


func leave_room() -> int:
	return _call("leave_room", [])


func select_bunny_slot(slot: int) -> int:
	return _call("select_bunny_slot", [slot])


func toggle_ready() -> int:
	return _call("toggle_ready", [])


func add_bot(slot: int) -> int:
	return _call("add_bot", [slot])


func remove_bot(slot: int) -> int:
	return _call("remove_bot", [slot])


func update_room_settings(
	win_mode: int,
	win_target: int,
	mut_low_gravity: bool,
	mut_pogo: bool,
	mut_jetpack: bool,
	gore_enabled: bool
) -> int:
	return _call("update_room_settings", [
		win_mode,
		win_target,
		mut_low_gravity,
		mut_pogo,
		mut_jetpack,
		gore_enabled,
	])


func start_match() -> int:
	return _call("start_match", [])


func send_input(input_bits: int, seq: int) -> int:
	return _call("send_input", [input_bits, seq])


func return_to_lobby() -> int:
	return _call("return_to_lobby", [])


# ---------------------------------------------------------------------------
# Internal Wiring & Table Mirroring
# ---------------------------------------------------------------------------

func _call(reducer_name: String, args: Array) -> int:
	if not is_client_connected():
		reducer_error.emit(reducer_name, "Not connected to server", -1)
		return -1
	return _wire.call_reducer(reducer_name, args)


func _load_schemas() -> void:
	var f := FileAccess.open(SCHEMAS_PATH, FileAccess.READ)
	if f == null:
		push_error("SpacetimeClient: Failed to open %s (err=%d)" % [SCHEMAS_PATH, FileAccess.get_open_error()])
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpacetimeClient: Invalid JSON in %s" % SCHEMAS_PATH)
		return
	var doc: Dictionary = parsed
	var tables_var: Variant = doc.get("tables", {})
	if typeof(tables_var) == TYPE_DICTIONARY:
		_schemas = tables_var


func _reset_tables() -> void:
	_tables.clear()
	for t in TABLE_NAMES:
		_tables[t] = {}


func _create_wire() -> void:
	_wire = SpacetimeWireScript.new()
	for table_name in _schemas.keys():
		var cols_var: Variant = _schemas[table_name]
		if cols_var is Array:
			var cols := PackedStringArray()
			for c in cols_var:
				cols.append(str(c))
			_wire.register_table(str(table_name), cols)

	_wire.identity_received.connect(_on_identity_received)
	_wire.initial_subscription.connect(_on_initial_subscription)
	_wire.transaction_committed.connect(_on_transaction_committed)
	_wire.transaction_failed.connect(_on_transaction_failed)
	_wire.disconnected.connect(_on_wire_disconnected)


func _on_identity_received(_identity_hex: String, _token: String) -> void:
	if _wire == null:
		return
	var queries := PackedStringArray()
	for t in TABLE_NAMES:
		queries.append("SELECT * FROM %s" % t)
	_sub_request_id = _wire.subscribe(queries)


func _on_initial_subscription(tables_by_name: Dictionary, _request_id: int) -> void:
	_reset_tables()
	# Empty tables may be omitted by SpacetimeDB from InitialSubscription.
	for table_name in tables_by_name.keys():
		var tname := str(table_name)
		if not _tables.has(tname):
			continue
		var delta: Dictionary = tables_by_name[table_name]
		var inserts: Array = delta.get("inserts", [])
		var mirror: Dictionary = _tables[tname]
		for row in inserts:
			if row is Dictionary:
				var pk: Variant = _extract_pk(tname, row)
				if pk != null:
					mirror[pk] = row

	_is_connecting = false
	_is_ready = true

	if not _pending_nickname.is_empty():
		var nick := _pending_nickname
		_pending_nickname = ""
		_wire.call_reducer("set_nickname", [nick])

	connected_and_ready.emit()
	state_updated.emit()


func _on_transaction_committed(tables_by_name: Dictionary, _reducer_call: Dictionary) -> void:
	var any_changed := false
	var new_kills: Array[Dictionary] = []

	for table_name in tables_by_name.keys():
		var tname := str(table_name)
		if not _tables.has(tname):
			continue
		var delta: Dictionary = tables_by_name[table_name]
		var mirror: Dictionary = _tables[tname]

		# Apply deletes before inserts so updates with identical PK preserve new row.
		var deletes: Array = delta.get("deletes", [])
		for row in deletes:
			if row is Dictionary:
				var pk: Variant = _extract_pk(tname, row)
				if pk != null and mirror.has(pk):
					mirror.erase(pk)
					any_changed = true

		var inserts: Array = delta.get("inserts", [])
		for row in inserts:
			if row is Dictionary:
				var pk: Variant = _extract_pk(tname, row)
				if pk != null:
					mirror[pk] = row
					any_changed = true
					if tname == "kill_event":
						new_kills.append((row as Dictionary).duplicate())

	for ev in new_kills:
		kill_event_received.emit(ev)

	if any_changed:
		state_updated.emit()


func _on_transaction_failed(error_message: String, reducer_call: Dictionary) -> void:
	var rname := str(reducer_call.get("reducer_name", "unknown"))
	var req_id := int(reducer_call.get("request_id", -1))
	reducer_error.emit(rname, error_message, req_id)


func _on_wire_disconnected(code: int, reason: String) -> void:
	if _intentional_disconnect:
		_intentional_disconnect = false
		return
	var msg := reason.strip_edges()
	if msg.is_empty():
		msg = "Disconnected (code %d)" % code if code != 0 else "Unable to connect to server"
	_handle_disconnect(msg)


func _handle_disconnect(reason: String) -> void:
	_is_connecting = false
	_is_ready = false
	_pending_nickname = ""
	if _wire != null:
		_wire.close(1000, "cleanup")
	_reset_tables()
	connection_lost.emit(reason)
	state_updated.emit()


func _extract_pk(table_name: String, row: Dictionary) -> Variant:
	match table_name:
		"player", "room_member", "match_bunny":
			var id_str := str(row.get("identity", ""))
			return id_str if not id_str.is_empty() else null
		"room", "kill_event":
			if not row.has("id"):
				return null
			return int(row["id"])
		_:
			return null
