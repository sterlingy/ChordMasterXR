class_name Theory
extends RefCounted
## Music theory: note spelling, chord qualities, scales, voicings.
##
## Notes are spelled as a letter (0..6 = C D E F G A B) plus an alteration
## (-2..+2 semitones). Pitch classes are 0..11 with C = 0. MIDI 60 = C4
## (middle C).

const LETTERS := ["C", "D", "E", "F", "G", "A", "B"]
const NATURAL_PC := [0, 2, 4, 5, 7, 9, 11]
const MIDDLE_C := 60

## Chord quality table.
## Each tone is [letter_steps_above_root, semitones_above_root]. Using letter
## steps makes spelling automatic: a third is always two letters above the
## root, so Ab minor spells Ab-Cb-Eb rather than Ab-B-Eb.
## "tags" drive the chord-pool filters.
const QUALITIES := {
	"maj":   {"symbol": "",       "spoken": "major",                 "tones": [[0, 0], [2, 4], [4, 7]],                    "tags": ["triad", "major"]},
	"min":   {"symbol": "m",      "spoken": "minor",                 "tones": [[0, 0], [2, 3], [4, 7]],                    "tags": ["triad", "minor"]},
	"dim":   {"symbol": "dim",    "spoken": "diminished",            "tones": [[0, 0], [2, 3], [4, 6]],                    "tags": ["triad", "diminished"]},
	"aug":   {"symbol": "aug",    "spoken": "augmented",             "tones": [[0, 0], [2, 4], [4, 8]],                    "tags": ["triad", "augmented"]},
	"sus2":  {"symbol": "sus2",   "spoken": "suspended two",         "tones": [[0, 0], [1, 2], [4, 7]],                    "tags": ["triad", "sus"]},
	"sus4":  {"symbol": "sus4",   "spoken": "suspended four",        "tones": [[0, 0], [3, 5], [4, 7]],                    "tags": ["triad", "sus"]},
	"6":     {"symbol": "6",      "spoken": "six",                   "tones": [[0, 0], [2, 4], [4, 7], [5, 9]],            "tags": ["sixth", "major"]},
	"m6":    {"symbol": "m6",     "spoken": "minor six",             "tones": [[0, 0], [2, 3], [4, 7], [5, 9]],            "tags": ["sixth", "minor"]},
	"maj7":  {"symbol": "maj7",   "spoken": "major seven",           "tones": [[0, 0], [2, 4], [4, 7], [6, 11]],           "tags": ["seventh", "major"]},
	"7":     {"symbol": "7",      "spoken": "seven",                 "tones": [[0, 0], [2, 4], [4, 7], [6, 10]],           "tags": ["seventh", "dominant"]},
	"m7":    {"symbol": "m7",     "spoken": "minor seven",           "tones": [[0, 0], [2, 3], [4, 7], [6, 10]],           "tags": ["seventh", "minor"]},
	"mmaj7": {"symbol": "m(maj7)", "spoken": "minor major seven",    "tones": [[0, 0], [2, 3], [4, 7], [6, 11]],           "tags": ["seventh", "minor"]},
	"m7b5":  {"symbol": "m7♭5",   "spoken": "minor seven flat five", "tones": [[0, 0], [2, 3], [4, 6], [6, 10]],           "tags": ["seventh", "diminished"]},
	"dim7":  {"symbol": "dim7",   "spoken": "diminished seven",      "tones": [[0, 0], [2, 3], [4, 6], [6, 9]],            "tags": ["seventh", "diminished"]},
	"7sus4": {"symbol": "7sus4",  "spoken": "seven suspended four",  "tones": [[0, 0], [3, 5], [4, 7], [6, 10]],           "tags": ["seventh", "sus", "dominant"]},
	"add9":  {"symbol": "add9",   "spoken": "add nine",              "tones": [[0, 0], [2, 4], [4, 7], [8, 14]],           "tags": ["extended", "major"]},
	"maj9":  {"symbol": "maj9",   "spoken": "major nine",            "tones": [[0, 0], [2, 4], [4, 7], [6, 11], [8, 14]],  "tags": ["extended", "major"]},
	"9":     {"symbol": "9",      "spoken": "nine",                  "tones": [[0, 0], [2, 4], [4, 7], [6, 10], [8, 14]],  "tags": ["extended", "dominant"]},
	"m9":    {"symbol": "m9",     "spoken": "minor nine",            "tones": [[0, 0], [2, 3], [4, 7], [6, 10], [8, 14]],  "tags": ["extended", "minor"]},
}

