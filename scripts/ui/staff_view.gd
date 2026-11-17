@tool
class_name StaffView
extends Control
## Draws a chord as whole notes on a treble, bass or grand staff.
##
## clef_mode:        "auto" | "treble" | "bass" | "grand"
## accidental_mode:  "accidentals"   – every altered note gets its accidental
##                   "key_signature" – a key signature is drawn and only notes
##                                     that differ from it get accidentals
##
## Music symbols come from the bundled Noto Music font (fonts/, SIL OFL).
## If it is missing, simple drawn fallbacks are used.

const TREBLE_BOTTOM := 30   # E4
const BASS_BOTTOM := 18     # G2
const SHARP_STEPS_TREBLE := [38, 35, 39, 36, 33, 37, 34]
const FLAT_STEPS_TREBLE := [34, 37, 33, 36, 32, 35, 31]

var clef_mode := "auto"
var accidental_mode := "accidentals"
var key_sig := 0                       # sharps (+) / flats (-)
var notes: Array = []                  # [[midi, Theory.Note], ...]
## Chord symbol written above the notes ("" = none; hidden in Name It mode
## until answered).
var chord_label := "":
	set(v):
		chord_label = v
		queue_redraw()
var note_color := Color(0.1, 0.1, 0.12)
var ink := Color(0.1, 0.1, 0.12)
var paper := Color(0.98, 0.97, 0.94)

var _music_font: Font
var _has_clefs := false
var _has_accidentals := false


func _ready() -> void:
	custom_minimum_size = Vector2(260, 160)
	# Redraw on moves too: the chord is centred on the window, not this box.
	item_rect_changed.connect(queue_redraw)
	_music_font = UITheme.music_font()
	_has_clefs = _music_font.has_char(0x1D11E) and _music_font.has_char(0x1D122)
	_has_accidentals = _music_font.has_char(0x266F) and _music_font.has_char(0x266D) and _music_font.has_char(0x266E)
	if Engine.is_editor_hint():
		# Editor preview: show a sample chord so the layout is visible.
		var c := Theory.parse_chord("Cmaj7")
		notes = c.voiced_tones(60, 0)


## Sets the chord to show. `voiced` is ChordPrompt.voiced_tones().
func show_chord(voiced: Array, p_key_sig := 0) -> void:
	notes = voiced
	key_sig = p_key_sig
	queue_redraw()


func clear() -> void:
	notes = []
	queue_redraw()


func resolved_clef() -> String:
	if clef_mode != "auto":
		return clef_mode
	if notes.is_empty():
		return "treble"
	var lo := 999
	var hi := -999
	for n in notes:
		lo = mini(lo, n[0])
		hi = maxi(hi, n[0])
	if lo >= 55:    # G3 and up: treble with at most two ledger lines below
		return "treble"
	if hi <= 64:    # E4 and down
		return "bass"
	return "grand"


