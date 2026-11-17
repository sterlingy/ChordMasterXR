class_name UITheme
extends RefCounted
## Shared colours and helpers for the 2D UI (also used on XR panels).
## The scenes use res://ui/theme.tres — edit that in the editor to restyle.
## build() is what generated it, kept for code-created popups/windows.

const BG := Color(0.075, 0.08, 0.10)
const PANEL := Color(0.13, 0.14, 0.17)
const PANEL_HI := Color(0.18, 0.19, 0.23)
const TEXT := Color(0.93, 0.93, 0.95)
const MUTED := Color(0.62, 0.64, 0.70)
const ACCENT := Color(0.36, 0.62, 1.0)
const GOOD := Color(0.35, 0.85, 0.5)
const BAD := Color(0.95, 0.38, 0.38)
const WARN := Color(1.0, 0.75, 0.3)


const MUSIC_FONT_PATH := "res://fonts/NotoMusic-Regular.ttf"

static var _music: Font
static var _ui: Font


## Bundled music-symbol font (works everywhere, including web).
static func music_font() -> Font:
	if _music == null:
		_music = load(MUSIC_FONT_PATH) if ResourceLoader.exists(MUSIC_FONT_PATH) else ThemeDB.fallback_font
	return _music


## Godot's default UI font with the music font as a fallback, so chord
## names like E♭maj7 render even where there are no system fonts (web).
static func ui_font() -> Font:
	if _ui == null:
		var f := FontVariation.new()
		f.base_font = ThemeDB.fallback_font
		f.fallbacks = [music_font()]
		_ui = f
	return _ui


static func build(base_size := 18) -> Theme:
	var t := Theme.new()
	t.default_font_size = base_size
	t.default_font = ui_font()

	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_corner_radius_all(12)
	panel.set_content_margin_all(14)
	t.set_stylebox("panel", "PanelContainer", panel)

	var popup := panel.duplicate()
	popup.bg_color = PANEL_HI
	popup.set_border_width_all(1)
	popup.border_color = Color(1, 1, 1, 0.08)
	t.set_stylebox("panel", "PopupPanel", popup)

	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var b := StyleBoxFlat.new()
		b.set_corner_radius_all(8)
		b.set_content_margin_all(10)
		b.content_margin_left = 16
		b.content_margin_right = 16
		match state:
			"normal": b.bg_color = PANEL_HI
			"hover": b.bg_color = PANEL_HI.lightened(0.12)
			"pressed": b.bg_color = ACCENT.darkened(0.25)
			"disabled": b.bg_color = PANEL_HI.darkened(0.3)
			"focus":
				b.bg_color = Color(0, 0, 0, 0)
				b.draw_center = false
				b.set_border_width_all(2)
				b.border_color = ACCENT
		for cls in ["Button", "OptionButton", "MenuButton"]:
			t.set_stylebox(state, cls, b)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_color", "CheckButton", TEXT)
	return t


static func label(text: String, size := 18, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func heading(text: String) -> Label:
	return label(text, 20, ACCENT)