## Display order for menus.
const QUALITY_ORDER := ["maj", "min", "dim", "aug", "sus2", "sus4", "6", "m6", "maj7", "7", "m7",
	"mmaj7", "m7b5", "dim7", "7sus4", "add9", "maj9", "9", "m9"]

## One conventional spelling per pitch class, for "all roots" pools.
const DEFAULT_ROOTS := ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

## Major key signatures: key name -> number of sharps (+) or flats (-).
const MAJOR_KEY_SIGS := {
	"C": 0, "G": 1, "D": 2, "A": 3, "E": 4, "B": 5, "F#": 6, "C#": 7,
	"F": -1, "Bb": -2, "Eb": -3, "Ab": -4, "Db": -5, "Gb": -6, "Cb": -7,
}
const SHARP_ORDER := [3, 0, 4, 1, 5, 2, 6]  # F C G D A E B (letter indices)
const FLAT_ORDER := [6, 2, 5, 1, 4, 0, 3]   # B E A D G C F

const SCALES := {
	"major":          [[0, 0], [1, 2], [2, 4], [3, 5], [4, 7], [5, 9], [6, 11]],
	"natural_minor":  [[0, 0], [1, 2], [2, 3], [3, 5], [4, 7], [5, 8], [6, 10]],
	"harmonic_minor": [[0, 0], [1, 2], [2, 3], [3, 5], [4, 7], [5, 8], [6, 11]],
}

const ROMAN := ["I", "II", "III", "IV", "V", "VI", "VII"]

## False where no font with ♭/♯ glyphs is available (web builds without a
## bundled music font): pretty names then fall back to "b" and "#".
static var unicode_accidentals := true


# --- Notes ---------------------------------------------------------------

## A spelled pitch class.
class Note:
	var letter: int
	var alter: int

	func _init(p_letter: int = 0, p_alter: int = 0) -> void:
		letter = posmod(p_letter, 7)
		alter = p_alter

	func pc() -> int:
		return posmod(Theory.NATURAL_PC[letter] + alter, 12)

	func name() -> String:
		return Theory.LETTERS[letter] + Theory.accidental_ascii(alter)

	func pretty() -> String:
		return Theory.LETTERS[letter] + Theory.accidental_pretty(alter)

	func spoken() -> String:
		match alter:
			-2: return Theory.LETTERS[letter] + " double flat"
			-1: return Theory.LETTERS[letter] + " flat"
			1: return Theory.LETTERS[letter] + " sharp"
			2: return Theory.LETTERS[letter] + " double sharp"
		return Theory.LETTERS[letter]

	func equals(other: Note) -> bool:
		return other != null and letter == other.letter and alter == other.alter


static func accidental_ascii(alter: int) -> String:
	match alter:
		-2: return "bb"
		-1: return "b"
		1: return "#"
		2: return "x"
	return ""


static func accidental_pretty(alter: int) -> String:
	if not unicode_accidentals:
		return accidental_ascii(alter)
	match alter:
		-2: return "𝄫"
		-1: return "♭"
		1: return "♯"
		2: return "𝄪"
	return ""


## Parses "C", "F#", "Bb", "Ebb", "Gx", "C♯", "B♭". Returns null if invalid.
static func parse_note(text: String) -> Note:
	var s := text.strip_edges()
	if s.is_empty():
		return null
	var letter := LETTERS.find(s.substr(0, 1).to_upper())
	if letter < 0:
		return null
	var rest := s.substr(1)
	var alter := 0
	for ch in rest:
		match ch:
			"#", "♯": alter += 1
			"b", "♭": alter -= 1
			"x", "𝄪": alter += 2
			"𝄫": alter -= 2
			_: return null
	if abs(alter) > 2:
		return null
	return Note.new(letter, alter)


