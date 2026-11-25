extends SceneTree

## Phase 4 Godot headless verification script.
##
## Modes (via user args after `--`):
##   --smoke                      Static scene instantiation, 400x256 UI bounds, InputMap,
##                                AudioManager SFX, and SpacetimeWire normalization checks.
##   --url <ws_url>               Single-process 2-client E2E flow using two SpacetimeClient nodes.
##   --role host --url <ws_url> --code-file <path>
##   --role guest --url <ws_url> --code-file <path>
##                                Multi-process 2-instance headless Godot E2E flow.

const SpacetimeWireScript = preload("res://autoload/SpacetimeWire.gd")
const SpacetimeClientScript = preload("res://autoload/SpacetimeClient.gd")
const AudioManagerScript = preload("res://autoload/AudioManager.gd")

const VIEWPORT_BOUNDS := Rect2(0.0, 0.0, 400.0, 256.0)
const TIMEOUT_MS := 25000

const SCENES_TO_SMOKE := [
	"res://scenes/Main.tscn",
	"res://scenes/ConnectScreen.tscn",
	"res://scenes/RoomBrowserScreen.tscn",
	"res://scenes/LobbyScreen.tscn",
	"res://scenes/GameWorld.tscn",
	"res://scenes/VictoryPodiumScreen.tscn",
]

var _mode: String = "smoke"
var _ws_url: String = ""
var _code_file: String = ""
var _start_ms: int = 0
var _done: bool = false

# Single-process or multi-process E2E state
var _host_client: Node = null
var _guest_client: Node = null
var _host_state: Dictionary = {}
var _guest_state: Dictionary = {}
var _smoke_ran: bool = false


func _init() -> void:
	_start_ms = Time.get_ticks_msec()
	_parse_args()


func _process(delta: float) -> bool:
	if _done:
		return true

	if _mode == "smoke":
		if not _smoke_ran:
			_smoke_ran = true
			var ok := _run_smoke_checks()
			_done = true
			quit(0 if ok else 1)
		return _done

	if Time.get_ticks_msec() - _start_ms > TIMEOUT_MS:
		_fail("E2E timed out in mode=%s (host_step=%s guest_step=%s)" % [
			_mode,
			str(_host_state.get("step", "?")),
			str(_guest_state.get("step", "?")),
		])
		return true

	if _host_client != null:
		_host_client.poll(delta)
		_step_host()
	if _guest_client != null:
		_guest_client.poll(delta)
		_step_guest()

	if _mode == "e2e" and _host_state.get("step") == "done" and _guest_state.get("step") == "done":
		print("[test_phase4_client] PASS: 2-instance E2E flow completed successfully")
		_cleanup_clients()
		_done = true
		quit(0)
		return true

	if _mode == "host" and _host_state.get("step") == "done":
		print("[test_phase4_client] PASS: Host E2E instance completed")
		_cleanup_clients()
		_done = true
		quit(0)
		return true

	if _mode == "guest" and _guest_state.get("step") == "done":
		print("[test_phase4_client] PASS: Guest E2E instance completed")
		_cleanup_clients()
		_done = true
		quit(0)
		return true

	OS.delay_msec(10)
	return false


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var role := ""
	var i := 0
	while i < args.size():
		var a := args[i]
		if a == "--smoke":
			_mode = "smoke"
		elif a == "--url" and i + 1 < args.size():
			_ws_url = args[i + 1]
			i += 1
		elif a == "--role" and i + 1 < args.size():
			role = args[i + 1]
			i += 1
		elif a == "--code-file" and i + 1 < args.size():
			_code_file = args[i + 1]
			i += 1
		i += 1

	if role == "host":
		_mode = "host"
		_start_host()
	elif role == "guest":
		_mode = "guest"
		_start_guest()
	elif not _ws_url.is_empty():
		_mode = "e2e"
		_start_host()
		_start_guest()
	else:
		_mode = "smoke"


# ---------------------------------------------------------------------------
# Static Smoke & UI Bounds Checks
# ---------------------------------------------------------------------------

