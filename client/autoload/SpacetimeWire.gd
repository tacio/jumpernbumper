class_name SpacetimeWire
extends RefCounted

## Reusable pure-GDScript WebSocket client for SpacetimeDB v2.16.3 (`v1.json.spacetimedb`).
##
## Observed SpacetimeDB v2.16.3 `v1.json.spacetimedb` wire JSON formats:
##
## 1. Server -> Client: `IdentityToken` (sent immediately upon WebSocket connect)
##    {
##      "IdentityToken": {
##        "identity": {"__identity__": "0xc200..."},
##        "token": "<jwt>",
##        "connection_id": {"__connection_id__": 91670483785570049809055618568347699264}
##      }
##    }
##
## 2. Client -> Server: `Subscribe`
##    {
##      "Subscribe": {
##        "query_strings": ["SELECT * FROM spike_state"],
##        "request_id": 1
##      }
##    }
##
## 3. Server -> Client: `InitialSubscription`
##    Note: Row strings in `InitialSubscription` are JSON OBJECT strings!
##    {
##      "InitialSubscription": {
##        "database_update": {
##          "tables": [{
##            "table_id": 4096,
##            "table_name": "spike_state",
##            "num_rows": 1,
##            "updates": [{
##              "deletes": [],
##              "inserts": ["{\"id\":0,\"counter\":0,\"last_message\":\"ready\"}"]
##            }]
##          }]
##        },
##        "request_id": 1,
##        "total_host_execution_duration": {"__time_duration_micros__": 847}
##      }
##    }
##
## 4. Client -> Server: `CallReducer`
##    Note: `args` is a JSON-encoded string of the positional argument array.
##    {
##      "CallReducer": {
##        "reducer": "send_ping",
##        "args": "[\"hello_from_godot\"]",
##        "request_id": 2,
##        "flags": 0
##      }
##    }
##
## 5. Server -> Client: `TransactionUpdate` (response for caller's reducer or full update)
##    Note: Row strings in `TransactionUpdate` are JSON POSITIONAL ARRAY strings!
##    {
##      "TransactionUpdate": {
##        "status": {
##          "Committed": {
##            "tables": [{
##              "table_id": 4096,
##              "table_name": "spike_state",
##              "num_rows": 2,
##              "updates": [{
##                "deletes": ["[0,0,\"ready\"]"],
##                "inserts": ["[0,1,\"hello_from_godot\"]"]
##              }]
##            }]
##          }
##        },
##        "timestamp": {"__timestamp_micros_since_unix_epoch__": 1795557682991185},
##        "caller_identity": {"__identity__": "0xc200..."},
##        "caller_connection_id": {"__connection_id__": 91670483785570049809055618568347699264},
##        "reducer_call": {"reducer_name": "send_ping", "reducer_id": 1, "args": "...", "request_id": 2},
##        "energy_quanta_used": {"quanta": 3579},
##        "total_host_execution_duration": {"__time_duration_micros__": 46}
##      }
##    }
##    If a reducer fails, `status` contains `{"Failed": "<error message>"}` or `{"OutOfEnergy": {}}`.
##
## 6. Server -> Client: `TransactionUpdateLight` (broadcast for scheduled ticks & other callers)
##    Note: Row strings in `TransactionUpdateLight` are also JSON POSITIONAL ARRAY strings!
##    {
##      "TransactionUpdateLight": {
##        "request_id": 0,
##        "update": {
##          "tables": [{
##            "table_id": 4096,
##            "table_name": "spike_state",
##            "num_rows": 2,
##            "updates": [{
##              "deletes": ["[0,1,\"hello_from_godot\"]"],
##              "inserts": ["[0,2,\"hello_from_godot\"]"]
##            }]
##          }]
##        }
##      }
##    }

signal connected()
signal identity_received(identity_hex: String, token: String)
signal initial_subscription(tables_by_name: Dictionary, request_id: int)
signal transaction_committed(tables_by_name: Dictionary, reducer_call: Dictionary)
signal transaction_failed(error_message: String, reducer_call: Dictionary)
signal disconnected(code: int, reason: String)