## Where the chord is centred, in this control's x: the middle of the whole
## window (so chord, name and notes line up with the app), or of this
## control in the editor.
func center_x() -> float:
	if Engine.is_editor_hint() or not is_inside_tree():
		return size.x * 0.5
	return get_viewport_rect().size.x * 0.5 - get_global_rect().position.x


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), paper)
	var clef := resolved_clef()
	var staves := []   # [bottom_step, bottom_line_y, kind]
	var sp: float
	if clef == "grand":
		sp = minf(size.y / 22.0, size.x / 20.0)
		var treble_bottom_y := size.y * 0.5 - sp * 1.0
		var bass_top_y := size.y * 0.5 + sp * 1.0
		staves.append([TREBLE_BOTTOM, treble_bottom_y, "treble"])
		staves.append([BASS_BOTTOM, bass_top_y + sp * 4.0, "bass"])
	else:
		sp = minf(size.y / 13.0, size.x / 20.0)
		var bottom_y := size.y * 0.5 + sp * 2.0
		staves.append([TREBLE_BOTTOM if clef == "treble" else BASS_BOTTOM, bottom_y, clef])

	# --- lay out first: clef, key signature, accidentals, chord --------------
	# The staff is only as wide as it needs to be and sits around the chord,
	# so the clef is right next to the notes.
	var sig := key_sig if accidental_mode == "key_signature" else 0
	var head_w := sp * 1.35

	# Assign each note to a staff (grand: middle C and up on treble).
	var placed := []   # [step, y, Theory.Note, staff]
	for pair in notes:
		var midi: int = pair[0]
		var note: Theory.Note = pair[1]
		var st: Array = staves[0]
		if clef == "grand" and midi < 60:
			st = staves[1]
		var step := Theory.staff_step(note, midi)
		placed.append([step, _y_for(step, st, sp), note, st])
	placed.sort_custom(func(a, b): return a[0] < b[0])

	# Seconds: alternate notes shift right so heads don't overlap.
	var xoff := []
	var max_off := 0.0
	for i in placed.size():
		var off := 0.0
		if i > 0 and placed[i][0] - placed[i - 1][0] == 1 and placed[i][3] == placed[i - 1][3] and xoff[i - 1] == 0.0:
			off = head_w * 0.95
		xoff.append(off)
		max_off = maxf(max_off, off)

	# Accidentals, engraved the standard way: work from the outside in
	# (top, bottom, 2nd from top, 2nd from bottom, ...) and put each in the
	# column nearest the chord where its ink doesn't overlap anything
	# already there. This gives the familiar zig-zag and keeps chords compact.
	var accs := []   # [index into placed, alter]
	for i in placed.size():
		var shown := _accidental_to_show(placed[i][2], sig)
		if shown != 99:
			accs.append([i, shown])
	var order := []
	var lo := 0
	var hi := accs.size() - 1
	while lo <= hi:
		order.append(accs[hi])      # highest remaining (placed is low -> high)
		if lo != hi:
			order.append(accs[lo])  # lowest remaining
		lo += 1
		hi -= 1
	var fs := int(sp * 2.6)
	var gap := sp * 0.12
	var columns := []   # each: {"spans": [[top, bottom]], "width": float}
	var placement := []  # [y, alter, column]
	for item in order:
		var y: float = placed[item[0]][1]
		var alter: int = item[1]
		var span := _accidental_span(alter, y, fs, sp)
		var col := 0
		while true:
			if col >= columns.size():
				columns.append({"spans": [], "width": 0.0})
			var clash := false
			for other in columns[col]["spans"]:
				if span[0] < other[1] + gap and span[1] > other[0] - gap:
					clash = true
					break
			if not clash:
				break
			col += 1
		columns[col]["spans"].append(span)
		columns[col]["width"] = maxf(columns[col]["width"], _accidental_width(alter, fs, sp))
		placement.append([y, alter, col])
	# All columns start from one line: just clear of the widest notehead/ledger.
	var any_ledger := false
	for item in accs:
		var pl: Array = placed[item[0]]
		var st: Array = pl[3]
		if pl[0] < st[0] - 1 or pl[0] > st[0] + 9:
			any_ledger = true
	var acc_inset := head_w * 0.75 + sp * 0.15 if any_ledger else sp * 0.66 + sp * 0.22
	# How far left of the chord's centre line things reach.
	var acc_extent := head_w * 0.75   # notehead + ledger
	var col_inset := []
	var inset := acc_inset
	for c in columns.size():
		col_inset.append(inset)
		inset += columns[c]["width"] + sp * 0.18
	if not columns.is_empty():
		acc_extent = inset
	var clef_w := sp * 3.2
	var sig_w := absi(sig) * sp * 0.95 + (sp * 0.6 if sig != 0 else 0.0)
	var lead := sp * 0.6 + clef_w + sig_w + sp * 0.9 + acc_extent
	var tail := max_off + head_w * 0.75 + sp * 2.2

	var note_x := center_x()
	note_x = clampf(note_x, 12.0 + lead, maxf(12.0 + lead, size.x - 12.0 - tail))
	var left := note_x - lead
	var right := minf(size.x - 12.0, note_x + tail)

	# --- draw --------------------------------------------------------------
	for st in staves:
		for i in 5:
			var y: float = st[1] - i * sp
			draw_line(Vector2(left, y), Vector2(right, y), ink, maxf(1.0, sp * 0.08))
	if clef == "grand":
		draw_line(Vector2(left, staves[0][1] - 4 * sp), Vector2(left, staves[1][1]), ink, maxf(1.5, sp * 0.12))
	else:
		draw_line(Vector2(left, staves[0][1] - 4 * sp), Vector2(left, staves[0][1]), ink, maxf(1.0, sp * 0.08))
	draw_line(Vector2(right, staves[0][1] - 4 * sp), Vector2(right, staves[-1][1]), ink, maxf(1.0, sp * 0.08))

	# Clefs
	var x := left + sp * 0.6
	for st in staves:
		_draw_clef(st[2], x, st[1], sp)
	x += clef_w

	# Key signature
	if sig != 0:
		var n := absi(sig)
		for st in staves:
			var xs := x
			for i in n:
				var step: int = (SHARP_STEPS_TREBLE[i] if sig > 0 else FLAT_STEPS_TREBLE[i])
				if st[2] == "bass":
					step -= 14
				_draw_accidental(1 if sig > 0 else -1, xs + sp * 0.8, _y_for(step, st, sp), sp)
				xs += sp * 0.95

	if notes.is_empty():
		return

	# Ledger lines
	for i in placed.size():
		var p: Array = placed[i]
		_draw_ledgers(p[0], p[3], sp, note_x + xoff[i], head_w)

	for pl in placement:
		_draw_accidental(pl[1], note_x - col_inset[pl[2]], pl[0], sp)

	for i in placed.size():
		var p: Array = placed[i]
		_draw_whole_note(Vector2(note_x + xoff[i], p[1]), sp)

	# Chord symbol, centred over the chord, clear of the staff and notes.
	if chord_label != "":
		var font := UITheme.ui_font()
		var label_fs := int(clampf(sp * 1.8, 12.0, 64.0))
		var staff_top: float = staves[0][1] - 4.0 * sp
		var top_note: float = placed[-1][1] - sp * 0.6
		var baseline := minf(staff_top, top_note) - sp * 1.6
		baseline = maxf(baseline, label_fs * 0.95)
		var w := font.get_string_size(chord_label, HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs).x
		draw_string(font, Vector2(note_x - w / 2.0, baseline), chord_label, HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs, ink)


