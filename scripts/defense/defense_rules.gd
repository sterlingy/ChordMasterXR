class_name DefenseRules
extends RefCounted
## Pure rules for Chord Defense (no nodes), so they can be unit-tested.
##
## The one rule: play the attacker's chord with its lowest note in the
## octave of the station it is attacking. Station octave n covers MIDI
## 12·(n+1) … 12·(n+1)+11 (C4 = 60, so octave 4 is middle C up to B4).

const MAX_STATIONS := 8
const SHIELDS := 3

## Combo: +1 multiplier every COMBO_STEP kills in a row, capped.
const COMBO_STEP := 4
const COMBO_MAX := 8


static func octave_low(octave: int) -> int:
	return 12 * (octave + 1)


static func octave_of(midi: int) -> int:
	return floori(midi / 12.0) - 1


## Octaves fully inside [low, high], lowest first, at most MAX_STATIONS
## (the middle ones if the keyboard is huge).
static func station_octaves(low: int, high: int) -> Array[int]:
	var out: Array[int] = []
	for o in range(-1, 10):
		if octave_low(o) >= low and octave_low(o) + 11 <= high:
			out.append(o)
	while out.size() > MAX_STATIONS:
		# Drop from the end that is further from middle C.
		if absi(out[0] - 4) > absi(out[-1] - 4):
			out.pop_front()
		else:
			out.pop_back()
	return out


## A close voicing of `chord` whose lowest note is in `octave` and whose top
## fits under `high`, or [] if the chord can't be played there.
## Prefers root position, then the lowest-sounding inversion.
static func voicing_in_octave(chord: Theory.Chord, octave: int, high: int) -> Array[int]:
	var lo := octave_low(octave)
	var best: Array[int] = []
	for inv in chord.max_inversion() + 1:
		for root_oct in range(octave - 1, octave + 2):
			var v := chord.voicing(ChordPrompt.midi_for(chord.root, root_oct), inv)
			if v[0] < lo or v[0] > lo + 11 or v[-1] > high:
				continue
			if best.is_empty():
				best = v
			if inv == 0:
				return v
	return best


static func pc_set(notes: Array) -> Dictionary:
	var s := {}
	for m in notes:
		s[posmod(int(m), 12)] = true
	return s


## True if the held notes are exactly the chord's pitch classes (doubling ok).
static func plays_chord(held: Array, chord: Theory.Chord) -> bool:
	if held.is_empty():
		return false
	var hs := pc_set(held)
	var pcs := chord.pitch_classes()
	if hs.size() != pcs.size():
		return false
	for pc in pcs:
		if not hs.has(pc):
			return false
	return true


## True if every held note is a tone of the chord (still building it).
static func partial_of(held: Array, chord: Theory.Chord) -> bool:
	var pcs := chord.pitch_classes()
	for m in held:
		if not pcs.has(posmod(int(m), 12)):
			return false
	return true


## Judges the held notes against the attackers.
## `targets`: [{id, chord: Theory.Chord, octave: int, progress: float}].
## Returns {kind: "kill"|"wrong_octave"|"misfire"|"pending", id, octave}.
##   kill          – matches an attacker on the station of the lowest note
##                   (the one closest to its station wins)
##   wrong_octave  – the chord matches, but the bass is in another octave
##   misfire       – 3+ different notes that aren't any attacker's chord
##   pending       – still building a chord (or too few notes to judge)
static func judge(held: Array, targets: Array) -> Dictionary:
	if held.is_empty():
		return {"kind": "pending"}
	var octave := octave_of(int(held.min()))
	var best_id = null
	var best_p := -1.0
	var wrong_id = null
	var building := false
	for t in targets:
		var c: Theory.Chord = t["chord"]
		if plays_chord(held, c):
			if int(t["octave"]) == octave:
				if float(t["progress"]) > best_p:
					best_p = float(t["progress"])
					best_id = t["id"]
			elif wrong_id == null:
				wrong_id = t["id"]
		elif partial_of(held, c):
			building = true
	if best_id != null:
		return {"kind": "kill", "id": best_id, "octave": octave}
	if wrong_id != null:
		return {"kind": "wrong_octave", "id": wrong_id, "octave": octave}
	if not building and pc_set(held).size() >= 3:
		return {"kind": "misfire", "octave": octave}
	return {"kind": "pending", "octave": octave}


static func combo_multiplier(streak: int) -> int:
	return mini(1 + streak / COMBO_STEP, COMBO_MAX)


## Points for a kill: base by chord size, bonus for killing it far from the
## station (progress 0 = just appeared, 1 = hitting), times the combo.
static func kill_points(chord: Theory.Chord, progress: float, streak: int) -> int:
	var base := 100 + 50 * maxi(0, chord.size() - 3)
	var distance_bonus := roundi(base * (1.0 - clampf(progress, 0.0, 1.0)))
	return (base + distance_bonus) * combo_multiplier(streak)


static func wave_bonus(wave: int, full_stations: int) -> int:
	return 500 * wave + 250 * full_stations
