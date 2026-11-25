extends Control

## Multiplayer room lobby screen with 4 classic bunny slots, room code copy,
## host match settings/mutators, ready-up toggle, and match start.

const KILL_PRESETS: Array[int] = [5, 10, 20]
const TIME_PRESETS: Array[int] = [60, 120, 180]

@onready var _room_name_lbl: Label = $MainPanel/VBox/TopBar/RoomNameLabel
@onready var _vis_badge_lbl: Label = $MainPanel/VBox/TopBar/VisBadgeLabel
@onready var _code_lbl: Label = $MainPanel/VBox/TopBar/CodeLabel
@onready var _copy_btn: Button = $MainPanel/VBox/TopBar/CopyCodeButton
@onready var _leave_btn: Button = $MainPanel/VBox/TopBar/LeaveButton

@onready var _slots_row: HBoxContainer = $MainPanel/VBox/SlotsRow

@onready var _win_kills_btn: Button = $MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/WinKillsButton
@onready var _win_time_btn: Button = $MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/WinTimeButton
@onready var _target_minus_btn: Button = $MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/TargetMinusButton
@onready var _target_val_lbl: Label = $MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/TargetValueLabel
@onready var _target_plus_btn: Button = $MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/TargetPlusButton
@onready var _preset_btns: Array[Button] = [
	$MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/Preset0Button,
	$MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/Preset1Button,
	$MainPanel/VBox/SettingsPanel/SettingsVBox/WinRow/Preset2Button,
]

@onready var _low_grav_check: CheckBox = $MainPanel/VBox/SettingsPanel/SettingsVBox/MutatorRow/LowGravCheck
@onready var _pogo_check: CheckBox = $MainPanel/VBox/SettingsPanel/SettingsVBox/MutatorRow/PogoCheck
@onready var _jetpack_check: CheckBox = $MainPanel/VBox/SettingsPanel/SettingsVBox/MutatorRow/JetpackCheck
@onready var _gore_check: CheckBox = $MainPanel/VBox/SettingsPanel/SettingsVBox/MutatorRow/GoreCheck

@onready var _ready_btn: Button = $MainPanel/VBox/FooterBar/ReadyButton
@onready var _ready_summary_lbl: Label = $MainPanel/VBox/FooterBar/ReadySummaryLabel
@onready var _start_btn: Button = $MainPanel/VBox/FooterBar/StartMatchButton

var _slot_cards: Array[Dictionary] = []
var _syncing_ui: bool = false
var _copy_feedback_timer: float = 0.0
var _current_room: Dictionary = {}


func _ready() -> void:
	theme = RetroUI.get_theme()
	_room_name_lbl.add_theme_font_size_override("font_size", 9)
	_room_name_lbl.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
	_code_lbl.add_theme_font_size_override("font_size", 9)
	_code_lbl.add_theme_color_override("font_color", Color(0.55, 0.90, 1.0, 1.0))
	_leave_btn.add_theme_stylebox_override("normal", RetroUI.make_button_style(Color(0.55, 0.18, 0.18, 1.0)))

	_build_slot_cards()

	_copy_btn.pressed.connect(_on_copy_pressed)
	_leave_btn.pressed.connect(_on_leave_pressed)
	_ready_btn.pressed.connect(_on_ready_pressed)
	_start_btn.pressed.connect(_on_start_pressed)

	_win_kills_btn.pressed.connect(func() -> void: _host_set_win_mode(0))
	_win_time_btn.pressed.connect(func() -> void: _host_set_win_mode(1))
	_target_minus_btn.pressed.connect(func() -> void: _host_step_target(-1))
	_target_plus_btn.pressed.connect(func() -> void: _host_step_target(1))

	for idx in range(_preset_btns.size()):
		var p_idx := idx
		_preset_btns[idx].pressed.connect(func() -> void: _host_apply_preset(p_idx))

	_low_grav_check.toggled.connect(func(_v: bool) -> void: _host_push_settings())
	_pogo_check.toggled.connect(func(_v: bool) -> void: _host_push_settings())
	_jetpack_check.toggled.connect(func(_v: bool) -> void: _host_push_settings())
	_gore_check.toggled.connect(func(_v: bool) -> void: _host_push_settings())

	var client := RetroUI.get_client(self)
	if client != null:
		client.state_updated.connect(refresh)
	refresh()


func _process(delta: float) -> void:
	if _copy_feedback_timer > 0.0:
		_copy_feedback_timer -= delta
		if _copy_feedback_timer <= 0.0:
			_copy_btn.text = "COPY"


