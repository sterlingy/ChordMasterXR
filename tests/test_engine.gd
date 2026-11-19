extends GutTest


func _engine(type: String, pool: ChordPool) -> ExerciseEngine:
	var e := ExerciseEngine.new()
	e.rng.seed = 1234
	e.configure(type, pool, PracticeStats.new())
	return e


func test_pool_filter_size() -> void:
	var p := ChordPool.from_preset("Major & minor")
	assert_eq(p.size(), 24)


func test_pool_key() -> void:
	var p := ChordPool.from_preset("C major: sevenths")
	var syms := []
	for e in p.entries():
		syms.append(e["chord"].symbol())
	assert_eq(syms, ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])
	assert_eq(p.entries()[1]["context"], "ii7 in C major")


func test_pool_custom_and_roundtrip() -> void:
	var p := ChordPool.new()
	p.source = "custom"
	p.custom = ["Cmaj7", "F#m7b5", "nonsense"]
	assert_eq(p.size(), 2)
	var q := ChordPool.from_dict(p.to_dict())
	assert_eq(q.size(), 2)


func test_prompts_stay_in_range() -> void:
	var e := _engine("random", ChordPool.from_preset("Ninths"))
	e.range_low = 48
	e.range_high = 72
	for i in 100:
		var pr := e.next_prompt()
		assert_not_null(pr)
		var v := pr.voicing()
		assert_true(v[0] >= 48 and v[-1] <= 72, "%s %s" % [pr.chord.symbol(), v])


func test_tiny_range_excludes_wide_chords() -> void:
	var e := _engine("random", ChordPool.from_preset("Ninths"))
	e.range_low = 60
	e.range_high = 70   # a 9th chord spans 14 semitones
	assert_eq(e.playable_entries().size(), 0)
	assert_null(e.next_prompt())


func test_no_immediate_repeat() -> void:
	var e := _engine("random", ChordPool.from_preset("Major & minor"))
	var last := ""
	for i in 200:
		var k := e.next_prompt().chord.key()
		assert_ne(k, last)
		last = k


func test_octave_mode_prompt() -> void:
	var e := _engine("random", ChordPool.from_preset("Major triads"))
	e.octave_mode = true
	e.target_octave = 3
	for i in 50:
		var pr := e.next_prompt()
		assert_eq(pr.target_octave, 3)
		assert_true(pr.matcher().evaluate_live(pr.voicing()) == ChordMatcher.Result.CORRECT)


func test_reference_voicing_always_passes_matcher() -> void:
	for t in ExerciseEngine.TYPES:
		var e := _engine(t, ChordPool.from_preset("All sevenths"))
		e.strict_inversion = true
		e.random_inversions = true
		for i in 40:
			var pr := e.next_prompt()
			if pr == null:
				break
			assert_eq(pr.matcher().evaluate_live(pr.voicing()), ChordMatcher.Result.CORRECT,
				"%s %s inv %d" % [t, pr.chord.symbol(), pr.inversion])


func test_two_five_one_sequence() -> void:
	var e := _engine("two_five_one", ChordPool.new())
	var syms := []
	for i in 6:
		syms.append(e.next_prompt().chord.symbol())
	assert_eq(syms, ["Dm7", "G7", "Cmaj7", "Gm7", "C7", "Fmaj7"])


func test_voice_leading_moves_little() -> void:
	var e := _engine("voice_leading", ChordPool.new())
	var prev: Array[int] = e.next_prompt().voicing()
	for i in 20:
		var v := e.next_prompt().voicing()
		var cost := 0
		for j in mini(v.size(), prev.size()):
			cost += absi(v[j] - prev[j])
		assert_true(cost <= 8, "movement %d from %s to %s" % [cost, prev, v])
		prev = v


func test_inversion_ladder() -> void:
	var p := ChordPool.new()
	p.source = "custom"
	p.custom = ["C"]
	var e := _engine("inversions", p)
	var invs := []
	for i in 3:
		var pr := e.next_prompt()
		assert_true(pr.strict_inversion)
		invs.append(pr.inversion)
	assert_eq(invs, [0, 1, 2])


func test_smart_weights_weak_chords() -> void:
	var stats := PracticeStats.new()
	for i in 10:
		stats.record("C:maj", "play", true, 800)
		stats.record("D:min", "play", false, 5000)
	assert_gt(stats.weight("D:min"), stats.weight("C:maj"))


func test_choices() -> void:
	var e := _engine("random", ChordPool.new())
	var answer := Theory.parse_chord("Cmaj7")
	for n in [3, 4, 5]:
		var ch := e.choices_for(answer, n)
		assert_eq(ch.size(), n)
		var keys := {}
		var found := false
		for c in ch:
			keys[c.key()] = true
			if c.equals(answer):
				found = true
		assert_true(found)
		assert_eq(keys.size(), n, "no duplicates")


func test_choices_exclude_same_sounding() -> void:
	var e := _engine("random", ChordPool.new())
	var answer := Theory.parse_chord("C6")
	for i in 30:
		for c in e.choices_for(answer, 5):
			assert_false(c.key() == "A:m7", "Am7 sounds identical to C6")


# --- octave toggles -------------------------------------------------------

func test_keyboard_octaves_for_common_keyboards() -> void:
	assert_eq(ChordPrompt.keyboard_octaves(36, 96), [2, 3, 4, 5, 6], "61 keys C2-C7")
	assert_eq(ChordPrompt.keyboard_octaves(21, 108), [0, 1, 2, 3, 4, 5, 6, 7], "88 keys A0-C8")
	assert_eq(ChordPrompt.keyboard_octaves(48, 72), [3, 4], "25 keys C3-C5 (C5 alone can't hold a chord)")


func test_prompts_only_start_in_enabled_octaves() -> void:
	for type in ["random", "smart"]:
		var e := ExerciseEngine.new()
		e.rng.seed = 99
		e.range_low = 36
		e.range_high = 96
		e.disabled_octaves = [2, 3, 5]
		e.random_inversions = true
		e.configure(type, ChordPool.from_preset("Major & minor"), PracticeStats.new())
		for i in 80:
			var pr := e.next_prompt()
			assert_not_null(pr)
			var o := ChordPrompt.bass_octave(pr.voicing())
			assert_true(o == 4 or o == 6, "%s %s starts in octave %d" % [type, pr.voicing(), o])
