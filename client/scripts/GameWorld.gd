extends Node2D

## Active gameplay world scene hosting `Arena.tscn`, interpolated bunny sprites,
## particle bursts (gore/fur/puffs/water droplets), SFX triggers, MatchHUD, and ESC pause menu.

const BUNNY_SHEET_TEX: Texture2D = preload("res://assets/sprites/bunny_sheet.png")
const PARTICLES_TEX: Texture2D = preload("res://assets/sprites/particles.png")

const SPRITE_OFFSET := Vector2(7.0, 6.0)
const SNAP_DISTANCE := 48.0
const INTERP_RATE := 24.0
const RUN_CYCLE: Array[int] = [2, 3, 4, 3]
const PARTICLE_GRAVITY := 280.0
const KILL_FEED_TTL := 3.5
const MAX_KILL_FEED := 3

@onready var _arena: ArenaRenderer = $Arena
@onready var _bunnies_layer: Node2D = $BunniesLayer
@onready var _particles_layer: Node2D = $ParticlesLayer
@onready var _hud_root: Control = $HUDLayer/MatchHUD
@onready var _scores_row: HBoxContainer = $HUDLayer/MatchHUD/TopBar/ScoresRow
@onready var _target_lbl: Label = $HUDLayer/MatchHUD/TopBar/TargetLabel
@onready var _menu_btn: Button = $HUDLayer/MatchHUD/TopBar/MenuButton
@onready var _kill_feed_vbox: VBoxContainer = $HUDLayer/MatchHUD/KillFeed
@onready var _pause_overlay: ColorRect = $HUDLayer/MatchHUD/PauseOverlay
@onready var _resume_btn: Button = $HUDLayer/MatchHUD/PauseOverlay/PausePanel/VBox/ResumeButton
@onready var _leave_btn: Button = $HUDLayer/MatchHUD/PauseOverlay/PausePanel/VBox/LeaveRoomButton
@onready var _disconnect_btn: Button = $HUDLayer/MatchHUD/PauseOverlay/PausePanel/VBox/DisconnectButton

var _room_id: int = 0
var _anim_time: float = 0.0
var _input_seq: int = 1
var _last_sent_bits: int = -1

var _bunny_nodes: Dictionary = {} # identity -> Dictionary{sprite, target, prev_alive, prev_on_ground, prev_in_water, prev_vy, state}
var _particles: Array[Dictionary] = []
var _kill_feed_entries: Array[Dictionary] = []
var _score_chips: Array[Label] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_hud_root.theme = RetroUI.get_theme()
	_pause_overlay.visible = false

	_build_score_chips()

	_menu_btn.pressed.connect(_toggle_pause)
	_resume_btn.pressed.connect(func() -> void: _set_paused(false))
	_leave_btn.pressed.connect(_on_leave_pressed)
	_disconnect_btn.pressed.connect(_on_disconnect_pressed)

	var client := RetroUI.get_client(self)
	if client != null:
		client.state_updated.connect(_on_state_updated)
		client.kill_event_received.connect(_on_kill_event_received)
		_on_state_updated()

	var audio := RetroUI.get_audio(self)
	if audio != null:
		audio.play_sfx("countdown", -3.0)


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action("pause_menu") and event.is_action_pressed("pause_menu"):
		_toggle_pause()
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	_sample_and_send_input()


func _process(delta: float) -> void:
	_anim_time += delta
	_update_bunny_visuals(delta)
	_update_particles(delta)
	_update_kill_feed(delta)


func _sample_and_send_input() -> void:
	var client := RetroUI.get_client(self)
	if client == null or not client.is_client_connected():
		return
	var room: Dictionary = client.get_my_room()
	if room.is_empty() or int(room.get("status", -1)) != client.STATUS_IN_PROGRESS:
		return

	var bits := 0
	if not _pause_overlay.visible:
		if InputMap.has_action("move_left") and Input.is_action_pressed("move_left"):
			bits |= client.INPUT_LEFT
		if InputMap.has_action("move_right") and Input.is_action_pressed("move_right"):
			bits |= client.INPUT_RIGHT
		if InputMap.has_action("jump") and Input.is_action_pressed("jump"):
			bits |= client.INPUT_JUMP

	if bits != _last_sent_bits:
		_last_sent_bits = bits
		client.send_input(bits, _input_seq)
		_input_seq += 1


