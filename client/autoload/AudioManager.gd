extends Node

## AudioManager singleton preloading and playing all 7 retro WAV sound effects
## through a small round-robin pool of AudioStreamPlayer nodes (headless-safe).

const POOL_SIZE := 8

const SFX_STREAMS := {
	"jump": preload("res://assets/sfx/jump.wav"),
	"stomp_splat": preload("res://assets/sfx/stomp_splat.wav"),
	"puff": preload("res://assets/sfx/puff.wav"),
	"spring": preload("res://assets/sfx/spring.wav"),
	"splash": preload("res://assets/sfx/splash.wav"),
	"countdown": preload("res://assets/sfx/countdown.wav"),
	"victory": preload("res://assets/sfx/victory.wav"),
}

var _players: Array[AudioStreamPlayer] = []
var _next_idx: int = 0
var _muted: bool = false


func _ready() -> void:
	_init_pool()


## Plays a named SFX (`jump`, `stomp_splat`, `puff`, `spring`, `splash`, `countdown`, `victory`).
func play_sfx(sfx_name: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if _muted:
		return
	if _players.is_empty():
		_init_pool()
	var stream := SFX_STREAMS.get(sfx_name, null) as AudioStream
	if stream == null:
		push_warning("AudioManager: unknown SFX '%s'" % sfx_name)
		return

	var player := _pick_player()
	if player == null:
		return
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.play()


## Returns true if the given SFX name is preloaded and ready.
func has_sfx(sfx_name: String) -> bool:
	return SFX_STREAMS.get(sfx_name, null) != null


## Returns all preloaded SFX names.
func get_sfx_names() -> PackedStringArray:
	var names := PackedStringArray()
	for k in SFX_STREAMS.keys():
		names.append(str(k))
	return names


func set_muted(muted: bool) -> void:
	_muted = muted
	if _muted:
		for p in _players:
			p.stop()


func is_muted() -> bool:
	return _muted


func _init_pool() -> void:
	if not _players.is_empty():
		return
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "SfxPlayer_%d" % i
		add_child(p)
		_players.append(p)


func _pick_player() -> AudioStreamPlayer:
	if _players.is_empty():
		return null
	for p in _players:
		if not p.playing:
			return p
	var chosen := _players[_next_idx % _players.size()]
	_next_idx = (_next_idx + 1) % _players.size()
	return chosen