func _y_for(step: int, st: Array, sp: float) -> float:
	return st[1] - (step - st[0]) * sp * 0.5


func _accidental_to_show(note: Theory.Note, sig: int) -> int:
	## Returns alteration to draw, 0 for a natural sign, 99 for none.
	if sig == 0:
		return 99 if note.alter == 0 else note.alter
	var implied := Theory.key_sig_alter(sig, note.letter)
	if note.alter == implied:
		return 99
	return note.alter


func _draw_ledgers(step: int, st: Array, sp: float, cx: float, head_w: float) -> void:
	var bottom: int = st[0]
	var top: int = bottom + 8
	var w := head_w * 0.75
	var thick := maxf(1.0, sp * 0.08)
	var s := bottom - 2
	while s >= step:
		var y := _y_for(s, st, sp)
		draw_line(Vector2(cx - w, y), Vector2(cx + w, y), ink, thick)
		s -= 2
	s = top + 2
	while s <= step:
		var y := _y_for(s, st, sp)
		draw_line(Vector2(cx - w, y), Vector2(cx + w, y), ink, thick)
		s += 2


func _draw_whole_note(c: Vector2, sp: float) -> void:
	var rx := sp * 0.66
	var ry := sp * 0.44
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	var steps := 28
	for i in steps:
		var a := TAU * i / steps
		outer.append(c + Vector2(cos(a) * rx, sin(a) * ry))
		# tilted inner hole gives the classic whole-note look
		var ia := Vector2(cos(a) * rx * 0.5, sin(a) * ry * 0.72).rotated(-0.6)
		inner.append(c + ia)
	draw_colored_polygon(outer, note_color)
	draw_colored_polygon(inner, paper)


