class_name Song
extends RefCounted
## A song's chord chart, loaded from data/songs.json.

const LIBRARY_PATH := "res://data/songs.json"

var id := ""
var title := ""
var artist := ""
var year := 0
var decade := ""
var bpm := 90.0
var beats_per_bar := 4
var key := ""
## Flattened timeline: [{chord: Theory.Chord, symbol, beat, beats, section, bar}]
var events: Array = []
var total_beats := 0.0
var errors: PackedStringArray = []
var transpose := 0              # semitones applied by transposed()

## Conventional spelling for keys on each pitch class (fewest accidentals;
## F# major / Eb minor style choices at the tritone).
const MAJOR_KEY_NAMES := ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
const MINOR_KEY_NAMES := ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]


static func from_dict(d: Dictionary) -> Song:
	var s := Song.new()
	s.id = str(d.get("id", ""))
	s.title = str(d.get("title", "Untitled"))
	s.artist = str(d.get("artist", ""))
	s.year = int(d.get("year", 0))
	s.decade = str(d.get("decade", ""))
	s.bpm = float(d.get("bpm", 90))
	s.beats_per_bar = int(d.get("beats_per_bar", 4))
	s.key = str(d.get("key", ""))
	var sections: Dictionary = d.get("sections", {})
	var order: Array = d.get("order", sections.keys())
	var beat := 0.0
	var bar_no := 0
	for sec_name in order:
		if not sections.has(sec_name):
			s.errors.append("Unknown section '%s'" % sec_name)
			continue
		for bar in sections[sec_name]:
			var syms := str(bar).split(" ", false)
			if syms.is_empty():
				continue
			var each := float(s.beats_per_bar) / syms.size()
			for sym in syms:
				var c := Theory.parse_chord(sym)
				if c == null:
					s.errors.append("Can't read chord '%s' in %s" % [sym, sec_name])
				else:
					s.events.append({"chord": c, "symbol": sym, "beat": beat, "beats": each, "section": sec_name, "bar": bar_no})
				beat += each
			bar_no += 1
	s.total_beats = beat
	return s


## Key tonic and mode. Uses the "key" field ("Bm", "F#"), else the first chord.
func key_tonic() -> Theory.Note:
	var k := key.strip_edges()
	if k.ends_with("m"):
		k = k.left(-1)
	var n := Theory.parse_note(k)
	if n == null and not events.is_empty():
		n = events[0]["chord"].root
	return n if n != null else Theory.Note.new(0, 0)


func is_minor() -> bool:
	if key.strip_edges() != "":
		return key.strip_edges().ends_with("m")
	return not events.is_empty() and events[0]["chord"].def()["tags"].has("minor")


func key_scale() -> String:
	return "natural_minor" if is_minor() else "major"


## Number of sharps (+) or flats (-) in this song's key.
func key_signature() -> int:
	return Theory.key_signature(key_tonic(), key_scale())


## "B♭ major", "C♯ minor".
func key_name() -> String:
	return "%s %s" % [key_tonic().pretty(), "minor" if is_minor() else "major"]


## A copy of this song moved by `semitones` (any integer; wraps by octave).
## The new key gets its conventional name and every chord is spelled
## relative to it, e.g. Bm +1 -> Cm turns F# into G and A into Bb.
func transposed(semitones: int) -> Song:
	var n := posmod(semitones, 12)
	var s := Song.new()
	s.id = id
	s.title = title
	s.artist = artist
	s.year = year
	s.decade = decade
	s.bpm = bpm
	s.beats_per_bar = beats_per_bar
	s.total_beats = total_beats
	s.errors = errors.duplicate()
	s.transpose = semitones
	var old_tonic := key_tonic()
	var names: Array = MINOR_KEY_NAMES if is_minor() else MAJOR_KEY_NAMES
	var new_tonic := Theory.parse_note(names[posmod(old_tonic.pc() + n, 12)])
	s.key = new_tonic.name() + ("m" if is_minor() else "")
	var letter_steps := posmod(new_tonic.letter - old_tonic.letter, 7)
	var sig := Theory.key_signature(new_tonic, s.key_scale())
	for e in events:
		var c: Theory.Chord = e["chord"]
		var root := Theory.interval_above(c.root, letter_steps, n)
		if absi(root.alter) > 1:
			root = _simple_spelling(root.pc(), sig)
		var nc := Theory.Chord.new(root, c.quality)
		var ne: Dictionary = e.duplicate()
		ne["chord"] = nc
		ne["symbol"] = nc.symbol()
		s.events.append(ne)
	return s


static func _simple_spelling(pc: int, sig: int) -> Theory.Note:
	var sharps := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var flats := ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
	return Theory.parse_note((sharps if sig > 0 else flats)[pc])


func label() -> String:
	return "%s — %s (%d)" % [title, artist, year] if year > 0 else "%s — %s" % [title, artist]


func bars() -> int:
	return ceili(total_beats / beats_per_bar)


static func load_library(path := LIBRARY_PATH) -> Array[Song]:
	var out: Array[Song] = []
	if not FileAccess.file_exists(path):
		return out
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		push_error("songs.json is not valid JSON")
		return out
	for sd in d.get("songs", []):
		var s := Song.from_dict(sd)
		for e in s.errors:
			push_warning("%s: %s" % [s.title, e])
		out.append(s)
	return out
