extends Control

## Connection screen allowing nickname entry, SpacetimeDB WS URL config, and connect.

const DEFAULT_WS_URL := "ws://127.0.0.1:3000/v1/database/jumpernbumper/subscribe"

@onready var _title_label: Label = $CenterPanel/VBox/TitleLabel
@onready var _subtitle_label: Label = $CenterPanel/VBox/SubtitleLabel
@onready var _bunny_preview_row: HBoxContainer = $CenterPanel/VBox/BunnyPreviewRow
@onready var _nickname_input: LineEdit = $CenterPanel/VBox/NickRow/NicknameInput
@onready var _url_input: LineEdit = $CenterPanel/VBox/UrlRow/UrlInput
@onready var _connect_button: Button = $CenterPanel/VBox/ConnectButton
@onready var _error_label: Label = $CenterPanel/VBox/ErrorLabel

var _anim_timer: float = 0.0
var _anim_frame_idx: int = 0
var _preview_icons: Array[TextureRect] = []


func _ready() -> void:
	theme = RetroUI.get_theme()
	_title_label.add_theme_font_size_override("font_size", 14)
	_title_label.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	_subtitle_label.add_theme_color_override("font_color", Color(0.75, 0.87, 0.96, 1.0))
	_error_label.add_theme_color_override("font_color", Color(0.96, 0.42, 0.42, 1.0))

	if _nickname_input.text.is_empty():
		_nickname_input.text = "Bunny%02d" % (randi() % 90 + 10)
	if _url_input.text.is_empty():
		_url_input.text = DEFAULT_WS_URL

	_setup_bunny_previews()

	_connect_button.pressed.connect(_on_connect_pressed)
	_nickname_input.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())
	_url_input.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())

	var client := RetroUI.get_client(self)
	if client != null:
		client.connection_lost.connect(_on_connection_lost)
		client.connected_and_ready.connect(_on_connected_and_ready)
		client.reducer_error.connect(_on_reducer_error)
		_refresh_connecting_state(client)


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
