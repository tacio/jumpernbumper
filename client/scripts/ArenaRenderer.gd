class_name ArenaRenderer
extends Node2D

## Renders the Jump 'n Bump classic meadow arena from `res://data/classic_meadow.json`.
##
## Draws the daytime parallax sky/hills backdrop (`meadow_bg.png`), the 25x16 tile grid
## (`tileset.png`) with grass-top/subsoil autotiling, 2-frame animated water surfaces,
## and animated springboards, plus gentle buzzing ambient meadow flies (`particles.png`).

const DEFAULT_MAP_PATH := "res://data/classic_meadow.json"
const BG_TEX_PATH := "res://assets/bg/meadow_bg.png"
const TILESET_TEX_PATH := "res://assets/tiles/tileset.png"
const PARTICLES_TEX_PATH := "res://assets/sprites/particles.png"

const TILE_EMPTY := 0
const TILE_GRASS_DIRT := 1
const TILE_MOSSY_STONE := 2
const TILE_WATER := 3
const TILE_ICE := 4
const TILE_SPRING := 5

const ATLAS_GRASS_TOP := Rect2(0.0, 0.0, 16.0, 16.0)
const ATLAS_DIRT := Rect2(16.0, 0.0, 16.0, 16.0)
const ATLAS_MOSSY_STONE := Rect2(32.0, 0.0, 16.0, 16.0)
const ATLAS_WATER_SURF_1 := Rect2(48.0, 0.0, 16.0, 16.0)
const ATLAS_WATER_SURF_2 := Rect2(64.0, 0.0, 16.0, 16.0)
const ATLAS_WATER_DEEP := Rect2(80.0, 0.0, 16.0, 16.0)
const ATLAS_ICE := Rect2(96.0, 0.0, 16.0, 16.0)
const ATLAS_SPRING_REST := Rect2(112.0, 0.0, 16.0, 16.0)
const ATLAS_SPRING_EXTENDED := Rect2(0.0, 16.0, 16.0, 16.0)

const WATER_FRAME_INTERVAL := 0.35
const SPRING_EXTEND_DURATION := 0.25
const FLY_FLAP_HZ := 12.0

@export var map_path: String = DEFAULT_MAP_PATH

var _cols: int = 0
var _rows_count: int = 0
var _tile_size: float = 16.0
var _grid: Array = []
var _spawn_points: Array[Vector2] = []

var _bg_tex: Texture2D
var _tileset_tex: Texture2D
var _particles_tex: Texture2D

var _water_anim_timer: float = 0.0
var _water_frame: int = 0
var _spring_timers: Dictionary = {}

var _fly_time: float = 0.0
var _flies: Array[Dictionary] = []


func _ready() -> void:
	_load_textures()
	_ensure_background_node()
	_load_map(map_path)
	_spawn_ambient_flies()
	queue_redraw()


func _process(delta: float) -> void:
	var needs_redraw := false

	_water_anim_timer += delta
	while _water_anim_timer >= WATER_FRAME_INTERVAL:
		_water_anim_timer -= WATER_FRAME_INTERVAL
		_water_frame = 1 - _water_frame
		needs_redraw = true

	if not _spring_timers.is_empty():
		var expired: Array[Vector2i] = []
		for key in _spring_timers.keys():
			var remaining: float = float(_spring_timers[key]) - delta
			if remaining <= 0.0:
				expired.append(key)
			else:
				_spring_timers[key] = remaining
		for key in expired:
			_spring_timers.erase(key)
			needs_redraw = true

	if needs_redraw:
		queue_redraw()

	_update_ambient_flies(delta)


func _draw() -> void:
	if _tileset_tex == null or _grid.is_empty():
		return

	for row in range(_rows_count):
		for col in range(_cols):
			var tile_id := get_tile_at(col, row)
			if tile_id == TILE_EMPTY:
				continue
			var src_rect := _get_tile_atlas_rect(col, row, tile_id)
			if src_rect.size.x <= 0.0 or src_rect.size.y <= 0.0:
				continue
			var dst_rect := Rect2(
				float(col) * _tile_size,
				float(row) * _tile_size,
				_tile_size,
				_tile_size
			)
			draw_texture_rect_region(_tileset_tex, dst_rect, src_rect)


func get_map_cols() -> int:
	return _cols


func get_map_rows() -> int:
	return _rows_count


func get_tile_size() -> float:
	return _tile_size


func get_tile_at(col: int, row: int) -> int:
	if col < 0 or col >= _cols or row < 0 or row >= _rows_count:
		return -1
	var row_arr: PackedInt32Array = _grid[row]
	return row_arr[col]


func get_spawn_points() -> Array[Vector2]:
	return _spawn_points.duplicate()


func trigger_spring_at_world_pos(world_x: float, world_y: float) -> bool:
	if _tile_size <= 0.0:
		return false
	var col := int(floor(world_x / _tile_size))
	var row := int(floor(world_y / _tile_size))
	if get_tile_at(col, row) != TILE_SPRING:
		return false
	_spring_timers[Vector2i(col, row)] = SPRING_EXTEND_DURATION
	queue_redraw()
	return true


func is_spring_extended(col: int, row: int) -> bool:
	return float(_spring_timers.get(Vector2i(col, row), 0.0)) > 0.0


func get_ambient_fly_count() -> int:
	return _flies.size()