func refresh() -> void:
	var client := RetroUI.get_client(self)
	if client == null:
		_sync_empty_preview()
		return

	var room: Dictionary = client.get_my_room()
	if room.is_empty():
		_sync_empty_preview()
		return

	_current_room = room
	var room_id := int(room.get("id", 0))
	var host_id := str(room.get("host_identity", ""))
	var is_host: bool = client.is_host()
	var my_id: String = client.my_identity()

	_room_name_lbl.text = str(room.get("name", "Lobby"))
	_vis_badge_lbl.text = "[PUBLIC]" if bool(room.get("is_public", false)) else "[PRIVATE]"
	_code_lbl.text = "CODE: %s" % str(room.get("code", "-----"))

	var members: Array = client.get_room_members(room_id)
	var by_slot := {}
	var ready_count := 0
	var my_member: Dictionary = {}

	for m in members:
		var md: Dictionary = m
		var s := int(md.get("slot", 0))
		by_slot[s] = md
		if bool(md.get("ready", false)):
			ready_count += 1
		if str(md.get("identity", "")) == my_id:
			my_member = md

	for slot in range(4):
		var card: Dictionary = _slot_cards[slot]
		var panel: PanelContainer = card["panel"]
		var host_lbl: Label = card["host_lbl"]
		var nick_lbl: Label = card["nick_lbl"]
		var ready_lbl: Label = card["ready_lbl"]
		var btn: Button = card["claim_btn"]

		if by_slot.has(slot):
			var md: Dictionary = by_slot[slot]
			var occ_id := str(md.get("identity", ""))
			var is_me := (occ_id == my_id)
			var is_occ_host := (occ_id == host_id)
			var is_ready := bool(md.get("ready", false))

			host_lbl.text = "HOST" if is_occ_host else ""
			nick_lbl.text = str(md.get("nickname", "Bunny"))
			ready_lbl.text = "READY" if is_ready else "WAIT"
			ready_lbl.add_theme_color_override(
				"font_color",
				Color(0.42, 0.92, 0.48, 1.0) if is_ready else Color(0.95, 0.72, 0.28, 1.0)
			)
			btn.text = "YOU" if is_me else "USED"
			btn.disabled = true
			var border_col := Color(0.98, 0.84, 0.28, 1.0) if is_me else RetroUI.BUNNY_COLORS[slot]
			panel.add_theme_stylebox_override("panel", RetroUI.make_card_style(border_col))
		else:
			host_lbl.text = ""
			nick_lbl.text = "OPEN"
			ready_lbl.text = ""
			btn.text = "PICK"
			btn.disabled = false
			panel.add_theme_stylebox_override("panel", RetroUI.make_card_style(Color(0.25, 0.34, 0.42, 1.0)))

	_sync_settings_ui(room, is_host)

	var am_ready := bool(my_member.get("ready", false))
	_ready_btn.text = "UNREADY" if am_ready else "READY UP"
	var all_ready := (members.size() >= 1 and ready_count == members.size())
	_ready_summary_lbl.text = "%d/%d Ready" % [ready_count, members.size()]

	if is_host:
		_start_btn.visible = true
		_start_btn.disabled = not all_ready
		_start_btn.text = "START MATCH" if all_ready else "WAIT READY"
	else:
		_start_btn.visible = true
		_start_btn.disabled = true
		_start_btn.text = "HOST STARTS"


func _sync_empty_preview() -> void:
	for slot in range(4):
		var card: Dictionary = _slot_cards[slot]
		card["host_lbl"].text = "HOST" if slot == 0 else ""
		card["nick_lbl"].text = "OPEN"
		card["ready_lbl"].text = ""
		card["claim_btn"].text = "PICK"
		card["claim_btn"].disabled = true


func _sync_settings_ui(room: Dictionary, is_host: bool) -> void:
	_syncing_ui = true
	var win_mode := int(room.get("win_mode", 0))
	var win_target := int(room.get("win_target", 10))

	_win_kills_btn.button_pressed = (win_mode == 0)
	_win_time_btn.button_pressed = (win_mode == 1)
	_win_kills_btn.disabled = not is_host
	_win_time_btn.disabled = not is_host
	_target_minus_btn.disabled = not is_host
	_target_plus_btn.disabled = not is_host

	_target_val_lbl.text = "%d" % win_target if win_mode == 0 else "%ds" % win_target
	var presets: Array[int] = KILL_PRESETS if win_mode == 0 else TIME_PRESETS
	for i in range(_preset_btns.size()):
		var p: int = presets[i]
		_preset_btns[i].text = "%d" % p if win_mode == 0 else "%ds" % p
		_preset_btns[i].disabled = not is_host

	_low_grav_check.button_pressed = bool(room.get("mut_low_gravity", false))
	_pogo_check.button_pressed = bool(room.get("mut_pogo", false))
	_jetpack_check.button_pressed = bool(room.get("mut_jetpack", false))
	_gore_check.button_pressed = bool(room.get("gore_enabled", true))

	_low_grav_check.disabled = not is_host
	_pogo_check.disabled = not is_host
	_jetpack_check.disabled = not is_host
	_gore_check.disabled = not is_host
	_syncing_ui = false