const SUBPROTOCOL := "v1.json.spacetimedb"

var _ws := WebSocketPeer.new()
var _was_open := false
var _connecting := false
var _next_request_id := 1
var _table_schemas: Dictionary = {}

var identity_hex := ""
var auth_token := ""


## Registers positional column names for a table so `TransactionUpdate` /
## `TransactionUpdateLight` tuple rows normalize into Dictionaries matching
## `InitialSubscription` object rows.
func register_table(table_name: String, columns: PackedStringArray) -> void:
	_table_schemas[table_name] = columns


## Initiates an asynchronous WebSocket connection to SpacetimeDB.
func connect_to_database(ws_url: String) -> Error:
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray([SUBPROTOCOL])
	_ws.inbound_buffer_size = 1024 * 1024
	_ws.outbound_buffer_size = 256 * 1024
	_was_open = false
	_connecting = true
	identity_hex = ""
	auth_token = ""
	var err := _ws.connect_to_url(ws_url)
	if err != OK:
		_connecting = false
	return err


## Returns true when the underlying WebSocketPeer is in STATE_OPEN.
func is_open() -> bool:
	return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Sends a `Subscribe` message for one or more SQL queries and returns `request_id`.
func subscribe(query_strings: PackedStringArray) -> int:
	var req_id := _alloc_request_id()
	var queries: Array[String] = []
	for q in query_strings:
		queries.append(q)
	_send_json({
		"Subscribe": {
			"query_strings": queries,
			"request_id": req_id,
		}
	})
	return req_id


## Sends a `CallReducer` message with JSON-encoded positional args and returns `request_id`.
func call_reducer(reducer_name: String, args: Array = []) -> int:
	var req_id := _alloc_request_id()
	_send_json({
		"CallReducer": {
			"reducer": reducer_name,
			"args": JSON.stringify(args),
			"request_id": req_id,
			"flags": 0,
		}
	})
	return req_id


## Cleanly closes the WebSocket connection.
func close(code: int = 1000, reason: String = "normal") -> void:
	_connecting = false
	if _ws.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]:
		_ws.close(code, reason)


## Pumps the WebSocket peer, processes incoming packets, and emits signals.
func poll() -> void:
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		_connecting = false
		if not _was_open:
			_was_open = true
			connected.emit()
		while _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet().get_string_from_utf8()
			_handle_message(raw)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open or _connecting:
			_was_open = false
			_connecting = false
			disconnected.emit(_ws.get_close_code(), _ws.get_close_reason())


func _alloc_request_id() -> int:
	var req_id := _next_request_id
	_next_request_id += 1
	return req_id


func _send_json(payload: Dictionary) -> void:
	var text := JSON.stringify(payload)
	var err := _ws.send_text(text)
	if err != OK:
		push_error("SpacetimeWire: failed to send packet (%s): %s" % [error_string(err), text])


func _handle_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("SpacetimeWire: ignoring non-object message: %s" % raw)
		return
	var msg: Dictionary = parsed

	if msg.has("IdentityToken"):
		var body := _as_dict(msg.get("IdentityToken"))
		var id_obj := _as_dict(body.get("identity"))
		identity_hex = str(id_obj.get("__identity__", ""))
		auth_token = str(body.get("token", ""))
		identity_received.emit(identity_hex, auth_token)
	elif msg.has("InitialSubscription"):
		var body := _as_dict(msg.get("InitialSubscription"))
		var db_update := _as_dict(body.get("database_update"))
		var tables := _normalize_tables(_as_array(db_update.get("tables")))
		initial_subscription.emit(tables, int(body.get("request_id", 0)))
	elif msg.has("TransactionUpdate"):
		var body := _as_dict(msg.get("TransactionUpdate"))
		var reducer_call := _as_dict(body.get("reducer_call"))
		var status := _as_dict(body.get("status"))
		if status.has("Committed"):
			var committed := _as_dict(status.get("Committed"))
			var tables := _normalize_tables(_as_array(committed.get("tables")))
			transaction_committed.emit(tables, reducer_call)
		elif status.has("Failed"):
			transaction_failed.emit(str(status["Failed"]), reducer_call)
		elif status.has("OutOfEnergy"):
			transaction_failed.emit("OutOfEnergy", reducer_call)
	elif msg.has("TransactionUpdateLight"):
		var body := _as_dict(msg.get("TransactionUpdateLight"))
		var db_update := _as_dict(body.get("update"))
		var tables := _normalize_tables(_as_array(db_update.get("tables")))
		transaction_committed.emit(tables, {})
	elif msg.has("SubscriptionError"):
		push_error("SpacetimeWire: SubscriptionError: %s" % raw)


