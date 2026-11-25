extends Node

## Manages customizable keyboard and joypad bindings, persists them to
## `user://settings.cfg`, and ensures joypad menu navigation works across all screens.

const SETTINGS_PATH := "user://settings.cfg"
const JOYPAD_DEADZONE := 0.25

const ACTIONS: Array[String] = ["move_left", "move_right", "jump", "pause_menu"]
const ACTION_LABELS: Dictionary = {
	"move_left": "Move Left",
	"move_right": "Move Right",
	"jump": "Jump",
	"pause_menu": "Pause Menu",
}

signal bindings_changed

# action -> { "key": InputEventKey, "joy": InputEvent (JoypadButton or JoypadMotion) }
var _bindings: Dictionary = {}


func _ready() -> void:
	_init_defaults()
	load_settings()
	apply_to_input_map()
	_ensure_ui_joypad_navigation()


func get_keyboard_event(action: String) -> InputEvent:
	var entry: Dictionary = _bindings.get(action, {})
	return entry.get("key", null) as InputEvent


func get_joypad_event(action: String) -> InputEvent:
	var entry: Dictionary = _bindings.get(action, {})
	return entry.get("joy", null) as InputEvent


func set_keyboard_binding(action: String, event: InputEventKey) -> void:
	if not _bindings.has(action) or event == null:
		return
	var copy := event.duplicate() as InputEventKey
	copy.pressed = false
	copy.echo = false
	_bindings[action]["key"] = copy
	apply_to_input_map()
	save_settings()
	bindings_changed.emit()


func set_joypad_binding(action: String, event: InputEvent) -> void:
	if not _bindings.has(action) or event == null:
		return
	if event is InputEventJoypadButton:
		var jb := (event as InputEventJoypadButton).duplicate() as InputEventJoypadButton
		jb.pressed = false
		jb.device = -1
		_bindings[action]["joy"] = jb
	elif event is InputEventJoypadMotion:
		var jm := InputEventJoypadMotion.new()
		jm.device = -1
		jm.axis = (event as InputEventJoypadMotion).axis
		jm.axis_value = 1.0 if (event as InputEventJoypadMotion).axis_value >= 0.0 else -1.0
		_bindings[action]["joy"] = jm
	else:
		return
	apply_to_input_map()
	save_settings()
	bindings_changed.emit()


func reset_to_defaults() -> void:
	_init_defaults()
	apply_to_input_map()
	save_settings()
	bindings_changed.emit()


func apply_to_input_map() -> void:
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, JOYPAD_DEADZONE)
		else:
			InputMap.action_set_deadzone(action, JOYPAD_DEADZONE)
		InputMap.action_erase_events(action)

		var entry: Dictionary = _bindings.get(action, {})
		var key_ev := entry.get("key", null) as InputEvent
		if key_ev != null:
			InputMap.action_add_event(action, key_ev)
		# Keep secondary arrow keys for convenience when default WASD is active.
		var alt_key := entry.get("alt_key", null) as InputEvent
		if alt_key != null and key_ev is InputEventKey and _is_default_key(action, key_ev as InputEventKey):
			InputMap.action_add_event(action, alt_key)

		var joy_ev := entry.get("joy", null) as InputEvent
		if joy_ev != null:
			InputMap.action_add_event(action, joy_ev)
		var alt_joy := entry.get("alt_joy", null) as InputEvent
		if alt_joy != null:
			InputMap.action_add_event(action, alt_joy)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for action in ACTIONS:
		var entry: Dictionary = _bindings.get(action, {})
		var key_ev := entry.get("key", null) as InputEventKey
		if key_ev != null:
			cfg.set_value("controls_key", action, int(key_ev.keycode))
		var joy_ev := entry.get("joy", null) as InputEvent
		if joy_ev is InputEventJoypadButton:
			cfg.set_value("controls_joy", action, {
				"type": "button",
				"button_index": int((joy_ev as InputEventJoypadButton).button_index),
			})
		elif joy_ev is InputEventJoypadMotion:
			cfg.set_value("controls_joy", action, {
				"type": "motion",
				"axis": int((joy_ev as InputEventJoypadMotion).axis),
				"axis_value": float((joy_ev as InputEventJoypadMotion).axis_value),
			})
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for action in ACTIONS:
		if cfg.has_section_key("controls_key", action):
			var kc := int(cfg.get_value("controls_key", action, 0))
			if kc > 0:
				_bindings[action]["key"] = _make_key(kc)
		if cfg.has_section_key("controls_joy", action):
			var raw: Variant = cfg.get_value("controls_joy", action, {})
			if typeof(raw) == TYPE_DICTIONARY:
				var d: Dictionary = raw
				var t := str(d.get("type", ""))
				if t == "button":
					_bindings[action]["joy"] = _make_joy_button(int(d.get("button_index", 0)))
				elif t == "motion":
					_bindings[action]["joy"] = _make_joy_motion(
						int(d.get("axis", 0)),
						float(d.get("axis_value", 1.0))
					)