func _on_state_updated() -> void:
	var client := RetroUI.get_client(self)
	if client == null:
		return
	var room: Dictionary = client.get_my_room()
	if room.is_empty():
		return

	_room_id = int(room.get("id", 0))
	var members: Array = client.get_room_members(_room_id)
	_refresh_hud(room, members)

	var bunnies: Array = client.get_room_bunnies(_room_id)
	var seen_ids := {}

	for b in bunnies:
		var bd: Dictionary = b
		var id := str(bd.get("identity", ""))
		if id.is_empty():
			continue
		seen_ids[id] = true
		_sync_bunny_state(id, bd)

	var to_remove: Array[String] = []
	for existing_id in _bunny_nodes.keys():
		if not seen_ids.has(existing_id):
			to_remove.append(str(existing_id))
	for rem_id in to_remove:
		var entry: Dictionary = _bunny_nodes[rem_id]
		var sp: Sprite2D = entry["sprite"]
		if is_instance_valid(sp):
			sp.queue_free()
		_bunny_nodes.erase(rem_id)


func _sync_bunny_state(id: String, bd: Dictionary) -> void:
	var slot := int(bd.get("slot", 0))
	var bx := float(bd.get("x", 0.0))
	var by := float(bd.get("y", 0.0))
	var vy := float(bd.get("vy", 0.0))
	var alive := bool(bd.get("alive", true))
	var on_ground := bool(bd.get("on_ground", false))
	var in_water := bool(bd.get("in_water", false))
	var target_pos := Vector2(bx, by) + SPRITE_OFFSET

	if not _bunny_nodes.has(id):
		var sp := Sprite2D.new()
		sp.name = "Bunny_%d" % slot
		sp.texture = BUNNY_SHEET_TEX
		sp.region_enabled = true
		sp.centered = true
		sp.region_rect = Rect2(0.0, float(slot * 16), 16.0, 16.0)
		sp.position = target_pos
		sp.visible = alive
		_bunnies_layer.add_child(sp)
		_bunny_nodes[id] = {
			"sprite": sp,
			"target": target_pos,
			"prev_alive": alive,
			"prev_on_ground": on_ground,
			"prev_in_water": in_water,
			"prev_vy": vy,
			"state": bd,
		}
		return

	var entry: Dictionary = _bunny_nodes[id]
	var sp: Sprite2D = entry["sprite"]
	var prev_alive: bool = bool(entry["prev_alive"])
	var prev_on_ground: bool = bool(entry["prev_on_ground"])
	var prev_in_water: bool = bool(entry["prev_in_water"])
	var prev_vy: float = float(entry["prev_vy"])

	# Snap on respawn or large teleport; smooth interpolate normal movement.
	if (not prev_alive and alive) or sp.position.distance_to(target_pos) > SNAP_DISTANCE:
		sp.position = target_pos

	if alive:
		var audio := RetroUI.get_audio(self)
		# Spring launch detection (spring velocity is -335.0 vs normal jump -225.0).
		if prev_vy > -260.0 and vy <= -260.0:
			_trigger_spring_near(bx, by)
			if audio != null:
				audio.play_sfx("spring", -2.0)
		elif prev_on_ground and not on_ground and vy < -50.0 and not in_water:
			if audio != null:
				audio.play_sfx("jump", -4.0, _rng.randf_range(0.95, 1.05))

		# Water entry/exit splash.
		if in_water != prev_in_water:
			_spawn_water_splash(bx + 7.0, by + 10.0)
			if audio != null:
				audio.play_sfx("splash", -3.0)

	entry["target"] = target_pos
	entry["prev_alive"] = alive
	entry["prev_on_ground"] = on_ground
	entry["prev_in_water"] = in_water
	entry["prev_vy"] = vy
	entry["state"] = bd


func _trigger_spring_near(bx: float, by: float) -> void:
	if _arena == null:
		return
	var probes: Array[Vector2] = [
		Vector2(bx + 7.0, by + 16.0),
		Vector2(bx + 2.0, by + 16.0),
		Vector2(bx + 12.0, by + 16.0),
		Vector2(bx + 7.0, by + 8.0),
		Vector2(bx + 7.0, by + 24.0),
	]
	for p in probes:
		if _arena.trigger_spring_at_world_pos(p.x, p.y):
			return