func _build_slot_cards() -> void:
	_slot_cards.clear()
	for child in _slots_row.get_children():
		child.queue_free()

	for slot in range(4):
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_theme_stylebox_override("panel", RetroUI.make_card_style())

		var vbox := VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		panel.add_child(vbox)

		var top := HBoxContainer.new()
		vbox.add_child(top)

		var bname := Label.new()
		bname.text = RetroUI.BUNNY_NAMES[slot].to_upper()
		bname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bname.add_theme_color_override("font_color", RetroUI.BUNNY_COLORS[slot])
		bname.add_theme_font_size_override("font_size", 7)
		top.add_child(bname)

		var host_lbl := Label.new()
		host_lbl.text = ""
		host_lbl.add_theme_color_override("font_color", Color(0.98, 0.84, 0.28, 1.0))
		host_lbl.add_theme_font_size_override("font_size", 7)
		top.add_child(host_lbl)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(20, 20)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = RetroUI.make_bunny_atlas(slot, 0)
		vbox.add_child(icon)

		var nick_lbl := Label.new()
		nick_lbl.text = "OPEN"
		nick_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nick_lbl.clip_text = true
		nick_lbl.add_theme_font_size_override("font_size", 7)
		vbox.add_child(nick_lbl)

		var ready_lbl := Label.new()
		ready_lbl.text = ""
		ready_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ready_lbl.add_theme_font_size_override("font_size", 7)
		vbox.add_child(ready_lbl)

		var claim_btn := Button.new()
		claim_btn.text = "PICK"
		claim_btn.custom_minimum_size = Vector2(0, 15)
		claim_btn.add_theme_font_size_override("font_size", 7)
		var target_slot := slot
		claim_btn.pressed.connect(func() -> void: _on_select_slot(target_slot))
		vbox.add_child(claim_btn)

		_slots_row.add_child(panel)
		_slot_cards.append({
			"panel": panel,
			"host_lbl": host_lbl,
			"nick_lbl": nick_lbl,
			"ready_lbl": ready_lbl,
			"claim_btn": claim_btn,
		})


func _on_select_slot(slot: int) -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.select_bunny_slot(slot)


func _on_copy_pressed() -> void:
	var code := str(_current_room.get("code", ""))
	if not code.is_empty():
		DisplayServer.clipboard_set(code)
		_copy_btn.text = "COPIED!"
		_copy_feedback_timer = 1.5


func _on_leave_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.leave_room()


func _on_ready_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.toggle_ready()


func _on_start_pressed() -> void:
	var client := RetroUI.get_client(self)
	if client != null:
		client.start_match()


func _host_set_win_mode(mode: int) -> void:
	if _syncing_ui:
		return
	var target := 10 if mode == 0 else 120
	_send_settings(mode, target)


func _host_step_target(dir: int) -> void:
	if _syncing_ui:
		return
	var mode := int(_current_room.get("win_mode", 0))
	var cur := int(_current_room.get("win_target", 10))
	var next_target := cur
	if mode == 0:
		next_target = clampi(cur + dir, 1, 99)
	else:
		next_target = clampi(cur + dir * 15, 10, 600)
	_send_settings(mode, next_target)


func _host_apply_preset(preset_idx: int) -> void:
	if _syncing_ui:
		return
	var mode := int(_current_room.get("win_mode", 0))
	var presets: Array[int] = KILL_PRESETS if mode == 0 else TIME_PRESETS
	_send_settings(mode, presets[preset_idx])


func _host_push_settings() -> void:
	if _syncing_ui:
		return
	var mode := int(_current_room.get("win_mode", 0))
	var target := int(_current_room.get("win_target", 10))
	_send_settings(mode, target)


func _send_settings(win_mode: int, win_target: int) -> void:
	var client := RetroUI.get_client(self)
	if client == null or not client.is_host():
		return
	client.update_room_settings(
		win_mode,
		win_target,
		_low_grav_check.button_pressed,
		_pogo_check.button_pressed,
		_jetpack_check.button_pressed,
		_gore_check.button_pressed
	)
