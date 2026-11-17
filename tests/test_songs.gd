extends GutTest

const G = SongEngine.Grade


func _song(bars: Array, bpm := 60.0) -> Song:
	return Song.from_dict({"title": "T", "bpm": bpm, "beats_per_bar": 4,
		"sections": {"A": bars}, "order": ["A"]})


func test_library_loads_without_errors() -> void:
	var lib := Song.load_library()
	assert_eq(lib.size(), 6)
	var decades := {}
	for s in lib:
		assert_eq(s.errors.size(), 0, "%s errors: %s" % [s.title, s.errors])
		assert_gt(s.events.size(), 0)
		decades[s.decade] = decades.get(s.decade, 0) + 1
	assert_eq(decades.get("70s", 0), 3)
	assert_eq(decades.get("Beatles", 0), 3)


func test_split_bars() -> void:
	var s := _song(["F C", "G"])
	assert_eq(s.events.size(), 3)
	assert_eq(s.events[0]["beats"], 2.0)
	assert_eq(s.events[1]["beat"], 2.0)
	assert_eq(s.events[2]["beat"], 4.0)
	assert_eq(s.events[2]["beats"], 4.0)
	assert_eq(s.total_beats, 8.0)


func test_bad_chord_reported() -> void:
	var s := _song(["C", "Hfoo"])
	assert_eq(s.errors.size(), 1)


func test_timing_grades() -> void:
	assert_eq(SongEngine.grade_for(0.0), G.PERFECT)
	assert_eq(SongEngine.grade_for(-0.05), G.PERFECT)
	assert_eq(SongEngine.grade_for(0.1), G.GREAT)
	assert_eq(SongEngine.grade_for(-0.18), G.GOOD)
	assert_eq(SongEngine.grade_for(0.5), G.OK)


func test_hit_on_time() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C", "G"]))   # 60 bpm: C at 0 s, G at 4 s
	e.note_struck()
	assert_eq(e.on_notes([60, 64, 67], 0.03), 0)
	assert_eq(e.targets[0]["grade"], G.PERFECT)
	assert_almost_eq(e.targets[0]["offset"], 0.03, 0.0001)


func test_early_hit_goes_to_next_chord() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C", "G"]))
	e.note_struck()
	e.on_notes([60, 64, 67], 0.0)
	e.note_struck()
	# G played 100 ms early still counts for the G target
	assert_eq(e.on_notes([55, 59, 62], 3.9), 1)
	assert_eq(e.targets[1]["grade"], G.GREAT)
	assert_lt(e.targets[1]["offset"], 0.0)


func test_needs_restrike() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C", "C"]))
	e.note_struck()
	assert_eq(e.on_notes([60, 64, 67], 0.0), 0)
	# still holding — the second C needs a new strike
	assert_eq(e.on_notes([60, 64, 67], 4.0), -1)
	e.note_struck()
	assert_eq(e.on_notes([60, 64, 67], 4.02), 1)


func test_wrong_chord_does_not_land() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C"]))
	e.note_struck()
	assert_eq(e.on_notes([60, 63, 67], 0.0), -1)


func test_misses_and_results() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C", "G", "Am", "F"]))
	e.note_struck()
	e.on_notes([60, 64, 67], 0.0)
	e.note_struck()
	e.on_notes([55, 59, 62], 4.15)
	var missed := e.update(16.5)
	assert_eq(missed, [2, 3])
	var r := e.results()
	assert_eq(r["hits"], 2)
	assert_eq(r["total"], 4)
	assert_eq(r["points"], 150)
	assert_almost_eq(r["avg_abs_ms"], 75.0, 0.5)
	assert_eq(r["rank"], "D")


func test_tempo_scale() -> void:
	var e := SongEngine.new()
	e.setup(_song(["C", "G"], 120.0), 0.5)   # half speed -> 60 bpm
	assert_almost_eq(e.targets[1]["t"], 4.0, 0.0001)
	assert_almost_eq(e.count_in_seconds(), 4.0, 0.0001)


func _syms(s: Song, n: int) -> Array:
	var out := []
	for i in mini(n, s.events.size()):
		out.append(s.events[i]["chord"].symbol())
	return out


func _lib(id: String) -> Song:
	for s in Song.load_library():
		if s.id == id:
			return s
	return null


func test_transpose_major_up() -> void:
	var s := _lib("let_it_be").transposed(2)
	assert_eq(s.key, "D")
	assert_eq(_syms(s, 4), ["D", "A", "Bm", "G"])
	assert_eq(s.key_name(), "D major")
	assert_eq(s.key_signature(), 2)


func test_transpose_minor_spelling() -> void:
	var s := _lib("hotel_california").transposed(1)
	assert_eq(s.key, "Cm")
	assert_eq(_syms(s, 8), ["Cm", "G", "Bb", "F", "Ab", "Eb", "Fm", "G"])
	assert_eq(s.key_signature(), -3)


func test_transpose_down_and_sevenths() -> void:
	var s := _lib("hey_jude").transposed(-1)
	assert_eq(s.key, "E")
	assert_eq(_syms(s, 5), ["E", "B", "B7", "E", "A"])


func test_transpose_tritone_and_wrap() -> void:
	var s := _lib("imagine").transposed(6)
	assert_eq(s.key, "F#")
	assert_eq(_syms(_lib("imagine").transposed(18), 3), _syms(s, 3))
	for e in s.events:
		assert_true(absi(e["chord"].root.alter) <= 1, "no double accidentals: " + e["chord"].symbol())


func test_transpose_zero_is_identity() -> void:
	var o := _lib("yesterday")
	assert_eq(_syms(o.transposed(0), o.events.size()), _syms(o, o.events.size()))


func test_every_song_every_key_spells_cleanly() -> void:
	for s in Song.load_library():
		for n in range(-6, 7):
			var t := s.transposed(n)
			for e in t.events:
				var c: Theory.Chord = e["chord"]
				assert_true(absi(c.root.alter) <= 1, "%s %+d %s" % [s.title, n, c.symbol()])
				# Chord tones should never need more than a double accidental.
				for tone in c.tones():
					assert_true(absi(tone.alter) <= 2)