func _as_dict(value: Variant) -> Dictionary:
	return value as Dictionary if typeof(value) == TYPE_DICTIONARY else {}


func _as_array(value: Variant) -> Array:
	return value as Array if typeof(value) == TYPE_ARRAY else []


func _normalize_tables(raw_tables: Array) -> Dictionary:
	var result: Dictionary = {}
	for entry in raw_tables:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var table_dict: Dictionary = entry
		var table_name := str(table_dict.get("table_name", ""))
		var inserts: Array[Dictionary] = []
		var deletes: Array[Dictionary] = []

		var updates_var: Variant = table_dict.get("updates", [])
		if typeof(updates_var) == TYPE_ARRAY:
			for upd in updates_var as Array:
				if typeof(upd) != TYPE_DICTIONARY:
					continue
				var upd_dict: Dictionary = upd
				var dels_var: Variant = upd_dict.get("deletes", [])
				if typeof(dels_var) == TYPE_ARRAY:
					for raw_del in dels_var as Array:
						deletes.append(_decode_row(table_name, str(raw_del)))
				var ins_var: Variant = upd_dict.get("inserts", [])
				if typeof(ins_var) == TYPE_ARRAY:
					for raw_ins in ins_var as Array:
						inserts.append(_decode_row(table_name, str(raw_ins)))

		result[table_name] = {
			"inserts": inserts,
			"deletes": deletes,
		}
	return result


func _is_identity_hex_string(s: String) -> bool:
	if s.length() != 66 or not s.begins_with("0x"):
		return false
	for i in range(2, 66):
		var c := s.unicode_at(i)
		var is_digit := (c >= 48 and c <= 57)
		var is_upper := (c >= 65 and c <= 70)
		var is_lower := (c >= 97 and c <= 102)
		if not (is_digit or is_upper or is_lower):
			return false
	return true


func _normalize_value(val: Variant) -> Variant:
	if typeof(val) == TYPE_DICTIONARY:
		var d: Dictionary = val
		if d.has("__identity__"):
			return str(d["__identity__"])
	elif typeof(val) == TYPE_ARRAY:
		var arr: Array = val
		if arr.size() == 1 and typeof(arr[0]) == TYPE_STRING:
			var s: String = arr[0]
			if _is_identity_hex_string(s):
				return s
	return val


func _decode_row(table_name: String, raw_row: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw_row)
	if typeof(parsed) == TYPE_DICTIONARY:
		var obj: Dictionary = parsed
		var normalized: Dictionary = {}
		for key in obj.keys():
			normalized[key] = _normalize_value(obj[key])
		return normalized
	if typeof(parsed) == TYPE_ARRAY:
		var tuple_vals: Array = parsed
		var schema: PackedStringArray = _table_schemas.get(table_name, PackedStringArray())
		if schema.size() == tuple_vals.size():
			var row: Dictionary = {}
			for i in range(schema.size()):
				row[schema[i]] = _normalize_value(tuple_vals[i])
			return row
		return {"_tuple": tuple_vals}
	return {"_raw": raw_row}
