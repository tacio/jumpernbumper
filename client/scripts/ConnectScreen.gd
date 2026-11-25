extends Control

## Connection screen allowing nickname entry, SpacetimeDB WS URL config, and connect.

const DEFAULT_WS_URL := "ws://127.0.0.1:3000/v1/database/jumpernbumper/subscribe"

@onready var _title_label: Label = $CenterPanel/VBox/TitleLabel
@onready var _subtitle_label: Label = $CenterPanel/VBox/SubtitleLabel
@onready var _bunny_preview_row: HBoxContainer = $CenterPanel/VBox/BunnyPreviewRow
@onready var _nickname_input: LineEdit = $CenterPanel/VBox/NickRow/NicknameInput
@onready var _url_input: LineEdit = $CenterPanel/VBox/UrlRow/UrlInput
@onready var _connect_button: Button = $CenterPanel/VBox/ButtonRow/ConnectButton
@onready var _controls_button: Button = $CenterPanel/VBox/ButtonRow/ControlsButton
@onready var _error_label: Label = $CenterPanel/VBox/ErrorLabel

var _anim_timer: float = 0.0
var _anim_frame_idx: int = 0
var _preview_icons: Array[TextureRect] = []

var _controls_overlay: ColorRect
var _controls_status_lbl: Label
var _controls_close_btn: Button
var _binding_buttons: Dictionary = {} # action -> { "key": Button, "joy": Button }
var _listening_action: String = ""
var _listening_mode: String = "" # "key" or "joy"


func _ready() -> void:
	theme = RetroUI.get_theme()
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	_subtitle_label.add_theme_color_override("font_color", Color(0.78, 0.90, 0.98, 1.0))
	_error_label.add_theme_color_override("font_color", Color(0.96, 0.42, 0.42, 1.0))
	_controls_button.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.22, 0.34, 0.48, 1.0)))

	if _nickname_input.text.is_empty():
		_nickname_input.text = "Bunny%02d" % (randi() % 90 + 10)
	if _url_input.text.is_empty():
		_url_input.text = DEFAULT_WS_URL

	_setup_bunny_previews()
	_build_controls_overlay()

	_connect_button.pressed.connect(_on_connect_pressed)
	_controls_button.pressed.connect(_open_controls_overlay)
	_nickname_input.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())
	_url_input.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())

	var client := RetroUI.get_client(self)
	if client != null:
		client.connection_lost.connect(_on_connection_lost)
		client.connected_and_ready.connect(_on_connected_and_ready)
		client.reducer_error.connect(_on_reducer_error)
		_refresh_connecting_state(client)

	_connect_button.call_deferred("grab_focus")


func _process(delta: float) -> void:
	_anim_timer += delta
	if _anim_timer >= 0.25:
		_anim_timer -= 0.25
		_anim_frame_idx = (_anim_frame_idx + 1) % 4
		var frames := [0, 2, 3, 4]
		var f: int = frames[_anim_frame_idx]
		for slot in range(_preview_icons.size()):
			var atlas := _preview_icons[slot].texture as AtlasTexture
			if atlas != null:
				atlas.region = Rect2(float(f * 16), float(slot * 16), 16.0, 16.0)


func show_error(message: String) -> void:
	_error_label.text = message
	_connect_button.disabled = false
	_connect_button.text = "CONNECT"


func _setup_bunny_previews() -> void:
	_preview_icons.clear()
	for child in _bunny_preview_row.get_children():
		child.queue_free()
	for slot in range(4):
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(20, 20)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = RetroUI.make_bunny_atlas(slot, 0)
		icon.tooltip_text = RetroUI.BUNNY_NAMES[slot]
		_bunny_preview_row.add_child(icon)
		_preview_icons.append(icon)