static func format_event(event: InputEvent) -> String:
	if event == null:
		return "UNBOUND"
	if event is InputEventKey:
		var kc := (event as InputEventKey).keycode
		var label := OS.get_keycode_string(kc)
		return label.to_upper() if not label.is_empty() else "KEY %d" % int(kc)
	if event is InputEventJoypadButton:
		var idx := int((event as InputEventJoypadButton).button_index)
		match idx:
			JOY_BUTTON_A:
				return "BTN A / X"
			JOY_BUTTON_B:
				return "BTN B / O"
			JOY_BUTTON_X:
				return "BTN X / SQ"
			JOY_BUTTON_Y:
				return "BTN Y / TRI"
			JOY_BUTTON_BACK:
				return "SELECT"
			JOY_BUTTON_START:
				return "START"
			JOY_BUTTON_LEFT_SHOULDER:
				return "LB / L1"
			JOY_BUTTON_RIGHT_SHOULDER:
				return "RB / R1"
			JOY_BUTTON_DPAD_UP:
				return "D-PAD UP"
			JOY_BUTTON_DPAD_DOWN:
				return "D-PAD DOWN"
			JOY_BUTTON_DPAD_LEFT:
				return "D-PAD LEFT"
			JOY_BUTTON_DPAD_RIGHT:
				return "D-PAD RIGHT"
			_:
				return "JOY BTN %d" % idx
	if event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		var sign_str := "+" if jm.axis_value >= 0.0 else "-"
		match int(jm.axis):
			JOY_AXIS_LEFT_X:
				return "L-STICK RIGHT" if jm.axis_value >= 0.0 else "L-STICK LEFT"
			JOY_AXIS_LEFT_Y:
				return "L-STICK DOWN" if jm.axis_value >= 0.0 else "L-STICK UP"
			JOY_AXIS_RIGHT_X:
				return "R-STICK RIGHT" if jm.axis_value >= 0.0 else "R-STICK LEFT"
			JOY_AXIS_RIGHT_Y:
				return "R-STICK DOWN" if jm.axis_value >= 0.0 else "R-STICK UP"
			JOY_AXIS_TRIGGER_LEFT:
				return "LT / L2"
			JOY_AXIS_TRIGGER_RIGHT:
				return "RT / R2"
			_:
				return "AXIS %d%s" % [int(jm.axis), sign_str]
	return "INPUT"


func _init_defaults() -> void:
	_bindings = {
		"move_left": {
			"key": _make_key(KEY_A),
			"alt_key": _make_key(KEY_LEFT),
			"joy": _make_joy_button(JOY_BUTTON_DPAD_LEFT),
			"alt_joy": _make_joy_motion(JOY_AXIS_LEFT_X, -1.0),
		},
		"move_right": {
			"key": _make_key(KEY_D),
			"alt_key": _make_key(KEY_RIGHT),
			"joy": _make_joy_button(JOY_BUTTON_DPAD_RIGHT),
			"alt_joy": _make_joy_motion(JOY_AXIS_LEFT_X, 1.0),
		},
		"jump": {
			"key": _make_key(KEY_W),
			"alt_key": _make_key(KEY_SPACE),
			"joy": _make_joy_button(JOY_BUTTON_A),
			"alt_joy": null,
		},
		"pause_menu": {
			"key": _make_key(KEY_ESCAPE),
			"alt_key": null,
			"joy": _make_joy_button(JOY_BUTTON_START),
			"alt_joy": null,
		},
	}


func _is_default_key(action: String, key_ev: InputEventKey) -> bool:
	match action:
		"move_left":
			return key_ev.keycode == KEY_A
		"move_right":
			return key_ev.keycode == KEY_D
		"jump":
			return key_ev.keycode == KEY_W
		_:
			return false


func _ensure_ui_joypad_navigation() -> void:
	_add_unique_event("ui_left", _make_joy_button(JOY_BUTTON_DPAD_LEFT))
	_add_unique_event("ui_left", _make_joy_motion(JOY_AXIS_LEFT_X, -1.0))
	_add_unique_event("ui_right", _make_joy_button(JOY_BUTTON_DPAD_RIGHT))
	_add_unique_event("ui_right", _make_joy_motion(JOY_AXIS_LEFT_X, 1.0))
	_add_unique_event("ui_up", _make_joy_button(JOY_BUTTON_DPAD_UP))
	_add_unique_event("ui_up", _make_joy_motion(JOY_AXIS_LEFT_Y, -1.0))
	_add_unique_event("ui_down", _make_joy_button(JOY_BUTTON_DPAD_DOWN))
	_add_unique_event("ui_down", _make_joy_motion(JOY_AXIS_LEFT_Y, 1.0))
	_add_unique_event("ui_accept", _make_joy_button(JOY_BUTTON_A))
	_add_unique_event("ui_cancel", _make_joy_button(JOY_BUTTON_B))


func _add_unique_event(action: String, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		return
	for existing in InputMap.action_get_events(action):
		if existing.is_match(event):
			return
	InputMap.action_add_event(action, event)


static func _make_key(kc: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = kc as Key
	ev.device = -1
	return ev


static func _make_joy_button(btn: int) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = btn as JoyButton
	ev.device = -1
	return ev


static func _make_joy_motion(axis: int, axis_val: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis as JoyAxis
	ev.axis_value = axis_val
	ev.device = -1
	return ev