func _load_textures() -> void:
	_bg_tex = load(BG_TEX_PATH) as Texture2D
	_tileset_tex = load(TILESET_TEX_PATH) as Texture2D
	_particles_tex = load(PARTICLES_TEX_PATH) as Texture2D

	if _bg_tex == null:
		push_error("ArenaRenderer: Failed to load %s" % BG_TEX_PATH)
	if _tileset_tex == null:
		push_error("ArenaRenderer: Failed to load %s" % TILESET_TEX_PATH)
	if _particles_tex == null:
		push_error("ArenaRenderer: Failed to load %s" % PARTICLES_TEX_PATH)


func _ensure_background_node() -> void:
	var bg := get_node_or_null("Background") as Sprite2D
	if bg == null:
		bg = Sprite2D.new()
		bg.name = "Background"
		bg.z_index = -10
		bg.centered = false
		add_child(bg)
	bg.centered = false
	bg.z_index = -10
	if _bg_tex != null:
		bg.texture = _bg_tex


func _load_map(path: String) -> void:
	_grid.clear()
	_spawn_points.clear()
	_cols = 0
	_rows_count = 0

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ArenaRenderer: Failed to open map file %s (err=%d)" % [path, FileAccess.get_open_error()])
		return

	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	if err != OK:
		push_error("ArenaRenderer: Invalid JSON in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return

	if not (json.data is Dictionary):
		push_error("ArenaRenderer: Map root must be a Dictionary in %s" % path)
		return

	var data: Dictionary = json.data
	_tile_size = float(data.get("tile_size", 16.0))
	_cols = int(data.get("cols", 0))

	var rows_raw: Array = data.get("rows", [])
	_rows_count = rows_raw.size()
	for r in rows_raw:
		var packed := PackedInt32Array()
		if r is Array:
			for v in r:
				packed.append(int(v))
		_grid.append(packed)

	var spawns_raw: Array = data.get("spawn_points", [])
	for sp in spawns_raw:
		if sp is Array and sp.size() >= 2:
			_spawn_points.append(Vector2(float(sp[0]), float(sp[1])))


func _get_tile_atlas_rect(col: int, row: int, tile_id: int) -> Rect2:
	match tile_id:
		TILE_GRASS_DIRT:
			if get_tile_at(col, row - 1) == TILE_GRASS_DIRT:
				return ATLAS_DIRT
			return ATLAS_GRASS_TOP
		TILE_MOSSY_STONE:
			return ATLAS_MOSSY_STONE
		TILE_WATER:
			if get_tile_at(col, row - 1) == TILE_WATER:
				return ATLAS_WATER_DEEP
			return ATLAS_WATER_SURF_1 if _water_frame == 0 else ATLAS_WATER_SURF_2
		TILE_ICE:
			return ATLAS_ICE
		TILE_SPRING:
			return ATLAS_SPRING_EXTENDED if is_spring_extended(col, row) else ATLAS_SPRING_REST
		_:
			return Rect2()


func _spawn_ambient_flies() -> void:
	if _particles_tex == null:
		return

	var flies_root := get_node_or_null("AmbientFlies") as Node2D
	if flies_root == null:
		flies_root = Node2D.new()
		flies_root.name = "AmbientFlies"
		flies_root.z_index = 5
		add_child(flies_root)

	for child in flies_root.get_children():
		child.queue_free()
	_flies.clear()

	var anchors: Array[Vector2] = [
		Vector2(66.0, 178.0),
		Vector2(142.0, 186.0),
		Vector2(204.0, 190.0),
		Vector2(256.0, 182.0),
		Vector2(328.0, 176.0),
		Vector2(198.0, 118.0),
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337

	for i in range(anchors.size()):
		var sprite := Sprite2D.new()
		sprite.name = "Fly_%d" % i
		sprite.texture = _particles_tex
		sprite.region_enabled = true
		var is_firefly := (i % 3 == 2)
		var base_col := 2 if is_firefly else 0
		sprite.region_rect = Rect2(float(base_col * 8), 24.0, 8.0, 8.0)
		sprite.position = anchors[i]
		flies_root.add_child(sprite)

		_flies.append({
			"sprite": sprite,
			"anchor": anchors[i],
			"base_col": base_col,
			"phase": rng.randf_range(0.0, TAU),
			"speed_x": rng.randf_range(1.6, 2.8),
			"speed_y": rng.randf_range(2.2, 3.6),
			"amp_x": rng.randf_range(8.0, 18.0),
			"amp_y": rng.randf_range(4.0, 9.0),
		})


func _update_ambient_flies(delta: float) -> void:
	if _flies.is_empty():
		return
	_fly_time += delta
	for entry in _flies:
		var sprite: Sprite2D = entry["sprite"]
		var anchor: Vector2 = entry["anchor"]
		var phase: float = float(entry["phase"])
		var sx: float = float(entry["speed_x"])
		var sy: float = float(entry["speed_y"])
		var ax: float = float(entry["amp_x"])
		var ay: float = float(entry["amp_y"])
		var base_col: int = int(entry["base_col"])

		var dx := sin(_fly_time * sx + phase) * ax
		var dy := cos(_fly_time * sy + phase * 1.3) * ay
		sprite.position = anchor + Vector2(dx, dy)
		sprite.flip_h = cos(_fly_time * sx + phase) < 0.0

		var flap_frame := int(floor((_fly_time + phase) * FLY_FLAP_HZ)) % 2
		sprite.region_rect = Rect2(float((base_col + flap_frame) * 8), 24.0, 8.0, 8.0)
