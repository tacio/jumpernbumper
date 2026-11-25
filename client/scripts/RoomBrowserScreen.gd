extends Control

## Room browser screen with Join-by-Code, Create Room controls, and live Public Waiting Rooms list.

@onready var _player_label: Label = $MainPanel/VBox/HeaderBar/PlayerLabel
@onready var _disconnect_btn: Button = $MainPanel/VBox/HeaderBar/DisconnectButton

@onready var _code_input: LineEdit = $MainPanel/VBox/JoinCodeBar/CodeInput
@onready var _join_code_btn: Button = $MainPanel/VBox/JoinCodeBar/JoinCodeButton
@onready var _status_label: Label = $MainPanel/VBox/JoinCodeBar/StatusLabel

@onready var _room_name_input: LineEdit = $MainPanel/VBox/CreateBar/RoomNameInput
@onready var _public_check: CheckBox = $MainPanel/VBox/CreateBar/PublicCheck
@onready var _create_btn: Button = $MainPanel/VBox/CreateBar/CreateButton

@onready var _rooms_header: Label = $MainPanel/VBox/RoomsHeader
@onready var _room_list_vbox: VBoxContainer = $MainPanel/VBox/RoomsScroll/RoomListVBox
@onready var _empty_label: Label = $MainPanel/VBox/RoomsScroll/RoomListVBox/EmptyLabel


func _ready() -> void:
	theme = RetroUI.get_theme()
	_player_label.add_theme_font_size_override("font_size", 9)
	_player_label.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	_status_label.add_theme_color_override("font_color", Color(0.96, 0.45, 0.45, 1.0))
	_disconnect_btn.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.55, 0.18, 0.18, 1.0)))

	_disconnect_btn.pressed.connect(_on_disconnect_pressed)
	_join_code_btn.pressed.connect(_on_join_code_pressed)
	_create_btn.pressed.connect(_on_create_pressed)
	_code_input.text_changed.connect(_on_code_text_changed)
	_code_input.text_submitted.connect(func(_t: String) -> void: _on_join_code_pressed())
	_room_name_input.text_submitted.connect(func(_t: String) -> void: _on_create_pressed())

	var client := RetroUI.get_client(self)
	if client != null:
		client.state_updated.connect(refresh)
		client.reducer_error.connect(_on_reducer_error)
	refresh()
	_create_btn.call_deferred("grab_focus")


func show_error(msg: String) -> void:
	_status_label.text = msg


func refresh() -> void:
	var client := RetroUI.get_client(self)
	if client == null:
		_player_label.text = "PLAYER: Offline"
		_rooms_header.text = "PUBLIC WAITING ROOMS (0)"
		return

	var me: Dictionary = client.get_my_player()
	var nick := str(me.get("nickname", "Bunny"))
	_player_label.text = "PLAYER: %s" % nick

	if _room_name_input.text.is_empty():
		_room_name_input.placeholder_text = "%s's Meadow" % nick

	for child in _room_list_vbox.get_children():
		if child != _empty_label:
			child.queue_free()

	var rooms: Array = client.get_public_waiting_rooms()
	_rooms_header.text = "PUBLIC WAITING ROOMS (%d)" % rooms.size()
	_empty_label.visible = rooms.is_empty()

	for r in rooms:
		var room: Dictionary = r
		var room_id := int(room.get("id", 0))
		var members: Array = client.get_room_members(room_id)
		var count := members.size()

		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", RetroUI.make_card_style())
		card.custom_minimum_size = Vector2(0, 22)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		card.add_child(row)

		var name_lbl := Label.new()
		name_lbl.text = str(room.get("name", "Room"))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.clip_text = true
		row.add_child(name_lbl)

		var code_lbl := Label.new()
		code_lbl.text = "[%s]" % str(room.get("code", "?????"))
		code_lbl.add_theme_color_override("font_color", Color(0.62, 0.88, 0.98, 1.0))
		row.add_child(code_lbl)

		var rule_lbl := Label.new()
		var win_mode := int(room.get("win_mode", 0))
		var win_target := int(room.get("win_target", 10))
		rule_lbl.text = "%dK" % win_target if win_mode == 0 else "%ds" % win_target
		rule_lbl.add_theme_color_override("font_color", Color(0.80, 0.85, 0.90, 1.0))
		row.add_child(rule_lbl)

		var count_lbl := Label.new()
		count_lbl.text = "%d/4" % count
		count_lbl.add_theme_color_override(
			"font_color",
			Color(0.98, 0.84, 0.28, 1.0) if count < 4 else Color(0.95, 0.45, 0.45, 1.0)
		)
		row.add_child(count_lbl)

		var join_btn := Button.new()
		join_btn.text = "FULL" if count >= 4 else "JOIN"
		join_btn.custom_minimum_size = Vector2(44, 16)
		join_btn.disabled = count >= 4
		join_btn.pressed.connect(func() -> void: _on_join_public(room_id))
		row.add_child(join_btn)

		_room_list_vbox.add_child(card)


func _on_code_text_changed(new_text: String) -> void:
	var upper := new_text.to_upper()
	if upper != new_text:
		var col := _code_input.caret_column
		_code_input.text = upper
		_code_input.caret_column = mini(col, upper.length())


func _on_join_code_pressed() -> void:
	var code := _code_input.text.strip_edges().to_upper()
	if code.length() != 5:
		show_error("Code must be 5 chars")
		return
	var client := RetroUI.get_client(self)
	if client == null:
		return
	_status_label.text = ""
	client.join_room_by_code(code)


func _on_join_public(room_id: int) -> void:
	var client := RetroUI.get_client(self)
	if client == null:
		return
	_status_label.text = ""
	client.join_public_room(room_id)


func _on_create_pressed() -> void:
	var rname := _room_name_input.text.strip_edges()
	if rname.is_empty():
		rname = "Meadow Brawl"
	if rname.length() > 32:
		show_error("Max 32 chars")
		return
	var client := RetroUI.get_client(self)
	if client == null:
		return
	_status_label.text = ""
	client.create_room(rname, _public_check.button_pressed)


func _on_disconnect_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.disconnect_from_server()


func _on_reducer_error(_reducer_name: String, error_message: String, _req_id: int) -> void:
	show_error(error_message)