func _draw_clef(kind: String, x: float, bottom_y: float, sp: float) -> void:
	if _has_clefs:
		var ch := "𝄞" if kind == "treble" else "𝄢"
		var fs := int(sp * (4.4 if kind == "treble" else 3.4))
		# Baseline: treble curls round G (2nd line), bass dots straddle F (4th line)
		var baseline := bottom_y + sp * (0.9 if kind == "treble" else -0.9)
		draw_string(_music_font, Vector2(x, baseline), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
	else:
		var fs := int(sp * 2.6)
		var label := "G" if kind == "treble" else "F"
		var line_y := bottom_y - sp * (1.0 if kind == "treble" else 3.0)
		draw_string(get_theme_default_font(), Vector2(x, line_y + sp * 0.9), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


var _ink_cache := {}


func _accidental_glyph(alter: int) -> String:
	match alter:
		-2: return "𝄫" if _music_font.has_char(0x1D12B) else "♭"
		-1: return "♭"
		0: return "♮"
		1: return "♯"
		2: return "𝄪" if _music_font.has_char(0x1D12A) else "♯"
	return ""


## Ink bounds of a glyph relative to its baseline origin, measured from the
## font itself so placement doesn't depend on hand-tuned offsets.
func _glyph_ink(glyph: String, fs: int) -> Rect2:
	var key := "%s@%d" % [glyph, fs]
	if _ink_cache.has(key):
		return _ink_cache[key]
	var r := Rect2()
	var rids: Array = _music_font.get_rids()
	var ts := TextServerManager.get_primary_interface()
	for rid in rids:
		var cp := glyph.unicode_at(0)
		if not ts.font_has_char(rid, cp):
			continue
		var sz := Vector2i(fs, 0)
		var gi := ts.font_get_glyph_index(rid, fs, cp, 0)
		ts.font_render_glyph(rid, sz, gi)
		var off := ts.font_get_glyph_offset(rid, sz, gi)
		var gs := ts.font_get_glyph_size(rid, sz, gi)
		if gs.x > 0 and gs.y > 0:
			r = Rect2(off, gs)
		break
	if r.size == Vector2.ZERO:
		# Fallback estimate if the text server can't report metrics.
		r = Rect2(Vector2(0, -fs * 0.7), Vector2(fs * 0.35, fs * 0.9))
	_ink_cache[key] = r
	return r


## Draws an accidental whose ink ends at `right_x`, vertically anchored on
## the note at `y`: sharps/naturals are centred on it; for flats the middle
## of the bowl (lower part of the glyph) sits on it, as in engraved music.
## Vertical extent [top, bottom] of an accidental drawn for a note at y.
func _accidental_span(alter: int, y: float, fs: int, sp: float) -> Array:
	if _has_accidentals:
		var box := _glyph_ink(_accidental_glyph(alter), fs)
		var anchor := 0.72 if alter < 0 else 0.5
		return [y - box.size.y * anchor, y + box.size.y * (1.0 - anchor)]
	return [y - sp * 1.4, y + sp * 1.0]


func _accidental_width(alter: int, fs: int, sp: float) -> float:
	if _has_accidentals:
		var w := _glyph_ink(_accidental_glyph(alter), fs).size.x
		return w * (1.9 if alter == -2 and _accidental_glyph(alter) == "♭" else 1.0)
	return sp * 0.9


func _draw_accidental(alter: int, right_x: float, y: float, sp: float) -> void:
	if _has_accidentals:
		var glyph := _accidental_glyph(alter)
		var fs := int(sp * 2.6)
		var box := _glyph_ink(glyph, fs)
		var anchor := 0.72 if alter < 0 else 0.5
		var base_x := right_x - (box.position.x + box.size.x)
		var base_y := y - (box.position.y + box.size.y * anchor)
		draw_string(_music_font, Vector2(base_x, base_y), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
		if alter == -2 and glyph == "♭":
			draw_string(_music_font, Vector2(base_x - box.size.x * 0.9, base_y), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
		return
	_draw_accidental_shape(alter, right_x - sp * 0.45, y, sp)


func _draw_accidental_shape(alter: int, x: float, y: float, sp: float) -> void:
	# Drawn fallbacks (no music font available), centred on (x, y).
	var t := maxf(1.0, sp * 0.12)
	match alter:
		1, 2:
			draw_line(Vector2(x - sp * 0.2, y - sp), Vector2(x - sp * 0.2, y + sp), ink, t)
			draw_line(Vector2(x + sp * 0.2, y - sp), Vector2(x + sp * 0.2, y + sp), ink, t)
			draw_line(Vector2(x - sp * 0.45, y - sp * 0.2), Vector2(x + sp * 0.45, y - sp * 0.4), ink, t * 1.6)
			draw_line(Vector2(x - sp * 0.45, y + sp * 0.4), Vector2(x + sp * 0.45, y + sp * 0.2), ink, t * 1.6)
		-1, -2:
			draw_line(Vector2(x - sp * 0.3, y - sp * 1.4), Vector2(x - sp * 0.3, y + sp * 0.4), ink, t)
			draw_arc(Vector2(x - sp * 0.05, y + sp * 0.05), sp * 0.32, -PI * 0.6, PI * 0.7, 10, ink, t)
		0:
			draw_line(Vector2(x - sp * 0.25, y - sp * 1.0), Vector2(x - sp * 0.25, y + sp * 0.4), ink, t)
			draw_line(Vector2(x + sp * 0.25, y - sp * 0.4), Vector2(x + sp * 0.25, y + sp * 1.0), ink, t)
			draw_line(Vector2(x - sp * 0.25, y - sp * 0.1), Vector2(x + sp * 0.25, y - sp * 0.3), ink, t * 1.6)
			draw_line(Vector2(x - sp * 0.25, y + sp * 0.4), Vector2(x + sp * 0.25, y + sp * 0.2), ink, t * 1.6)
