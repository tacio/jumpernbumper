class_name RetroUI
extends RefCounted

## Shared retro pixel UI theme builder, bunny palette metadata, and autoload lookup helpers
## tailored for the 400x256 virtual viewport.

const BUNNY_SHEET_PATH := "res://assets/sprites/bunny_sheet.png"
const BUNNY_NAMES: Array[String] = ["Dott", "Jiffy", "Fizz", "Mijji"]
const BUNNY_COLORS: Array[Color] = [
	Color(0.84, 0.56, 0.34, 1.0), # Dott (brown/tan)
	Color(0.95, 0.76, 0.24, 1.0), # Jiffy (gold)
	Color(0.94, 0.94, 0.98, 1.0), # Fizz (white)
	Color(0.45, 0.64, 0.92, 1.0), # Mijji (blue)
]

static var _cached_theme: Theme
static var _cached_bunny_sheet: Texture2D


## Returns a shared pixel-crisp Theme sized for 400x256 virtual resolution.
static func get_theme() -> Theme:
	if _cached_theme != null:
		return _cached_theme

	var t := Theme.new()
	t.default_font_size = 8

	var panel_bg := _flat_box(Color(0.09, 0.13, 0.18, 0.92), Color(0.28, 0.39, 0.48, 1.0), 1, 5)
	var card_bg := _flat_box(Color(0.13, 0.18, 0.25, 0.95), Color(0.32, 0.44, 0.54, 1.0), 1, 3)

	var btn_norm := _flat_box(Color(0.22, 0.48, 0.28, 1.0), Color(0.11, 0.22, 0.14, 1.0), 1, 4, 2)
	var btn_hover := _flat_box(Color(0.28, 0.58, 0.35, 1.0), Color(0.95, 0.80, 0.28, 1.0), 1, 4, 2)
	var btn_press := _flat_box(Color(0.16, 0.36, 0.22, 1.0), Color(0.95, 0.80, 0.28, 1.0), 1, 4, 2)
	var btn_dis := _flat_box(Color(0.18, 0.21, 0.26, 0.85), Color(0.25, 0.29, 0.35, 1.0), 1, 4, 2)

	var edit_norm := _flat_box(Color(0.06, 0.09, 0.13, 1.0), Color(0.34, 0.46, 0.56, 1.0), 1, 4, 2)
	var edit_focus := _flat_box(Color(0.07, 0.10, 0.15, 1.0), Color(0.95, 0.80, 0.28, 1.0), 1, 4, 2)

	t.set_stylebox("panel", "PanelContainer", panel_bg)
	t.set_stylebox("normal", "Button", btn_norm)
	t.set_stylebox("hover", "Button", btn_hover)
	t.set_stylebox("pressed", "Button", btn_press)
	t.set_stylebox("focus", "Button", btn_hover)
	t.set_stylebox("disabled", "Button", btn_dis)

	t.set_color("font_color", "Button", Color(0.97, 0.95, 0.88, 1.0))
	t.set_color("font_hover_color", "Button", Color(1.0, 0.98, 0.82, 1.0))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.92, 0.58, 1.0))
	t.set_color("font_disabled_color", "Button", Color(0.55, 0.59, 0.65, 1.0))
	t.set_font_size("font_size", "Button", 8)

	t.set_stylebox("normal", "LineEdit", edit_norm)
	t.set_stylebox("focus", "LineEdit", edit_focus)
	t.set_color("font_color", "LineEdit", Color(0.96, 0.96, 0.92, 1.0))
	t.set_color("font_placeholder_color", "LineEdit", Color(0.52, 0.58, 0.66, 1.0))
	t.set_font_size("font_size", "LineEdit", 8)

	t.set_color("font_color", "Label", Color(0.95, 0.93, 0.86, 1.0))
	t.set_font_size("font_size", "Label", 8)

	t.set_color("font_color", "CheckBox", Color(0.95, 0.93, 0.86, 1.0))
	t.set_color("font_disabled_color", "CheckBox", Color(0.58, 0.62, 0.68, 1.0))
	t.set_font_size("font_size", "CheckBox", 8)

	t.set_stylebox("normal", "OptionButton", card_bg)
	t.set_stylebox("hover", "OptionButton", btn_hover)
	t.set_stylebox("pressed", "OptionButton", btn_press)
	t.set_stylebox("disabled", "OptionButton", btn_dis)
	t.set_font_size("font_size", "OptionButton", 8)

	t.set_stylebox("scroll", "VScrollBar", _flat_box(Color(0.06, 0.08, 0.12, 0.9), Color(0.2, 0.25, 0.3, 1.0), 1, 1))
	t.set_stylebox("grabber", "VScrollBar", _flat_box(Color(0.36, 0.52, 0.64, 1.0), Color(0.2, 0.3, 0.4, 1.0), 1, 1))
	t.set_stylebox("grabber_highlight", "VScrollBar", _flat_box(Color(0.5, 0.7, 0.82, 1.0), Color(0.95, 0.8, 0.28, 1.0), 1, 1))

	_cached_theme = t
	return _cached_theme


## Returns a crisp dark card StyleBoxFlat for list rows and slot cards.
static func make_card_style(border_color: Color = Color(0.32, 0.44, 0.54, 1.0), bg_color: Color = Color(0.13, 0.18, 0.25, 0.95)) -> StyleBoxFlat:
	return _flat_box(bg_color, border_color, 1, 3, 2)


## Returns a secondary danger/mute button StyleBoxFlat.
static func make_button_style(bg: Color, border: Color = Color(0.1, 0.1, 0.14, 1.0)) -> StyleBoxFlat:
	return _flat_box(bg, border, 1, 4, 2)


## Returns an AtlasTexture for bunny `slot` (0..3) and animation `frame` (0..7).
static func make_bunny_atlas(slot: int, frame: int = 0) -> AtlasTexture:
	if _cached_bunny_sheet == null:
		_cached_bunny_sheet = load(BUNNY_SHEET_PATH) as Texture2D
	var atlas := AtlasTexture.new()
	atlas.atlas = _cached_bunny_sheet
	var safe_slot := clampi(slot, 0, 3)
	var safe_frame := clampi(frame, 0, 7)
	atlas.region = Rect2(float(safe_frame * 16), float(safe_slot * 16), 16.0, 16.0)
	return atlas


## Safely looks up the SpacetimeClient autoload node if present in the active tree.
static func get_client(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_node_or_null("/root/SpacetimeClient")


## Safely looks up the AudioManager autoload node if present in the active tree.
static func get_audio(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_node_or_null("/root/AudioManager")


static func _flat_box(
	bg: Color,
	border: Color,
	border_w: int = 1,
	margin_h: int = 4,
	margin_v: int = -1
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	var mv := margin_h if margin_v < 0 else margin_v
	sb.content_margin_left = margin_h
	sb.content_margin_right = margin_h
	sb.content_margin_top = mv
	sb.content_margin_bottom = mv
	return sb
