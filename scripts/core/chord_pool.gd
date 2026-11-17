class_name ChordPool
extends RefCounted
## The set of chords an exercise may draw from.
##
## A pool is either:
## - "filter": every chosen root x every chosen quality, or
## - "key": the diatonic triads and/or sevenths of a key, or
## - "custom": an explicit list of chord symbols.
## Pools can be saved/loaded as plain dictionaries (see to_dict/from_dict).

var source := "filter"                  # "filter" | "key" | "custom"
var roots: Array = Theory.DEFAULT_ROOTS.duplicate()
var qualities: Array = ["maj", "min"]
var key_tonic := "C"
var key_scale := "major"
var key_triads := true
var key_sevenths := false
var custom: Array = []                  # chord symbols, e.g. ["Cmaj7", "Dm7"]

## Built-in presets shown as one-tap buttons.
const PRESETS := {
	"Major triads":       {"source": "filter", "qualities": ["maj"]},
	"Minor triads":       {"source": "filter", "qualities": ["min"]},
	"Major & minor":      {"source": "filter", "qualities": ["maj", "min"]},
	"All triads":         {"source": "filter", "qualities": ["maj", "min", "dim", "aug"]},
	"Sus chords":         {"source": "filter", "qualities": ["sus2", "sus4", "7sus4"]},
	"Maj7":               {"source": "filter", "qualities": ["maj7"]},
	"Dominant 7":         {"source": "filter", "qualities": ["7"]},
	"Minor 7":            {"source": "filter", "qualities": ["m7"]},
	"All sevenths":       {"source": "filter", "qualities": ["maj7", "7", "m7", "m7b5", "dim7", "mmaj7"]},
	"Jazz 7ths (maj7/7/m7/ø)": {"source": "filter", "qualities": ["maj7", "7", "m7", "m7b5"]},
	"Sixths":             {"source": "filter", "qualities": ["6", "m6"]},
	"Ninths":             {"source": "filter", "qualities": ["add9", "maj9", "9", "m9"]},
	"C major: triads":    {"source": "key", "key_tonic": "C", "key_scale": "major", "key_triads": true, "key_sevenths": false},
	"C major: sevenths":  {"source": "key", "key_tonic": "C", "key_scale": "major", "key_triads": false, "key_sevenths": true},
	"A minor: triads":    {"source": "key", "key_tonic": "A", "key_scale": "natural_minor", "key_triads": true, "key_sevenths": false},
}


static func from_preset(preset_name: String) -> ChordPool:
	var p := ChordPool.new()
	if PRESETS.has(preset_name):
		p.apply(PRESETS[preset_name])
	return p


func apply(d: Dictionary) -> void:
	for k in d:
		if k in self:
			var v = d[k]
			if v is Array:
				v = v.duplicate()
			set(k, v)


func to_dict() -> Dictionary:
	return {
		"source": source, "roots": roots.duplicate(), "qualities": qualities.duplicate(),
		"key_tonic": key_tonic, "key_scale": key_scale, "key_triads": key_triads,
		"key_sevenths": key_sevenths, "custom": custom.duplicate(),
	}


static func from_dict(d: Dictionary) -> ChordPool:
	var p := ChordPool.new()
	p.apply(d)
	return p


## Returns entries: {chord: Theory.Chord, context: String, key_tonic: String,
## key_scale: String}. Context is e.g. "ii in C major" for key pools.
func entries() -> Array:
	var out := []
	match source:
		"filter":
			for r in roots:
				for q in qualities:
					var c := Theory.make_chord(r, q)
					if c != null:
						out.append({"chord": c, "context": "", "key_tonic": "", "key_scale": ""})
		"key":
			var tonic := Theory.parse_note(key_tonic)
			if tonic == null:
				return out
			var kinds := []
			if key_triads:
				kinds.append(false)
			if key_sevenths:
				kinds.append(true)
			for sev in kinds:
				for e in Theory.diatonic_chords(tonic, key_scale, sev):
					out.append({
						"chord": e["chord"],
						"context": "%s in %s %s" % [e["roman"], tonic.pretty(), scale_label(key_scale)],
						"key_tonic": key_tonic, "key_scale": key_scale,
					})
		"custom":
			for sym in custom:
				var c := Theory.parse_chord(str(sym))
				if c != null:
					out.append({"chord": c, "context": "", "key_tonic": "", "key_scale": ""})
	return out


func size() -> int:
	return entries().size()


static func scale_label(scale: String) -> String:
	match scale:
		"major": return "major"
		"natural_minor": return "minor"
		"harmonic_minor": return "harmonic minor"
	return scale


func describe() -> String:
	match source:
		"filter":
			var qs := []
			for q in qualities:
				qs.append(Theory.QUALITIES[q]["symbol"] if Theory.QUALITIES[q]["symbol"] != "" else "maj")
			return "%s on %d roots" % [", ".join(qs), roots.size()]
		"key":
			var parts := []
			if key_triads: parts.append("triads")
			if key_sevenths: parts.append("sevenths")
			return "%s %s: %s" % [key_tonic, scale_label(key_scale), " + ".join(parts)]
		"custom":
			return "Custom (%d chords)" % custom.size()
	return ""
