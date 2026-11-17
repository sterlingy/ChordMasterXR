extends GutTest

const R = ChordMatcher.Result


func _m(sym: String) -> ChordMatcher:
	return ChordMatcher.new(Theory.parse_chord(sym))


func test_root_position_correct() -> void:
	assert_eq(_m("C").evaluate_live([60, 64, 67]), R.CORRECT)


func test_rolled_chord_pending_then_correct() -> void:
	var m := _m("Cmaj7")
	assert_eq(m.evaluate_live([60]), R.PENDING)
	assert_eq(m.evaluate_live([60, 64]), R.PENDING)
	assert_eq(m.evaluate_live([60, 64, 67]), R.PENDING)
	assert_eq(m.evaluate_live([60, 64, 67, 71]), R.CORRECT)


func test_wrong_note_fails_immediately() -> void:
	assert_eq(_m("C").evaluate_live([60, 63]), R.WRONG_NOTE)
	assert_eq(_m("C").evaluate_live([60, 64, 67, 69]), R.WRONG_NOTE)


func test_doubling_allowed() -> void:
	assert_eq(_m("C").evaluate_live([48, 60, 64, 67, 72]), R.CORRECT)


func test_inversion_accepted_when_not_strict() -> void:
	assert_eq(_m("C").evaluate_live([64, 67, 72]), R.CORRECT)


func test_strict_inversion() -> void:
	var m := _m("C")
	m.strict_inversion = true
	m.inversion = 1
	assert_eq(m.evaluate_live([60, 64, 67]), R.WRONG_INVERSION, "root position when 1st asked")
	assert_eq(m.evaluate_live([64, 67, 72]), R.CORRECT)


func test_octave_mode_root_octave() -> void:
	var m := _m("G")
	m.octave_mode = true
	m.target_octave = 3
	assert_eq(m.evaluate_live([55, 59, 62]), R.CORRECT)   # G3 B3 D4
	assert_eq(m.evaluate_live([67, 71, 74]), R.WRONG_OCTAVE)
	assert_eq(m.evaluate_live([59, 62, 67]), R.WRONG_OCTAVE, "no G in octave 3")


func test_submit_incomplete() -> void:
	assert_eq(_m("C").evaluate_submit([60, 64]), R.INCOMPLETE)
	assert_eq(_m("C").evaluate_submit([60, 64, 67]), R.CORRECT)


func test_enharmonic_input_is_fine() -> void:
	# MIDI has no spelling: Cb major is played on B, D#, F#
	assert_eq(_m("Cb").evaluate_live([59, 63, 66]), R.CORRECT)


func test_wrong_notes_list() -> void:
	assert_eq(_m("C").wrong_notes([60, 61, 64, 66]), [61, 66])