func _update_bunny_visuals(delta: float) -> void:
	var alpha := minf(1.0, delta * INTERP_RATE)
	for entry_var in _bunny_nodes.values():
		var entry: Dictionary = entry_var
		var sp: Sprite2D = entry["sprite"]
		var target: Vector2 = entry["target"]
		var bd: Dictionary = entry["state"]

		var alive := bool(bd.get("alive", true))
		sp.visible = alive
		if not alive:
			continue

		sp.position = sp.position.lerp(target, alpha)
		sp.flip_h = int(bd.get("facing", 1)) < 0

		var slot := clampi(int(bd.get("slot", 0)), 0, 3)
		var invuln := int(bd.get("invuln_ticks", 0))
		if invuln > 0:
			var blink_on := int(floor(_anim_time * 16.0)) % 2 == 0
			sp.modulate.a = 0.45 if blink_on else 1.0
		else:
			sp.modulate.a = 1.0

		var frame := _pick_anim_frame(bd, slot)
		sp.region_rect = Rect2(float(frame * 16), float(slot * 16), 16.0, 16.0)


func _pick_anim_frame(bd: Dictionary, slot: int) -> int:
	if bool(bd.get("in_water", false)):
		return 7
	if not bool(bd.get("on_ground", false)):
		return 5 if float(bd.get("vy", 0.0)) < 0.0 else 6
	if absf(float(bd.get("vx", 0.0))) > 8.0:
		var idx := int(floor(_anim_time * 12.0 + float(slot) * 0.3)) % RUN_CYCLE.size()
		return RUN_CYCLE[idx]
	return int(floor(_anim_time * 2.0 + float(slot) * 0.5)) % 2


func _on_kill_event_received(ev: Dictionary) -> void:
	if int(ev.get("room_id", 0)) != _room_id:
		return

	var killer_slot := clampi(int(ev.get("killer_slot", 0)), 0, 3)
	var victim_slot := clampi(int(ev.get("victim_slot", 0)), 0, 3)
	var wx := float(ev.get("x", 200.0))
	var wy := float(ev.get("y", 128.0))

	var client := RetroUI.get_client(self)
	var room: Dictionary = client.get_my_room() if client != null else {}
	var gore_enabled := bool(room.get("gore_enabled", true))
	var members: Array = client.get_room_members(_room_id) if client != null else []

	var killer_name := _name_for_slot(members, killer_slot)
	var victim_name := _name_for_slot(members, victim_slot)
	_push_kill_feed("%s > %s" % [killer_name, victim_name], RetroUI.BUNNY_COLORS[killer_slot])

	var audio := RetroUI.get_audio(self)
	if gore_enabled:
		if audio != null:
			audio.play_sfx("stomp_splat", -1.0)
		_spawn_gore_burst(wx, wy, victim_slot)
	else:
		if audio != null:
			audio.play_sfx("puff", -1.0)
		_spawn_puff_burst(wx, wy)


func _name_for_slot(members: Array, slot: int) -> String:
	for m in members:
		var md: Dictionary = m
		if int(md.get("slot", -1)) == slot:
			return str(md.get("nickname", RetroUI.BUNNY_NAMES[slot])).left(10)
	return RetroUI.BUNNY_NAMES[slot]


func _spawn_gore_burst(wx: float, wy: float, victim_slot: int) -> void:
	for _i in range(12):
		var col := _rng.randi_range(0, 7)
		_add_particle(
			Vector2(wx, wy),
			Vector2(_rng.randf_range(-110.0, 110.0), _rng.randf_range(-165.0, -30.0)),
			Rect2(float(col * 8), 0.0, 8.0, 8.0),
			_rng.randf_range(0.55, 0.90),
			true
		)
	for _i in range(6):
		var col := clampi(victim_slot, 0, 3) * 2 + _rng.randi_range(0, 1)
		_add_particle(
			Vector2(wx, wy),
			Vector2(_rng.randf_range(-85.0, 85.0), _rng.randf_range(-130.0, -25.0)),
			Rect2(float(col * 8), 8.0, 8.0, 8.0),
			_rng.randf_range(0.50, 0.85),
			true
		)


func _spawn_puff_burst(wx: float, wy: float) -> void:
	for _i in range(10):
		var col := _rng.randi_range(0, 3)
		_add_particle(
			Vector2(wx, wy),
			Vector2(_rng.randf_range(-75.0, 75.0), _rng.randf_range(-90.0, 20.0)),
			Rect2(float(col * 8), 16.0, 8.0, 8.0),
			_rng.randf_range(0.35, 0.60),
			false
		)


func _spawn_water_splash(wx: float, wy: float) -> void:
	for _i in range(7):
		var col := _rng.randi_range(4, 7)
		_add_particle(
			Vector2(wx, wy),
			Vector2(_rng.randf_range(-65.0, 65.0), _rng.randf_range(-120.0, -40.0)),
			Rect2(float(col * 8), 16.0, 8.0, 8.0),
			_rng.randf_range(0.30, 0.55),
			true
		)


