extends SceneTree

## Headless Phase 3 verification script for Godot 4.7.2.
##
## Loads `res://scenes/Arena.tscn`, checks all procedural PNG textures and WAV SFX
## load cleanly with expected dimensions/formats, asserts `get_map_cols() == 25`,
## `get_map_rows() == 16`, and every tile (col, row) matches `res://data/classic_meadow.json`
## 1:1, and exercises springboard animation and ambient fly updates without errors.

const EXPECTED_TEXTURES := {
	"res://assets/sprites/bunny_sheet.png": Vector2i(128, 64),
	"res://assets/tiles/tileset.png": Vector2i(128, 32),
	"res://assets/bg/meadow_bg.png": Vector2i(400, 256),
	"res://assets/sprites/particles.png": Vector2i(64, 32),
}

const EXPECTED_SFX := [
	"res://assets/sfx/jump.wav",
	"res://assets/sfx/stomp_splat.wav",
	"res://assets/sfx/puff.wav",
	"res://assets/sfx/spring.wav",
	"res://assets/sfx/splash.wav",
	"res://assets/sfx/countdown.wav",
	"res://assets/sfx/victory.wav",
]

const EXPECTED_DATA_FILES := [
	"res://data/classic_meadow.json",
	"res://data/physics_constants.json",
	"res://data/table_schemas.json",
]

var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true

	var ok := _run_all_checks()
	quit(0 if ok else 1)
	return true


func _run_all_checks() -> bool:
	# 1. Verify mirrored JSON files in res://data/
	var meadow_data: Dictionary = {}
	for path in EXPECTED_DATA_FILES:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return _fail("Failed to open data file: %s" % path)
		var json := JSON.new()
		var err := json.parse(f.get_as_text())
		if err != OK or not (json.data is Dictionary):
			return _fail("Invalid JSON in %s: %s" % [path, json.get_error_message()])
		if path == "res://data/classic_meadow.json":
			meadow_data = json.data

	# 2. Verify all PNG textures load with expected dimensions
	for tex_path in EXPECTED_TEXTURES.keys():
		var expected_size: Vector2i = EXPECTED_TEXTURES[tex_path]
		var tex := load(tex_path) as Texture2D
		if tex == null:
			return _fail("Failed to load texture: %s" % tex_path)
		var actual_size := Vector2i(tex.get_width(), tex.get_height())
		if actual_size != expected_size:
			return _fail("Texture %s size mismatch: got %s, expected %s" % [tex_path, str(actual_size), str(expected_size)])

	# 3. Verify all WAV SFX load as 16-bit mono 22050 Hz streams
	for sfx_path in EXPECTED_SFX:
		var stream := load(sfx_path) as AudioStreamWAV
		if stream == null:
			return _fail("Failed to load AudioStreamWAV: %s" % sfx_path)
		if not (stream.format in [AudioStreamWAV.FORMAT_16_BITS, AudioStreamWAV.FORMAT_QOA]):
			return _fail("SFX %s unexpected AudioStreamWAV format: %d" % [sfx_path, stream.format])
		if stream.mix_rate != 22050:
			return _fail("SFX %s mix_rate expected 22050, got %d" % [sfx_path, stream.mix_rate])
		if stream.stereo:
			return _fail("SFX %s expected mono, got stereo" % sfx_path)
		if stream.get_length() <= 0.0:
			return _fail("SFX %s has zero length" % sfx_path)

	# 4. Instantiate res://scenes/Arena.tscn
	var packed := load("res://scenes/Arena.tscn") as PackedScene
	if packed == null:
		return _fail("Failed to load res://scenes/Arena.tscn")

	var arena := packed.instantiate() as ArenaRenderer
	if arena == null:
		return _fail("Arena.tscn root did not instantiate as ArenaRenderer")
	root.add_child(arena)

	# 5. Assert map dimensions & 1:1 tile match against classic_meadow.json
	if arena.get_map_cols() != 25:
		return _fail("Expected get_map_cols() == 25, got %d" % arena.get_map_cols())
	if arena.get_map_rows() != 16:
		return _fail("Expected get_map_rows() == 16, got %d" % arena.get_map_rows())

	var rows: Array = meadow_data.get("rows", [])
	if rows.size() != 16:
		return _fail("classic_meadow.json rows size != 16")

	var first_spring := Vector2i(-1, -1)
	for r in range(16):
		var row_arr: Array = rows[r]
		if row_arr.size() != 25:
			return _fail("classic_meadow.json row %d size != 25" % r)
		for c in range(25):
			var expected_tile := int(row_arr[c])
			var actual_tile := arena.get_tile_at(c, r)
			if actual_tile != expected_tile:
				return _fail("Tile mismatch at (%d, %d): arena=%d json=%d" % [c, r, actual_tile, expected_tile])
			if expected_tile == 5 and first_spring.x == -1:
				first_spring = Vector2i(c, r)

	if arena.get_tile_at(-1, 0) != -1 or arena.get_tile_at(25, 0) != -1 or arena.get_tile_at(0, 16) != -1:
		return _fail("Out-of-bounds get_tile_at should return -1")

	# 6. Verify Background & AmbientFlies initialized
	var bg := arena.get_node_or_null("Background") as Sprite2D
	if bg == null or bg.texture == null:
		return _fail("Arena Background Sprite2D or texture is missing")
	if arena.get_ambient_fly_count() <= 0:
		return _fail("Expected at least 1 ambient fly in Arena")

	# 7. Trigger spring animation and verify extend -> rest lifecycle
	if first_spring.x == -1:
		return _fail("No spring tile (5) found in classic_meadow.json")

	var sx := float(first_spring.x) * 16.0 + 8.0
	var sy := float(first_spring.y) * 16.0 + 8.0
	if arena.is_spring_extended(first_spring.x, first_spring.y):
		return _fail("Spring should initially be resting")
	if not arena.trigger_spring_at_world_pos(sx, sy):
		return _fail("trigger_spring_at_world_pos failed on spring tile (%d, %d)" % [first_spring.x, first_spring.y])
	if not arena.is_spring_extended(first_spring.x, first_spring.y):
		return _fail("Spring did not enter extended state after trigger")
	if arena.trigger_spring_at_world_pos(8.0, 8.0):
		return _fail("trigger_spring_at_world_pos unexpectedly returned true on empty tile (0, 0)")

	arena._process(0.10)
	if not arena.is_spring_extended(first_spring.x, first_spring.y):
		return _fail("Spring reset too early after 0.10s")

	arena._process(0.40)
	if arena.is_spring_extended(first_spring.x, first_spring.y):
		return _fail("Spring did not return to resting after 0.50s total")

	print("[test_phase3_arena] PASS: 25x16 classic_meadow tiles, 4 PNGs, 7 WAVs, spring animation, and ambient flies verified.")
	return true


func _fail(reason: String) -> bool:
	printerr("[test_phase3_arena] FAIL: %s" % reason)
	return false
