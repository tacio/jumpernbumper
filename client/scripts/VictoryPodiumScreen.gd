extends Control

## Match victory podium screen showing winner banner, ranked kills/deaths table,
## and Host Return-to-Lobby / Leave Room controls.

@onready var _winner_icon: TextureRect = $CenterPanel/VBox/WinnerRow/WinnerIcon
@onready var _winner_label: Label = $CenterPanel/VBox/WinnerRow/WinnerLabel
@onready var _sub_label: Label = $CenterPanel/VBox/SubLabel
@onready var _standings_vbox: VBoxContainer = $CenterPanel/VBox/StandingsPanel/StandingsVBox
@onready var _return_btn: Button = $CenterPanel/VBox/ButtonRow/ReturnLobbyButton
@onready var _leave_btn: Button = $CenterPanel/VBox/ButtonRow/LeaveRoomButton


func _ready() -> void:
	theme = RetroUI.get_theme()
	_winner_label.add_theme_font_size_override("font_size", 11)
	_winner_label.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	_leave_btn.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.55, 0.18, 0.18, 1.0)))

	_return_btn.pressed.connect(_on_return_pressed)
	_leave_btn.pressed.connect(_on_leave_pressed)

	var audio := RetroUI.get_audio(self)
	if audio != null:
		audio.play_sfx("victory", -2.0)

	var client := RetroUI.get_client(self)
	if client != null:
		client.state_updated.connect(refresh)
	refresh()


func refresh() -> void:
	var client := RetroUI.get_client(self)
	if client == null:
		return
	var room: Dictionary = client.get_my_room()
	if room.is_empty():
		return

	var room_id := int(room.get("id", 0))
	var winner_slot := int(room.get("winner_slot", -1))
	var members: Array = client.get_room_members(room_id)
	var is_host: bool = client.is_host()

	members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak := int(a.get("kills", 0))
		var bk := int(b.get("kills", 0))
		if ak != bk:
			return ak > bk
		var ad := int(a.get("deaths", 0))
		var bd := int(b.get("deaths", 0))
		if ad != bd:
			return ad < bd
		return int(a.get("slot", 0)) < int(b.get("slot", 0))
	)

	if winner_slot >= 0 and winner_slot <= 3:
		_winner_icon.visible = true
		var winner_is_bot := false
		var wname := RetroUI.BUNNY_NAMES[winner_slot]
		for m in members:
			if int(m.get("slot", -1)) == winner_slot:
				wname = "%s (%s)" % [str(m.get("nickname", wname)), wname]
				winner_is_bot = bool(m.get("is_bot", false))
				break
		_winner_icon.texture = RetroUI.make_bunny_atlas(winner_slot, 5, winner_is_bot)
		_winner_label.text = "WINNER: %s" % wname
	else:
		_winner_icon.visible = false
		_winner_label.text = "MATCH DRAW!"

	var elapsed_s := int(floor(float(room.get("elapsed_ms", 0)) / 1000.0))
	_sub_label.text = "Room: %s  |  Duration: %ds" % [str(room.get("name", "Meadow")), elapsed_s]

	for child in _standings_vbox.get_children():
		child.queue_free()

	var header := _make_row("#", -1, "PLAYER", "K", "D", Color(0.75, 0.85, 0.95, 1.0))
	_standings_vbox.add_child(header)

	for i in range(members.size()):
		var md: Dictionary = members[i]
		var slot := clampi(int(md.get("slot", 0)), 0, 3)
		var row := _make_row(
			"%d" % (i + 1),
			slot,
			str(md.get("nickname", RetroUI.BUNNY_NAMES[slot])),
			str(int(md.get("kills", 0))),
			str(int(md.get("deaths", 0))),
			RetroUI.BUNNY_COLORS[slot],
			bool(md.get("is_bot", false))
		)
		_standings_vbox.add_child(row)

	if is_host:
		_return_btn.disabled = false
		_return_btn.text = "RETURN TO LOBBY"
		_return_btn.call_deferred("grab_focus")
	else:
		_return_btn.disabled = true
		_return_btn.text = "WAIT FOR HOST"
		_leave_btn.call_deferred("grab_focus")


func _make_row(rank: String, slot: int, pname: String, kills: String, deaths: String, color: Color, is_bot: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var r_lbl := Label.new()
	r_lbl.custom_minimum_size = Vector2(18, 0)
	r_lbl.text = rank
	r_lbl.add_theme_color_override("font_color", color)
	row.add_child(r_lbl)

	if slot >= 0:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(14, 14)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = RetroUI.make_bunny_atlas(slot, 0, is_bot)
		row.add_child(icon)
	else:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(14, 14)
		row.add_child(spacer)

	var n_lbl := Label.new()
	n_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n_lbl.text = pname
	n_lbl.clip_text = true
	n_lbl.add_theme_color_override("font_color", color)
	row.add_child(n_lbl)

	var k_lbl := Label.new()
	k_lbl.custom_minimum_size = Vector2(28, 0)
	k_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	k_lbl.text = kills
	k_lbl.add_theme_color_override("font_color", color)
	row.add_child(k_lbl)

	var d_lbl := Label.new()
	d_lbl.custom_minimum_size = Vector2(28, 0)
	d_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	d_lbl.text = deaths
	d_lbl.add_theme_color_override("font_color", color)
	row.add_child(d_lbl)

	return row


func _on_return_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.return_to_lobby()


func _on_leave_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.leave_room()
