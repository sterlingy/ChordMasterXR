extends GutTest


func _names(notes: Array) -> Array:
	var out := []
	for n in notes:
		out.append(n.name())
	return out


func _chord(sym: String) -> Theory.Chord:
	var c := Theory.parse_chord(sym)
	assert_not_null(c, "parse " + sym)
	return c


func test_parse_note() -> void:
	assert_eq(Theory.parse_note("C").pc(), 0)
	assert_eq(Theory.parse_note("F#").pc(), 6)
	assert_eq(Theory.parse_note("Bb").pc(), 10)
	assert_eq(Theory.parse_note("Cb").pc(), 11)
	assert_eq(Theory.parse_note("B#").pc(), 0)
	assert_eq(Theory.parse_note("Ebb").pc(), 2)
	assert_eq(Theory.parse_note("E♭").pc(), 3)
	assert_null(Theory.parse_note("H"))


func test_triad_spelling() -> void:
	assert_eq(_names(_chord("C").tones()), ["C", "E", "G"])
	assert_eq(_names(_chord("Abm").tones()), ["Ab", "Cb", "Eb"])
	assert_eq(_names(_chord("F#").tones()), ["F#", "A#", "C#"])
	assert_eq(_names(_chord("Bdim").tones()), ["B", "D", "F"])
	assert_eq(_names(_chord("Ebaug").tones()), ["Eb", "G", "B"])
	assert_eq(_names(_chord("G#m").tones()), ["G#", "B", "D#"])
	assert_eq(_names(_chord("Dsus4").tones()), ["D", "G", "A"])


func test_seventh_spelling() -> void:
	assert_eq(_names(_chord("Cmaj7").tones()), ["C", "E", "G", "B"])
	assert_eq(_names(_chord("Bbm7").tones()), ["Bb", "Db", "F", "Ab"])
	assert_eq(_names(_chord("F#m7b5").tones()), ["F#", "A", "C", "E"])
	assert_eq(_names(_chord("Bdim7").tones()), ["B", "D", "F", "Ab"])
	assert_eq(_names(_chord("C#dim7").tones()), ["C#", "E", "G", "Bb"])
	assert_eq(_names(_chord("Db7").tones()), ["Db", "F", "Ab", "Cb"])
	assert_eq(_names(_chord("Gm(maj7)").tones()), ["G", "Bb", "D", "F#"])


func test_ninths() -> void:
	assert_eq(_names(_chord("Cmaj9").tones()), ["C", "E", "G", "B", "D"])
	assert_eq(_names(_chord("Ebm9").tones()), ["Eb", "Gb", "Bb", "Db", "F"])


func test_parse_chord_symbols() -> void:
	assert_eq(_chord("Bb").quality, "maj")
	assert_eq(_chord("Bb").root.name(), "Bb")
	assert_eq(_chord("Bbm7b5").quality, "m7b5")
	assert_eq(_chord("Bm7♭5").root.name(), "B")
	assert_eq(_chord("Eb7sus4").quality, "7sus4")
	assert_null(Theory.parse_chord("Cfoo"))


func test_symbols_and_speech() -> void:
	assert_eq(_chord("Cmaj7").pretty(), "Cmaj7")
	assert_eq(_chord("F#m7b5").pretty(), "F♯m7♭5")
	assert_eq(_chord("Ebm").spoken(), "E flat minor")
	assert_eq(_chord("C#m7b5").spoken(), "C sharp minor seven flat five")


func test_voicing_and_inversions() -> void:
	var c := _chord("C")
	assert_eq(c.voicing(60, 0), [60, 64, 67])
	assert_eq(c.voicing(60, 1), [64, 67, 72])
	assert_eq(c.voicing(60, 2), [67, 72, 76])
	var c7 := _chord("G7")
	assert_eq(c7.voicing(55, 3), [65, 67, 71, 74])
	assert_eq(c7.bass_pc(3), 5)


func test_octaves() -> void:
	assert_eq(Theory.midi_octave(60), 4)
	assert_eq(Theory.midi_octave(59), 3)
	assert_eq(Theory.midi_name(60), "C4")
	# B#3 sounds as C4; Cb4 sounds as B3
	assert_eq(Theory.spelled_octave(Theory.parse_note("B#"), 60), 3)
	assert_eq(Theory.spelled_octave(Theory.parse_note("Cb"), 59), 4)
	assert_eq(ChordPrompt.midi_for(Theory.parse_note("Cb"), 4), 59)
	assert_eq(ChordPrompt.midi_for(Theory.parse_note("B#"), 3), 60)


func test_diatonic_c_major() -> void:
	var tri := Theory.diatonic_chords(Theory.parse_note("C"), "major", false)
	var syms := []
	var romans := []
	for e in tri:
		syms.append(e["chord"].symbol())
		romans.append(e["roman"])
	assert_eq(syms, ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
	assert_eq(romans, ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
	var sev := Theory.diatonic_chords(Theory.parse_note("C"), "major", true)
	syms = []
	for e in sev:
		syms.append(e["chord"].symbol())
	assert_eq(syms, ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])


func test_diatonic_flat_key_spelling() -> void:
	var sev := Theory.diatonic_chords(Theory.parse_note("Ab"), "major", true)
	var syms := []
	for e in sev:
		syms.append(e["chord"].symbol())
	assert_eq(syms, ["Abmaj7", "Bbm7", "Cm7", "Dbmaj7", "Eb7", "Fm7", "Gm7b5"])


func test_harmonic_minor() -> void:
	var tri := Theory.diatonic_chords(Theory.parse_note("A"), "harmonic_minor", false)
	var syms := []
	for e in tri:
		syms.append(e["chord"].symbol())
	assert_eq(syms, ["Am", "Bdim", "Caug", "Dm", "E", "F", "G#dim"])


func test_key_signatures() -> void:
	assert_eq(Theory.key_signature(Theory.parse_note("D")), 2)
	assert_eq(Theory.key_signature(Theory.parse_note("Eb")), -3)
	assert_eq(Theory.key_signature(Theory.parse_note("C"), "natural_minor"), -3)
	assert_eq(Theory.key_sig_alter(2, 3), 1)   # F# in D major
	assert_eq(Theory.key_sig_alter(2, 4), 0)   # G natural
	assert_eq(Theory.key_sig_alter(-3, 5), -1) # Ab in Eb major


func test_identify_quality() -> void:
	assert_eq(Theory.identify_quality([0, 4, 7, 11]), "maj7")
	assert_eq(Theory.identify_quality([0, 3, 6, 9]), "dim7")
	assert_eq(Theory.identify_quality([0, 1, 2]), "")