## Spells the note `letter_steps` letters and `semitones` above `root`.
static func interval_above(root: Note, letter_steps: int, semitones: int) -> Note:
	var letter := posmod(root.letter + letter_steps, 7)
	var target_pc := posmod(root.pc() + semitones, 12)
	var diff := posmod(target_pc - NATURAL_PC[letter], 12)
	if diff > 6:
		diff -= 12
	return Note.new(letter, diff)


## Note name with octave for a MIDI number, using sharps (for display of
## raw input where no spelling context exists).
static func midi_name(midi: int, prefer_flats := false) -> String:
	var pc := posmod(midi, 12)
	var sharp_names := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var flat_names := ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
	var names: Array = flat_names if prefer_flats else sharp_names
	return "%s%d" % [names[pc], midi_octave(midi)]


static func midi_octave(midi: int) -> int:
	return floori(midi / 12.0) - 1


## Octave number of a spelled note sounding at `midi` (B#3 sounds as C4).
static func spelled_octave(note: Note, midi: int) -> int:
	return floori((midi - note.alter) / 12.0) - 1


## Diatonic staff position: letter + 7 * octave (C4 = 28).
static func staff_step(note: Note, midi: int) -> int:
	return note.letter + 7 * spelled_octave(note, midi)


# --- Chords --------------------------------------------------------------

## A chord: spelled root + quality id. Inversion 0 = root position.
class Chord:
	var root: Note
	var quality: String

	func _init(p_root: Note = null, p_quality: String = "maj") -> void:
		root = p_root if p_root != null else Note.new(0, 0)
		quality = p_quality

	func def() -> Dictionary:
		return Theory.QUALITIES[quality]

	## ASCII symbol, e.g. "Bbm7b5" (stable, used in pools and parsing).
	func symbol() -> String:
		return root.name() + str(def()["symbol"]).replace("♭", "b")

	func pretty() -> String:
		var sym: String = def()["symbol"]
		if not Theory.unicode_accidentals:
			sym = sym.replace("♭", "b")
		return root.pretty() + sym

	func spoken() -> String:
		return root.spoken() + " " + def()["spoken"]

	## Stable id used for stats, e.g. "Eb:m7".
	func key() -> String:
		return root.name() + ":" + quality

	func size() -> int:
		return def()["tones"].size()

	func tones() -> Array[Note]:
		var out: Array[Note] = []
		for t in def()["tones"]:
			out.append(Theory.interval_above(root, t[0], t[1]))
		return out

	func pitch_classes() -> Array[int]:
		var out: Array[int] = []
		for n in tones():
			if not out.has(n.pc()):
				out.append(n.pc())
		return out

	func semitones() -> Array[int]:
		var out: Array[int] = []
		for t in def()["tones"]:
			out.append(t[1])
		return out

	## Max inversion index (number of chord tones - 1).
	func max_inversion() -> int:
		return size() - 1

	## Close-position voicing with the root at MIDI `root_midi`, rotated by
	## `inversion` (lowest tones moved up an octave). Notes ascending.
	func voicing(root_midi: int, inversion := 0) -> Array[int]:
		var semis := semitones()
		var notes: Array[int] = []
		for i in semis.size():
			var s: int = semis[i]
			# Extended tones (9ths) stay above the 7th in close voicing.
			notes.append(root_midi + s + (12 if i < inversion else 0))
		notes.sort()
		return notes

	## Spelled tones paired to a voicing (same order as voicing()).
	func voiced_tones(root_midi: int, inversion := 0) -> Array:
		var semis := semitones()
		var ts := tones()
		var pairs := []
		for i in semis.size():
			pairs.append([root_midi + semis[i] + (12 if i < inversion else 0), ts[i]])
		pairs.sort_custom(func(a, b): return a[0] < b[0])
		return pairs

	func bass_pc(inversion: int) -> int:
		return tones()[clampi(inversion, 0, size() - 1)].pc()

	func equals(other: Chord) -> bool:
		return other != null and quality == other.quality and root.equals(other.root)


static func make_chord(root_name: String, quality: String) -> Chord:
	var n := parse_note(root_name)
	if n == null or not QUALITIES.has(quality):
		return null
	return Chord.new(n, quality)