func _add_particle(pos: Vector2, vel: Vector2, region: Rect2, ttl: float, use_gravity: bool) -> void:
	var sp := Sprite2D.new()
	sp.texture = PARTICLES_TEX
	sp.region_enabled = true
	sp.region_rect = region
	sp.position = pos
	_particles_layer.add_child(sp)
	_particles.append({
		"sprite": sp,
		"vel": vel,
		"ttl": ttl,
		"max_ttl": ttl,
		"gravity": use_gravity,
	})


func _update_particles(delta: float) -> void:
	if _particles.is_empty():
		return
	var alive_list: Array[Dictionary] = []
	for p in _particles:
		var ttl: float = float(p["ttl"]) - delta
		var sp: Sprite2D = p["sprite"]
		if ttl <= 0.0 or not is_instance_valid(sp):
			if is_instance_valid(sp):
				sp.queue_free()
			continue
		var vel: Vector2 = p["vel"]
		if bool(p["gravity"]):
			vel.y += PARTICLE_GRAVITY * delta
		sp.position += vel * delta
		sp.modulate.a = clampf(ttl / float(p["max_ttl"]), 0.0, 1.0)
		p["vel"] = vel
		p["ttl"] = ttl
		alive_list.append(p)
	_particles = alive_list


func _build_score_chips() -> void:
	_score_chips.clear()
	for child in _scores_row.get_children():
		child.queue_free()
	for slot in range(4):
		var lbl := Label.new()
		lbl.text = ""
		lbl.visible = false
		lbl.add_theme_color_override("font_color", RetroUI.BUNNY_COLORS[slot])
		_scores_row.add_child(lbl)
		_score_chips.append(lbl)


func _refresh_hud(room: Dictionary, members: Array) -> void:
	var by_slot := {}
	for m in members:
		var md: Dictionary = m
		by_slot[int(md.get("slot", 0))] = md

	for slot in range(4):
		var lbl: Label = _score_chips[slot]
		if by_slot.has(slot):
			var md: Dictionary = by_slot[slot]
			var nick := str(md.get("nickname", RetroUI.BUNNY_NAMES[slot])).left(7)
			var kills := int(md.get("kills", 0))
			lbl.text = "%s:%d" % [nick, kills]
			lbl.visible = true
		else:
			lbl.visible = false

	var win_mode := int(room.get("win_mode", 0))
	var win_target := int(room.get("win_target", 10))
	if win_mode == 0:
		_target_lbl.text = "TO %dK" % win_target
	else:
		var elapsed_s := int(floor(float(room.get("elapsed_ms", 0)) / 1000.0))
		var rem_s := maxi(0, win_target - elapsed_s)
		var mins := rem_s / 60
		var secs := rem_s % 60
		_target_lbl.text = "%02d:%02d" % [mins, secs]


func _push_kill_feed(text: String, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	_kill_feed_vbox.add_child(lbl)
	_kill_feed_entries.append({"label": lbl, "ttl": KILL_FEED_TTL})

	while _kill_feed_entries.size() > MAX_KILL_FEED:
		var oldest: Dictionary = _kill_feed_entries.pop_front()
		var old_lbl: Label = oldest["label"]
		if is_instance_valid(old_lbl):
			old_lbl.queue_free()


func _update_kill_feed(delta: float) -> void:
	if _kill_feed_entries.is_empty():
		return
	var kept: Array[Dictionary] = []
	for item in _kill_feed_entries:
		var ttl: float = float(item["ttl"]) - delta
		var lbl: Label = item["label"]
		if ttl <= 0.0 or not is_instance_valid(lbl):
			if is_instance_valid(lbl):
				lbl.queue_free()
			continue
		lbl.modulate.a = clampf(ttl, 0.0, 1.0)
		item["ttl"] = ttl
		kept.append(item)
	_kill_feed_entries = kept


func _toggle_pause() -> void:
	_set_paused(not _pause_overlay.visible)


func _set_paused(paused: bool) -> void:
	_pause_overlay.visible = paused


func _on_leave_pressed() -> void:
	_set_paused(false)
	var client := RetroUI.get_client(self)
	if client != null:
		client.leave_room()


func _on_disconnect_pressed() -> void:
	_set_paused(false)
	var client := RetroUI.get_client(self)
	if client != null:
		client.disconnect_from_server()
