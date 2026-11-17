@tool
class_name PianoKeyboard
extends Control
## On-screen piano keyboard.
##
## Shows held notes, hint notes and wrong notes, and accepts mouse/touch
## input in two styles:
##   "play"   – press and hold, like a real key (sends note on/off)
##   "select" – click to toggle a note in/out of the selection

signal key_pressed(midi: int)
signal key_released(midi: int)
signal selection_changed(selected: Array)

const WHITE_PCS := [0, 2, 4, 5, 7, 9, 11]

@export var low := 48:
	set(v):
		low = v
		queue_redraw()
@export var high := 84:
	set(v):
		high = v
		queue_redraw()
@export var interaction := "play"   # "play" | "select" | "none"
@export var show_c_labels := true

var held: Array = []
var hints: Array = []
var wrong: Array = []
var correct_flash: Array = []
var selected: Array = []
var out_of_range_dim := true

var _mouse_note := -1

const C_WHITE := Color(0.97, 0.97, 0.95)
const C_BLACK := Color(0.12, 0.12, 0.14)
const C_HELD := Color(0.30, 0.60, 1.00)
const C_SELECTED := Color(1.00, 0.75, 0.25)
const C_HINT := Color(0.35, 0.85, 0.55)
const C_WRONG := Color(0.95, 0.30, 0.30)
const C_CORRECT := Color(0.30, 0.90, 0.45)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(300, 120)
	resized.connect(queue_redraw)


static func is_white(midi: int) -> bool:
	return WHITE_PCS.has(posmod(midi, 12))


func _first_white() -> int:
	var m := low
	while not is_white(m):
		m -= 1
	return m


func _last_white() -> int:
	var m := high
	while not is_white(m):
		m += 1
	return m


func _white_count() -> int:
	var n := 0
	for m in range(_first_white(), _last_white() + 1):
		if is_white(m):
			n += 1
	return maxi(n, 1)


func _white_w() -> float:
	return size.x / _white_count()


## Rect for a key in local coordinates.
func key_rect(midi: int) -> Rect2:
	var ww := _white_w()
	var idx := 0
	for m in range(_first_white(), midi):
		if is_white(m):
			idx += 1
	if is_white(midi):
		return Rect2(idx * ww, 0, ww, size.y)
	var bw := ww * 0.6
	return Rect2(idx * ww - bw / 2.0, 0, bw, size.y * 0.62)


func _key_color(midi: int, base: Color) -> Color:
	if correct_flash.has(midi):
		return C_CORRECT
	if wrong.has(midi):
		return C_WRONG
	if held.has(midi):
		return C_HELD
	if selected.has(midi):
		return C_SELECTED
	if hints.has(midi):
		return base.lerp(C_HINT, 0.65)
	return base


func _draw() -> void:
	var fw := _first_white()
	var lw := _last_white()
	var font := get_theme_default_font()
	var fsize := int(clampf(_white_w() * 0.38, 8, 16))
	for m in range(fw, lw + 1):
		if not is_white(m):
			continue
		var r := key_rect(m)
		var col := _key_color(m, C_WHITE)
		if out_of_range_dim and (m < low or m > high):
			col = col.darkened(0.45)
		draw_rect(r.grow(-1), col)
		if show_c_labels and posmod(m, 12) == 0:
			draw_string(font, Vector2(r.position.x, r.end.y - 6), Theory.midi_name(m),
				HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fsize, Color(0.3, 0.3, 0.35))
	for m in range(fw, lw + 1):
		if is_white(m):
			continue
		var r := key_rect(m)
		var col := _key_color(m, C_BLACK)
		if out_of_range_dim and (m < low or m > high):
			col = col.lightened(0.15)
		draw_rect(r, col)
	# Hint dots on top so they read on both key colours.
	for m in hints:
		if m < fw or m > lw or held.has(m) or wrong.has(m):
			continue
		var r := key_rect(int(m))
		draw_circle(Vector2(r.get_center().x, r.end.y - r.size.x * 0.5 - 14), r.size.x * 0.18, C_HINT)


func note_at(pos: Vector2) -> int:
	# Black keys sit on top, so test them first.
	for m in range(_first_white(), _last_white() + 1):
		if not is_white(m) and key_rect(m).has_point(pos):
			return m
	for m in range(_first_white(), _last_white() + 1):
		if is_white(m) and key_rect(m).has_point(pos):
			return m
	return -1


func _gui_input(event: InputEvent) -> void:
	if interaction == "none" or Engine.is_editor_hint():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var m := note_at(event.position)
			if m < 0:
				return
			if interaction == "select":
				toggle_selected(m)
			else:
				_mouse_note = m
				key_pressed.emit(m)
		elif _mouse_note >= 0:
			key_released.emit(_mouse_note)
			_mouse_note = -1
		accept_event()
	elif event is InputEventMouseMotion and _mouse_note >= 0 and interaction == "play":
		var m := note_at(event.position)
		if m >= 0 and m != _mouse_note:
			key_released.emit(_mouse_note)
			_mouse_note = m
			key_pressed.emit(m)


func toggle_selected(m: int) -> void:
	if selected.has(m):
		selected.erase(m)
	else:
		selected.append(m)
		selected.sort()
	selection_changed.emit(selected.duplicate())
	queue_redraw()


func clear_selection() -> void:
	selected.clear()
	selection_changed.emit([])
	queue_redraw()


func set_held(notes: Array) -> void:
	held = notes.duplicate()
	queue_redraw()


func set_hints(notes: Array) -> void:
	hints = notes.duplicate()
	queue_redraw()


func set_wrong(notes: Array) -> void:
	wrong = notes.duplicate()
	queue_redraw()


func flash_correct(notes: Array, seconds := 0.5) -> void:
	correct_flash = notes.duplicate()
	queue_redraw()
	await get_tree().create_timer(seconds).timeout
	correct_flash = []
	queue_redraw()