## Parses "Cmaj7", "F#m7b5", "Bb", "Ebm(maj7)". Returns null if unknown.
static func parse_chord(text: String) -> Chord:
	var s := text.strip_edges().replace("♭", "b").replace("♯", "#")
	if s.is_empty():
		return null
	var root_len := 1
	while root_len < s.length() and s[root_len] in ["#", "b", "x"]:
		# "b" right after the letter is a flat, except in "...b5" suffixes
		root_len += 1
	# Try longest root first, falling back if the suffix doesn't match.
	for rl in range(root_len, 0, -1):
		var root := parse_note(s.substr(0, rl))
		if root == null:
			continue
		var suffix := s.substr(rl)
		for q in QUALITIES:
			if QUALITIES[q]["symbol"].replace("♭", "b") == suffix:
				return Chord.new(root, q)
	return null


static func inversion_name(inversion: int) -> String:
	match inversion:
		0: return "root position"
		1: return "1st inversion"
		2: return "2nd inversion"
		3: return "3rd inversion"
		4: return "4th inversion"
	return "%dth inversion" % inversion


## Returns the quality id whose tone set matches the given semitone set
## (relative to root, mod 12), or "" if none.
static func identify_quality(semis: Array) -> String:
	var want := []
	for s in semis:
		var v := posmod(int(s), 12)
		if not want.has(v):
			want.append(v)
	want.sort()
	for q in QUALITY_ORDER:
		var have := []
		for t in QUALITIES[q]["tones"]:
			var v := posmod(int(t[1]), 12)
			if not have.has(v):
				have.append(v)
		have.sort()
		if have == want:
			return q
	return ""


# --- Scales & keys -------------------------------------------------------

static func scale_notes(tonic: Note, scale: String = "major") -> Array[Note]:
	var out: Array[Note] = []
	for d in SCALES[scale]:
		out.append(interval_above(tonic, d[0], d[1]))
	return out


## Diatonic chords of a key. `sevenths` true -> 7th chords, else triads.
## Returns an array of dictionaries: {chord, degree (0..6), roman}.
static func diatonic_chords(tonic: Note, scale: String = "major", sevenths := false) -> Array:
	var notes := scale_notes(tonic, scale)
	var out := []
	for deg in 7:
		var stack := [0, 2, 4, 6] if sevenths else [0, 2, 4]
		var root := notes[deg]
		var semis := []
		for k in stack:
			var n: Note = notes[(deg + k) % 7]
			semis.append(posmod(n.pc() - root.pc(), 12))
		var q := identify_quality(semis)
		if q == "":
			continue
		var chord := Chord.new(root, q)
		out.append({"chord": chord, "degree": deg, "roman": roman_numeral(deg, q)})
	return out


static func roman_numeral(degree: int, quality: String) -> String:
	var base: String = ROMAN[degree]
	var tags: Array = QUALITIES[quality]["tags"]
	var lower := tags.has("minor") or tags.has("diminished")
	var r := base.to_lower() if lower else base
	match quality:
		"dim": r += "°"
		"aug": r += "+"
		"maj7": r += "maj7"
		"7": r += "7"
		"m7": r += "7"
		"m7b5": r += "ø7"
		"dim7": r += "°7"
		"mmaj7": r += "(maj7)"
	return r


## Key signature (count of sharps >0 / flats <0) for a major key tonic.
## Unknown/theoretical keys return 0.
static func key_signature(tonic: Note, scale: String = "major") -> int:
	var major_tonic := tonic
	if scale != "major":
		major_tonic = interval_above(tonic, 2, 3)  # relative major
	return MAJOR_KEY_SIGS.get(major_tonic.name(), 0)


## Alteration that the key signature applies to a letter.
static func key_sig_alter(sig: int, letter: int) -> int:
	if sig > 0:
		return 1 if SHARP_ORDER.slice(0, sig).has(letter) else 0
	if sig < 0:
		return -1 if FLAT_ORDER.slice(0, -sig).has(letter) else 0
	return 0


## Root for a "next in circle of fourths" step, keeping friendly spellings.
static func circle_of_fourths() -> Array[String]:
	return ["C", "F", "Bb", "Eb", "Ab", "Db", "Gb", "B", "E", "A", "D", "G"]


static func circle_of_fifths() -> Array[String]:
	return ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"]