func _run_smoke_checks() -> bool:
	# 1. Verify InputMap actions
	for action in ["move_left", "move_right", "jump", "pause_menu"]:
		if not InputMap.has_action(action):
			return _fail("Missing InputMap action: %s" % action)
		var events := InputMap.action_get_events(action)
		if events.is_empty():
			return _fail("InputMap action %s has no events" % action)

	# 2. Verify SpacetimeWire _normalize_value tightening
	var wire: SpacetimeWire = SpacetimeWireScript.new()
	var valid_ident := "0x" + "a1b2c3d4".repeat(8)
	if wire._normalize_value([valid_ident]) != valid_ident:
		return _fail("SpacetimeWire should unwrap 0x + 64-hex 1-element array")
	var non_ident_arr: Variant = wire._normalize_value(["hello"])
	if typeof(non_ident_arr) != TYPE_ARRAY or non_ident_arr != ["hello"]:
		return _fail("SpacetimeWire must NOT unwrap non-identity 1-element string array")
	var bad_hex := "0x" + "zzzzzzzz".repeat(8)
	if typeof(wire._normalize_value([bad_hex])) != TYPE_ARRAY:
		return _fail("SpacetimeWire must NOT unwrap invalid-hex 66-char string array")

	# 3. Mount AudioManager & SpacetimeClient on root for scene smoke tests
	var audio: Node = AudioManagerScript.new()
	audio.name = "AudioManager"
	root.add_child(audio)
	for sfx in ["jump", "stomp_splat", "puff", "spring", "splash", "countdown", "victory"]:
		if not audio.has_sfx(sfx):
			return _fail("AudioManager missing SFX: %s" % sfx)
	audio.play_sfx("jump")
	audio.play_sfx("victory")

	var client: Node = SpacetimeClientScript.new()
	client.name = "SpacetimeClient"
	root.add_child(client)
	if client.is_client_connected():
		return _fail("Fresh SpacetimeClient should not report connected")

	# 4. Instantiate every Phase 4 scene and verify 400x256 UI bounds
	root.size = Vector2i(400, 256)
	for scene_path in SCENES_TO_SMOKE:
		var packed := load(scene_path) as PackedScene
		if packed == null:
			return _fail("Failed to load scene: %s" % scene_path)
		var inst := packed.instantiate()
		if inst == null:
			return _fail("Failed to instantiate scene: %s" % scene_path)
		root.add_child(inst)

		# Let layout pass compute sizes
		if inst is Control:
			_force_layout_recursive(inst)
			if not _check_bounds_recursive(inst, scene_path, false):
				root.remove_child(inst)
				inst.free()
				return false
		else:
			var hud := inst.get_node_or_null("HUDLayer/MatchHUD") as Control
			if hud != null:
				_force_layout_recursive(hud)
				if not _check_bounds_recursive(hud, scene_path, false):
					root.remove_child(inst)
					inst.free()
					return false

		if scene_path == "res://scenes/Main.tscn":
			if inst.get_active_screen_id() != 0:
				root.remove_child(inst)
				inst.free()
				return _fail("Main.tscn should route to ConnectScreen (0) when disconnected")

		root.remove_child(inst)
		inst.free()

	root.remove_child(audio)
	audio.free()
	root.remove_child(client)
	client.free()
	RetroUI._cached_theme = null
	RetroUI._cached_bunny_sheet = null
	print("[test_phase4_client] PASS: InputMap, SpacetimeWire, AudioManager, and all 6 scenes passed 400x256 bounds smoke checks.")
	return true


func _force_layout_recursive(node: Node) -> void:
	if node is Container:
		(node as Container).queue_sort()
	for child in node.get_children():
		_force_layout_recursive(child)


func _check_bounds_recursive(ctrl: Control, scene_path: String, inside_scroll: bool) -> bool:
	if not ctrl.visible:
		return true
	if not inside_scroll:
		var rect := ctrl.get_rect()
		if rect.size.x > 0.0 and rect.size.y > 0.0:
			var gpos := ctrl.global_position
			var grect := Rect2(gpos, rect.size)
			if grect.position.x < -1.0 or grect.position.y < -1.0 \
					or grect.end.x > VIEWPORT_BOUNDS.end.x + 1.0 \
					or grect.end.y > VIEWPORT_BOUNDS.end.y + 1.0:
				return _fail("Control %s in %s overflows 400x256: %s" % [
					ctrl.get_path(), scene_path, str(grect)
				])
	var next_scroll := inside_scroll or (ctrl is ScrollContainer)
	for child in ctrl.get_children():
		if child is Control:
			if not _check_bounds_recursive(child as Control, scene_path, next_scroll):
				return false
	return true


# ---------------------------------------------------------------------------
# E2E Host & Guest State Machines
# ---------------------------------------------------------------------------

