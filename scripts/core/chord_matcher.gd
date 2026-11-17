class_name ChordMatcher
extends RefCounted
## Judges whether a set of held MIDI notes plays a prompted chord.
##
## Rules (agreed spec):
## - Rolled chords count: notes don't have to land at the same instant.
##   The chord is judged once every chord tone is held.
## - Any note that isn't a chord tone is an immediate fail.
## - Doubled chord tones (same pitch class, other octave) are fine.
## - Inversions are accepted unless `strict_inversion` is set, in which
##   case the lowest held note must be the prompted inversion's bass.
## - Octave mode: the root must be played in `target_octave` (C4 = middle C).
## - Sustain pedal is ignored by the input layer, not here.

enum Result { PENDING, CORRECT, WRONG_NOTE, WRONG_INVERSION, WRONG_OCTAVE, INCOMPLETE }

var chord: Theory.Chord
var inversion := 0
var strict_inversion := false
var octave_mode := false
var target_octave := 4


func _init(p_chord: Theory.Chord = null) -> void:
	chord = p_chord


## Live evaluation while notes are being held (MIDI mode).
## Returns PENDING while the chord is still being built correctly.
func evaluate_live(held: Array) -> Result:
	if held.is_empty():
		return Result.PENDING
	var pcs := chord.pitch_classes()
	var held_pcs := {}
	for m in held:
		var pc := posmod(int(m), 12)
		if not pcs.has(pc):
			return Result.WRONG_NOTE
		held_pcs[pc] = true
	if held_pcs.size() < pcs.size():
		return Result.PENDING
	return _judge_complete(held)


## One-shot evaluation for "select and submit" mode: anything short of the
## full chord is INCOMPLETE rather than PENDING.
func evaluate_submit(selected: Array) -> Result:
	var r := evaluate_live(selected)
	if r == Result.PENDING:
		return Result.INCOMPLETE
	return r


func _judge_complete(held: Array) -> Result:
	var lowest := int(held.min())
	if strict_inversion and posmod(lowest, 12) != chord.bass_pc(inversion):
		return Result.WRONG_INVERSION
	if octave_mode:
		var root_pc := chord.root.pc()
		var ok := false
		for m in held:
			var mi := int(m)
			if posmod(mi, 12) == root_pc and Theory.spelled_octave(chord.root, mi) == target_octave:
				ok = true
				break
		if not ok:
			return Result.WRONG_OCTAVE
	return Result.CORRECT


## Notes held that aren't in the chord (for red highlighting).
func wrong_notes(held: Array) -> Array[int]:
	var pcs := chord.pitch_classes()
	var out: Array[int] = []
	for m in held:
		if not pcs.has(posmod(int(m), 12)):
			out.append(int(m))
	return out


static func result_text(r: Result) -> String:
	match r:
		Result.CORRECT: return "Correct!"
		Result.WRONG_NOTE: return "Wrong note"
		Result.WRONG_INVERSION: return "Wrong inversion"
		Result.WRONG_OCTAVE: return "Root is in the wrong octave"
		Result.INCOMPLETE: return "Not all chord tones selected"
	return ""


static func is_fail(r: Result) -> bool:
	return r in [Result.WRONG_NOTE, Result.WRONG_INVERSION, Result.WRONG_OCTAVE, Result.INCOMPLETE]