func _on_connect_pressed() -> void:
	var nick := _nickname_input.text.strip_edges()
	if nick.length() < 1 or nick.length() > 16:
		show_error("Nickname must be 1 to 16 characters.")
		return

	var url := _url_input.text.strip_edges()
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		show_error("Server URL must start with ws:// or wss://")
		return

	var client := RetroUI.get_client(self)
	if client == null:
		show_error("SpacetimeClient autoload is unavailable.")
		return

	_error_label.text = ""
	_connect_button.disabled = true
	_connect_button.text = "CONNECTING..."
	var err: Error = client.connect_to_server(url, nick)
	if err != OK:
		show_error("Failed to connect: %s" % error_string(err))


func _on_connected_and_ready() -> void:
	_error_label.text = ""
	_connect_button.disabled = false
	_connect_button.text = "CONNECT"


func _on_connection_lost(reason: String) -> void:
	show_error(reason if not reason.is_empty() else "Connection lost.")


func _on_reducer_error(_reducer_name: String, error_message: String, _req_id: int) -> void:
	show_error(error_message)


func _refresh_connecting_state(client: Node) -> void:
	if client.is_connecting():
		_connect_button.disabled = true
		_connect_button.text = "CONNECTING..."
	else:
		_connect_button.disabled = false
		_connect_button.text = "CONNECT"


func _build_controls_overlay() -> void:
	_controls_overlay = ColorRect.new()
	_controls_overlay.name = "ControlsOverlay"
	_controls_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_overlay.color = Color(0.02, 0.04, 0.07, 0.78)
	_controls_overlay.visible = false
	add_child(_controls_overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -168.0
	panel.offset_top = -102.0
	panel.offset_right = 168.0
	panel.offset_bottom = 102.0
	_controls_overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "CONTROLS & JOYPAD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	vbox.add_child(title)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var h_act := Label.new()
	h_act.text = "ACTION"
	h_act.custom_minimum_size = Vector2(88, 0)
	h_act.add_theme_color_override("font_color", Color(0.68, 0.82, 0.94, 1.0))
	header.add_child(h_act)

	var h_key := Label.new()
	h_key.text = "KEYBOARD"
	h_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h_key.add_theme_color_override("font_color", Color(0.68, 0.82, 0.94, 1.0))
	header.add_child(h_key)

	var h_joy := Label.new()
	h_joy.text = "JOYPAD"
	h_joy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_joy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h_joy.add_theme_color_override("font_color", Color(0.68, 0.82, 0.94, 1.0))
	header.add_child(h_joy)

	_binding_buttons.clear()
	var input_settings := RetroUI.get_input_settings(self)
	var actions: Array[String] = ["move_left", "move_right", "jump", "pause_menu"]
	var labels: Dictionary = {
		"move_left": "Move Left",
		"move_right": "Move Right",
		"jump": "Jump",
		"pause_menu": "Pause Menu",
	}
	if input_settings != null:
		actions = input_settings.ACTIONS
		labels = input_settings.ACTION_LABELS

	for action in actions:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		vbox.add_child(row)

		var lbl := Label.new()
		lbl.text = str(labels.get(action, action))
		lbl.custom_minimum_size = Vector2(88, 0)
		row.add_child(lbl)

		var key_btn := Button.new()
		key_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key_btn.custom_minimum_size = Vector2(96, 18)
		key_btn.pressed.connect(func() -> void: _start_rebind(action, "key"))
		row.add_child(key_btn)

		var joy_btn := Button.new()
		joy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		joy_btn.custom_minimum_size = Vector2(96, 18)
		joy_btn.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.20, 0.34, 0.48, 1.0)))
		joy_btn.pressed.connect(func() -> void: _start_rebind(action, "joy"))
		row.add_child(joy_btn)

		_binding_buttons[action] = {
			"key": key_btn,
			"joy": joy_btn,
		}

	_controls_status_lbl = Label.new()
	_controls_status_lbl.text = "Click a slot to rebind. Menus also support D-Pad / Stick."
	_controls_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_controls_status_lbl.add_theme_color_override("font_color", Color(0.75, 0.87, 0.96, 1.0))
	vbox.add_child(_controls_status_lbl)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(footer)

	var reset_btn := Button.new()
	reset_btn.text = "RESET DEFAULTS"
	reset_btn.custom_minimum_size = Vector2(110, 19)
	reset_btn.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.55, 0.24, 0.20, 1.0)))
	reset_btn.pressed.connect(_on_reset_controls_pressed)
	footer.add_child(reset_btn)

	_controls_close_btn = Button.new()
	_controls_close_btn.text = "CLOSE"
	_controls_close_btn.custom_minimum_size = Vector2(88, 19)
	_controls_close_btn.pressed.connect(_close_controls_overlay)
	footer.add_child(_controls_close_btn)