func _start_host() -> void:
	_host_client = SpacetimeClientScript.new()
	_host_state = {
		"step": "connecting",
		"room_id": 0,
		"code": "",
		"kills_seen": 0,
		"seq": 1,
		"last_bits": -1,
	}
	_host_client.connected_and_ready.connect(func() -> void:
		_host_state["step"] = "create_room"
		_host_client.create_room("Phase4 Meadow", true)
	)
	_host_client.kill_event_received.connect(func(ev: Dictionary) -> void:
		if int(ev.get("room_id", 0)) == int(_host_state["room_id"]):
			_host_state["kills_seen"] = int(_host_state["kills_seen"]) + 1
	)
	_host_client.reducer_error.connect(func(rname: String, err: String, _rid: int) -> void:
		_fail("Host reducer %s failed: %s" % [rname, err])
	)
	_host_client.connection_lost.connect(func(reason: String) -> void:
		if _host_state.get("step") != "done":
			_fail("Host lost connection: %s" % reason)
	)
	var err: Error = _host_client.connect_to_server(_ws_url, "GodotHost")
	if err != OK:
		_fail("Host connect_to_server failed: %s" % error_string(err))


func _start_guest() -> void:
	_guest_client = SpacetimeClientScript.new()
	_guest_state = {
		"step": "connecting",
		"room_id": 0,
		"kills_seen": 0,
		"seq": 1,
		"last_bits": -1,
	}
	_guest_client.connected_and_ready.connect(func() -> void:
		_guest_state["step"] = "wait_code"
	)
	_guest_client.kill_event_received.connect(func(ev: Dictionary) -> void:
		if int(ev.get("room_id", 0)) == int(_guest_state["room_id"]):
			_guest_state["kills_seen"] = int(_guest_state["kills_seen"]) + 1
	)
	_guest_client.reducer_error.connect(func(rname: String, err: String, _rid: int) -> void:
		_fail("Guest reducer %s failed: %s" % [rname, err])
	)
	_guest_client.connection_lost.connect(func(reason: String) -> void:
		if _guest_state.get("step") != "done":
			_fail("Guest lost connection: %s" % reason)
	)
	var err: Error = _guest_client.connect_to_server(_ws_url, "GodotGuest")
	if err != OK:
		_fail("Guest connect_to_server failed: %s" % error_string(err))


func _step_host() -> void:
	var step: String = _host_state["step"]
	var room: Dictionary = _host_client.get_my_room()
	match step:
		"create_room":
			if not room.is_empty():
				var rid := int(room.get("id", 0))
				var code := str(room.get("code", ""))
				_host_state["room_id"] = rid
				_host_state["code"] = code
				_host_state["ready_for_guest"] = false
				# Host claims slot 1 (spawns at x=97, y=194) and sets Kill Limit = 1.
				_host_client.select_bunny_slot(1)
				_host_client.update_room_settings(0, 1, false, false, false, true)
				_host_state["step"] = "configure_lobby"
		"configure_lobby":
			if room.is_empty():
				return
			var me: Dictionary = _host_client.get_my_room_member()
			if int(me.get("slot", -1)) == 1 and int(room.get("win_target", 0)) == 1:
				if not _code_file.is_empty():
					var f := FileAccess.open(_code_file, FileAccess.WRITE)
					if f != null:
						f.store_string(str(_host_state["code"]))
						f.close()
				_host_state["ready_for_guest"] = true
				_host_state["step"] = "wait_lobby"
		"wait_lobby":
			if room.is_empty():
				return
			var rid := int(_host_state["room_id"])
			var members: Array = _host_client.get_room_members(rid)
			if members.size() == 2:
				var all_ready := true
				for m in members:
					if not bool(m.get("ready", false)):
						all_ready = false
				if all_ready:
					_host_client.start_match()
					_host_state["step"] = "wait_in_progress"
		"wait_in_progress":
			if int(room.get("status", 0)) == _host_client.STATUS_IN_PROGRESS:
				_host_state["step"] = "playing"
		"playing":
			if int(room.get("status", 0)) == _host_client.STATUS_FINISHED:
				if int(_host_state["kills_seen"]) < 1:
					_fail("Host did not receive KillEvent before Finished")
					return
				_host_state["finished_ms"] = Time.get_ticks_msec()
				_host_state["step"] = "post_finish_wait"
				return
			var rid := int(_host_state["room_id"])
			var bunnies: Array = _host_client.get_room_bunnies(rid)
			if not _all_invuln_expired(bunnies):
				return
			var my_bunny := _find_bunny(bunnies, _host_client.my_identity())
			if my_bunny.is_empty():
				return
			var bx := float(my_bunny.get("x", 0.0))
			var bits := 0
			if bx < 152.0:
				bits = _host_client.INPUT_RIGHT
			elif bx > 158.0:
				bits = _host_client.INPUT_LEFT
			if bits != int(_host_state["last_bits"]):
				_host_state["last_bits"] = bits
				_host_client.send_input(bits, int(_host_state["seq"]))
				_host_state["seq"] = int(_host_state["seq"]) + 1
		"post_finish_wait":
			if Time.get_ticks_msec() - int(_host_state.get("finished_ms", 0)) >= 300:
				_host_client.return_to_lobby()
				_host_state["step"] = "wait_return_lobby"
		"wait_return_lobby":
			if int(room.get("status", -1)) == _host_client.STATUS_WAITING:
				var members: Array = _host_client.get_room_members(int(_host_state["room_id"]))
				for m in members:
					if int(m.get("kills", 0)) != 0 or int(m.get("deaths", 0)) != 0:
						_fail("Stats were not reset on return_to_lobby")
						return
				_host_state["step"] = "done"


