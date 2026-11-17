class_name ChordPrompt
extends RefCounted
## One thing the user is asked to play or name.

var chord: Theory.Chord
var inversion := 0                # which inversion is shown/expected
var strict_inversion := false     # only this inversion counts
var octave_mode := false
var target_octave := 4            # octave the root must be in (octave mode)
var root_midi := 60               # where the reference voicing's root sits
var context := ""                 # e.g. "ii in C major", "ii–V–I in F"
var key_tonic := ""               # key used for key-signature display
var key_scale := "major"


func voicing() -> Array[int]:
	return chord.voicing(root_midi, inversion)


func voiced_tones() -> Array:
	return chord.voiced_tones(root_midi, inversion)


func matcher() -> ChordMatcher:
	var m := ChordMatcher.new(chord)
	m.inversion = inversion
	m.strict_inversion = strict_inversion
	m.octave_mode = octave_mode
	m.target_octave = target_octave
	return m


func title() -> String:
	return chord.pretty()


func subtitle(with_inversion := true) -> String:
	var parts := []
	if strict_inversion and with_inversion:
		parts.append(Theory.inversion_name(inversion))
	if octave_mode:
		parts.append("root in octave %d" % target_octave)
	if context != "":
		parts.append(context)
	return "  ·  ".join(parts)


func spoken() -> String:
	var s := chord.spoken()
	if strict_inversion and inversion > 0:
		s += ", " + Theory.inversion_name(inversion)
	return s


## MIDI number of `note` in `octave` (B#4 -> 72, Cb4 -> 59).
static func midi_for(note: Theory.Note, octave: int) -> int:
	return 12 * (octave + 1) + Theory.NATURAL_PC[note.letter] + note.alter


## Picks a root position so the voicing fits [low, high]. Prefers the
## placement whose centre is closest to `centre`. Returns -1 if none fits.
static func place_root(chord: Theory.Chord, inversion: int, low: int, high: int, centre := 62) -> int:
	var best := -1
	var best_d := INF
	for octave in range(0, 9):
		var rm := midi_for(chord.root, octave)
		var v := chord.voicing(rm, inversion)
		if v[0] < low or v[-1] > high:
			continue
		var mid := (v[0] + v[-1]) / 2.0
		var d := absf(mid - centre)
		if d < best_d:
			best_d = d
			best = rm
	return best


## True if the chord can be played with its root in `octave` within range.
static func fits_in_octave(chord: Theory.Chord, inversion: int, octave: int, low: int, high: int) -> bool:
	var v := chord.voicing(midi_for(chord.root, octave), inversion)
	return v[0] >= low and v[-1] <= high