func _open_controls_overlay() -> void:
	_listening_action = ""
	_listening_mode = ""
	_refresh_controls_labels()
	_controls_overlay.visible = true
	_controls_close_btn.call_deferred("grab_focus")


func _close_controls_overlay() -> void:
	_listening_action = ""
	_listening_mode = ""
	_controls_overlay.visible = false
	_controls_button.call_deferred("grab_focus")


func _on_reset_controls_pressed() -> void:
	_listening_action = ""
	_listening_mode = ""
	var input_settings := RetroUI.get_input_settings(self)
	if input_settings != null:
		input_settings.reset_to_defaults()
	_refresh_controls_labels()
	_controls_status_lbl.text = "Defaults restored."


func _start_rebind(action: String, mode: String) -> void:
	_listening_action = action
	_listening_mode = mode
	_refresh_controls_labels()
	if mode == "key":
		_controls_status_lbl.text = "Press any KEY to bind (ESC to cancel)..."
	else:
		_controls_status_lbl.text = "Press any JOYPAD button/stick (ESC to cancel)..."


func _refresh_controls_labels() -> void:
	var input_settings := RetroUI.get_input_settings(self)
	for action in _binding_buttons.keys():
		var pair: Dictionary = _binding_buttons[action]
		var key_btn: Button = pair["key"]
		var joy_btn: Button = pair["joy"]
		if _listening_action == action and _listening_mode == "key":
			key_btn.text = "[PRESS KEY]"
		elif input_settings != null:
			key_btn.text = input_settings.format_event(input_settings.get_keyboard_event(action))
		if _listening_action == action and _listening_mode == "joy":
			joy_btn.text = "[PRESS JOY]"
		elif input_settings != null:
			joy_btn.text = input_settings.format_event(input_settings.get_joypad_event(action))


func _input(event: InputEvent) -> void:
	if _controls_overlay == null or not _controls_overlay.visible:
		return

	if _listening_action.is_empty():
		if event.is_action_pressed("ui_cancel"):
			_close_controls_overlay()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var kev := event as InputEventKey
		if kev.keycode == KEY_ESCAPE and _listening_mode != "key":
			_listening_action = ""
			_listening_mode = ""
			_refresh_controls_labels()
			_controls_status_lbl.text = "Rebind cancelled."
			get_viewport().set_input_as_handled()
			return
		if _listening_mode == "key":
			var input_settings := RetroUI.get_input_settings(self)
			if input_settings != null:
				input_settings.set_keyboard_binding(_listening_action, kev)
			_listening_action = ""
			_listening_mode = ""
			_refresh_controls_labels()
			_controls_status_lbl.text = "Keyboard binding saved."
			get_viewport().set_input_as_handled()
		return

	if _listening_mode == "joy":
		if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
			var input_settings := RetroUI.get_input_settings(self)
			if input_settings != null:
				input_settings.set_joypad_binding(_listening_action, event)
			_listening_action = ""
			_listening_mode = ""
			_refresh_controls_labels()
			_controls_status_lbl.text = "Joypad button saved."
			get_viewport().set_input_as_handled()
			return
		if event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) >= 0.6:
			var input_settings := RetroUI.get_input_settings(self)
			if input_settings != null:
				input_settings.set_joypad_binding(_listening_action, event)
			_listening_action = ""
			_listening_mode = ""
			_refresh_controls_labels()
			_controls_status_lbl.text = "Joypad axis saved."
			get_viewport().set_input_as_handled()
			return