func _step_guest() -> void:
	var step: String = _guest_state["step"]
	var room: Dictionary = _guest_client.get_my_room()
	match step:
		"wait_code":
			var code := ""
			if _mode == "e2e":
				if bool(_host_state.get("ready_for_guest", false)):
					code = str(_host_state.get("code", ""))
			elif not _code_file.is_empty() and FileAccess.file_exists(_code_file):
				var f := FileAccess.open(_code_file, FileAccess.READ)
				if f != null:
					code = f.get_as_text().strip_edges()
					f.close()
			if code.length() == 5:
				_guest_client.join_room_by_code(code)
				_guest_state["step"] = "joining"
		"joining":
			if not room.is_empty():
				_guest_state["room_id"] = int(room.get("id", 0))
				# Guest claims slot 2 (spawns at x=33, y=82 on upper ledge above pond) and readies up.
				_guest_client.select_bunny_slot(2)
				_guest_client.toggle_ready()
				_guest_state["step"] = "wait_in_progress"
		"wait_in_progress":
			if int(room.get("status", 0)) == _guest_client.STATUS_IN_PROGRESS:
				_guest_state["step"] = "playing"
		"playing":
			var st := int(room.get("status", 0))
			if st == _guest_client.STATUS_FINISHED:
				if int(_guest_state["kills_seen"]) < 1:
					_fail("Guest did not receive KillEvent before Finished")
					return
				_guest_state["step"] = "wait_return_lobby"
				return
			if st == _guest_client.STATUS_WAITING and int(_guest_state["kills_seen"]) >= 1:
				_guest_state["step"] = "done"
				return
			var rid := int(_guest_state["room_id"])
			var bunnies: Array = _guest_client.get_room_bunnies(rid)
			if not _all_invuln_expired(bunnies):
				return
			var my_bunny := _find_bunny(bunnies, _guest_client.my_identity())
			var other_bunny := _find_other_bunny(bunnies, _guest_client.my_identity())
			if my_bunny.is_empty() or other_bunny.is_empty():
				return
			var dx := float(other_bunny.get("x", 155.0)) - float(my_bunny.get("x", 0.0))
			var bits := 0
			if dx > 2.0:
				bits = _guest_client.INPUT_RIGHT
			elif dx < -2.0:
				bits = _guest_client.INPUT_LEFT
			if bits != int(_guest_state["last_bits"]):
				_guest_state["last_bits"] = bits
				_guest_client.send_input(bits, int(_guest_state["seq"]))
				_guest_state["seq"] = int(_guest_state["seq"]) + 1
		"wait_return_lobby":
			if int(room.get("status", -1)) == _guest_client.STATUS_WAITING:
				_guest_state["step"] = "done"


func _all_invuln_expired(bunnies: Array) -> bool:
	if bunnies.size() < 2:
		return false
	for b in bunnies:
		if int(b.get("invuln_ticks", 0)) > 0:
			return false
	return true


func _find_bunny(bunnies: Array, target_id: String) -> Dictionary:
	for b in bunnies:
		if str(b.get("identity", "")) == target_id:
			return b
	return {}


func _find_other_bunny(bunnies: Array, my_id: String) -> Dictionary:
	for b in bunnies:
		if str(b.get("identity", "")) != my_id:
			return b
	return {}


func _cleanup_clients() -> void:
	if _host_client != null:
		_host_client.disconnect_from_server()
		_host_client.free()
		_host_client = null
	if _guest_client != null:
		_guest_client.disconnect_from_server()
		_guest_client.free()
		_guest_client = null


func _fail(reason: String) -> bool:
	printerr("[test_phase4_client] FAIL: %s" % reason)
	_cleanup_clients()
	_done = true
	quit(1)
	return false
