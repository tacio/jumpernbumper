extends Control

## Root scene router transitioning between Connect, RoomBrowser, Lobby, GameWorld,
## and VictoryPodium based on SpacetimeClient state, and displaying transient error banners.

enum ScreenId {
	NONE = -1,
	CONNECT = 0,
	ROOM_BROWSER = 1,
	LOBBY = 2,
	GAME_WORLD = 3,
	VICTORY_PODIUM = 4,
}

const SCREEN_SCENES := {
	ScreenId.CONNECT: preload("res://scenes/ConnectScreen.tscn"),
	ScreenId.ROOM_BROWSER: preload("res://scenes/RoomBrowserScreen.tscn"),
	ScreenId.LOBBY: preload("res://scenes/LobbyScreen.tscn"),
	ScreenId.GAME_WORLD: preload("res://scenes/GameWorld.tscn"),
	ScreenId.VICTORY_PODIUM: preload("res://scenes/VictoryPodiumScreen.tscn"),
}

const BANNER_DURATION_SEC := 4.5

@onready var _screen_container: Node = $ScreenContainer
@onready var _banner_panel: PanelContainer = $BannerLayer/BannerPanel
@onready var _banner_label: Label = $BannerLayer/BannerPanel/HBox/BannerLabel
@onready var _banner_close_btn: Button = $BannerLayer/BannerPanel/HBox/CloseButton

var _active_screen_id: int = ScreenId.NONE
var _active_screen_node: Node = null
var _banner_timer: float = 0.0


func _ready() -> void:
	theme = RetroUI.get_theme()
	_banner_panel.visible = false
	_banner_panel.add_theme_stylebox_override(
		"panel",
		RetroUI.make_card_style(Color(0.95, 0.36, 0.36, 1.0), Color(0.24, 0.07, 0.08, 0.94))
	)
	_banner_close_btn.pressed.connect(func() -> void: _hide_banner())

	var client := RetroUI.get_client(self)
	if client != null:
		client.connected_and_ready.connect(_on_state_or_connect_changed)
		client.state_updated.connect(_on_state_or_connect_changed)
		client.connection_lost.connect(_on_connection_lost)
		client.reducer_error.connect(_on_reducer_error)

	_route_to_desired_screen()


func _process(delta: float) -> void:
	if _banner_panel.visible and _banner_timer > 0.0:
		_banner_timer -= delta
		if _banner_timer <= 0.0:
			_hide_banner()


func get_active_screen_id() -> int:
	return _active_screen_id


func show_banner(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	_banner_label.text = message
	_banner_panel.visible = true
	_banner_timer = BANNER_DURATION_SEC


func _hide_banner() -> void:
	_banner_panel.visible = false
	_banner_timer = 0.0


func _on_state_or_connect_changed() -> void:
	_route_to_desired_screen()


func _on_connection_lost(reason: String) -> void:
	_route_to_desired_screen()
	show_banner("Disconnected: %s" % reason)


func _on_reducer_error(_reducer_name: String, error_message: String, _req_id: int) -> void:
	show_banner(error_message)


func _route_to_desired_screen() -> void:
	var target := _compute_target_screen()
	if target == _active_screen_id and is_instance_valid(_active_screen_node):
		return

	if is_instance_valid(_active_screen_node):
		_active_screen_node.queue_free()
		_active_screen_node = null

	_active_screen_id = target
	var packed: PackedScene = SCREEN_SCENES.get(target, null)
	if packed != null:
		_active_screen_node = packed.instantiate()
		_screen_container.add_child(_active_screen_node)


func _compute_target_screen() -> int:
	var client := RetroUI.get_client(self)
	if client == null or not client.is_client_connected():
		return ScreenId.CONNECT

	var room: Dictionary = client.get_my_room()
	if room.is_empty():
		return ScreenId.ROOM_BROWSER

	var status := int(room.get("status", 0))
	match status:
		client.STATUS_WAITING:
			return ScreenId.LOBBY
		client.STATUS_IN_PROGRESS:
			return ScreenId.GAME_WORLD
		client.STATUS_FINISHED:
			return ScreenId.VICTORY_PODIUM
		_:
			return ScreenId.ROOM_BROWSER
