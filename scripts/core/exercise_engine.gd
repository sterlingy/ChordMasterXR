class_name ExerciseEngine
extends RefCounted
## Produces the sequence of prompts for an exercise.
##
## Exercise types:
##   random         – uniform random from the pool
##   smart          – adaptive: weak/slow/unseen chords come up more often
##   two_five_one   – ii–V–I (m7, 7, maj7) through all 12 major keys
##   circle         – pool qualities walked around the circle of fourths
##   inversions     – each pool chord through all its inversions (strict)
##   diatonic       – the pool's key in scale order (I, ii, iii, ...)
##   voice_leading  – ii–V–I in all keys, inversions chosen for the
##                    smallest hand movement between chords (strict)

const TYPES := ["smart", "random", "two_five_one", "circle", "inversions", "diatonic", "voice_leading"]
const TYPE_LABELS := {
	"smart": "Smart practice (adaptive)",
	"random": "Random from pool",
	"two_five_one": "ii–V–I in all keys",
	"circle": "Circle of fourths",
	"inversions": "Inversion ladder",
	"diatonic": "Diatonic in key",
	"voice_leading": "Voice leading (ii–V–I)",
}
const TYPE_HINTS := {
	"smart": "Draws from your pool, favouring chords you miss or play slowly.",
	"random": "Every chord in the pool is equally likely.",
	"two_five_one": "Minor 7 → dominant 7 → major 7, moving through the circle of fourths. Ignores the pool.",
	"circle": "Each quality in your pool, root moving C → F → B♭ → …",
	"inversions": "Every pool chord in root position, then each inversion. Inversion must match.",
	"diatonic": "Chords of the pool's key in scale order. Uses C major if the pool isn't a key pool.",
	"voice_leading": "ii–V–I in all keys with the inversion that moves your hand least. Inversion must match.",
}

var type := "smart"
var pool: ChordPool = ChordPool.new()
var stats: PracticeStats = PracticeStats.new()
var rng := RandomNumberGenerator.new()

# Settings (copied from AppSettings by the caller)
var range_low := 48          # C3
var range_high := 84         # C6
var strict_inversion := false
var random_inversions := false   # in strict mode, ask for random inversions
var octave_mode := false
var target_octave := 4           # -1 = random octave within range
## Octaves chords may not start in (their lowest note); [] = all allowed.
var disabled_octaves: Array = []

var _queue: Array = []           # pending ChordPrompt objects for sequenced types
var _last_key := ""
var _last_voicing: Array[int] = []


func configure(p_type: String, p_pool: ChordPool, p_stats: PracticeStats) -> void:
	type = p_type
	pool = p_pool
	stats = p_stats
	reset()


func reset() -> void:
	_queue.clear()
	_last_key = ""
	_last_voicing.clear()


## Pool entries that can actually be played on the user's keyboard.
func playable_entries() -> Array:
	var out := []
	for e in pool.entries():
		if _fits_anywhere(e["chord"]):
			out.append(e)
	return out


func next_prompt() -> ChordPrompt:
	var p: ChordPrompt = null
	match type:
		"random", "smart":
			p = _next_from_pool(type == "smart")
		_:
			if _queue.is_empty():
				_build_sequence()
			if not _queue.is_empty():
				p = _queue.pop_front()
	if p != null:
		_last_key = p.chord.key()
		_last_voicing = p.voicing()
	return p


# --- pool-based --------------------------------------------------------

func _next_from_pool(adaptive: bool) -> ChordPrompt:
	var entries := playable_entries()
	if entries.is_empty():
		return null
	var candidates := entries
	if entries.size() > 1:
		candidates = entries.filter(func(e): return e["chord"].key() != _last_key)
	var pick: Dictionary
	if adaptive:
		var total := 0.0
		var weights := []
		for e in candidates:
			var w := stats.weight(e["chord"].key())
			weights.append(w)
			total += w
		var r := rng.randf() * total
		pick = candidates[-1]
		for i in candidates.size():
			r -= weights[i]
			if r <= 0.0:
				pick = candidates[i]
				break
	else:
		pick = candidates[rng.randi() % candidates.size()]
	var inv := 0
	if strict_inversion and random_inversions:
		inv = rng.randi() % pick["chord"].size()
	return _make_prompt(pick["chord"], inv, pick.get("context", ""), pick.get("key_tonic", ""), pick.get("key_scale", "major"))


# --- sequenced types ---------------------------------------------------

func _build_sequence() -> void:
	match type:
		"two_five_one":
			for key_name in Theory.circle_of_fourths():
				_push_251(key_name, false)
		"voice_leading":
			_last_voicing.clear()
			for key_name in Theory.circle_of_fourths():
				_push_251(key_name, true)
		"circle":
			var quals: Array = pool.qualities if pool.source == "filter" else ["maj"]
			for q in quals:
				for r in Theory.circle_of_fourths():
					var c := Theory.make_chord(r, q)
					if c != null and _fits_anywhere(c):
						_queue.append(_make_prompt(c, 0, "circle of fourths", "", "major"))
		"inversions":
			var entries := playable_entries()
			entries.shuffle()
			for e in entries:
				var c: Theory.Chord = e["chord"]
				for inv in c.size():
					var p := _make_prompt(c, inv, e.get("context", ""), e.get("key_tonic", ""), e.get("key_scale", "major"), true)
					if p != null:
						_queue.append(p)
		"diatonic":
			var tonic_name := pool.key_tonic if pool.source == "key" else "C"
			var scale := pool.key_scale if pool.source == "key" else "major"
			var tonic := Theory.parse_note(tonic_name)
			var sev := pool.source == "key" and pool.key_sevenths and not pool.key_triads
			for e in Theory.diatonic_chords(tonic, scale, sev):
				var ctx := "%s in %s %s" % [e["roman"], tonic.pretty(), ChordPool.scale_label(scale)]
				var p := _make_prompt(e["chord"], 0, ctx, tonic_name, scale)
				if p != null:
					_queue.append(p)
	_queue = _queue.filter(func(p): return p != null)


func _push_251(key_name: String, voice_lead: bool) -> void:
	var tonic := Theory.parse_note(key_name)
	var degs := Theory.diatonic_chords(tonic, "major", true)
	var label := "ii–V–I in %s" % tonic.pretty()
	for d in [1, 4, 0]:
		var e: Dictionary = degs[d]
		var c: Theory.Chord = e["chord"]
		var ctx := "%s  ·  %s" % [e["roman"], label]
		if voice_lead:
			var best := _closest_inversion(c, _last_voicing)
			if best.is_empty():
				continue
			var p := _make_prompt(c, best["inversion"], ctx, key_name, "major", true, best["root_midi"])
			_queue.append(p)
			_last_voicing = p.voicing()
		else:
			var p := _make_prompt(c, 0, ctx, key_name, "major")
			if p != null:
				_queue.append(p)


## The (inversion, root placement) whose voicing is nearest `prev` (sum of
## distances between sorted notes). With no previous voicing, picks root
## position near the middle of the keyboard.
func _closest_inversion(c: Theory.Chord, prev: Array[int]) -> Dictionary:
	if prev.is_empty():
		var rm := ChordPrompt.place_root(c, 0, range_low, range_high, 62, disabled_octaves)
		return {} if rm < 0 else {"inversion": 0, "root_midi": rm}
	var best := {}
	var best_cost := INF
	for inv in c.size():
		for octave in range(0, 9):
			var rm := ChordPrompt.midi_for(c.root, octave)
			var v := c.voicing(rm, inv)
			if v[0] < range_low or v[-1] > range_high or disabled_octaves.has(ChordPrompt.bass_octave(v)):
				continue
			var cost := 0.0
			for i in mini(v.size(), prev.size()):
				cost += absf(v[i] - prev[i])
			cost += absf(v.size() - prev.size()) * 2.0
			if cost < best_cost:
				best_cost = cost
				best = {"inversion": inv, "root_midi": rm}
	return best


# --- prompt construction ----------------------------------------------

func _fits_anywhere(c: Theory.Chord) -> bool:
	if octave_mode and target_octave >= 0:
		return ChordPrompt.fits_in_octave(c, 0, target_octave, range_low, range_high, disabled_octaves)
	return ChordPrompt.place_root(c, 0, range_low, range_high, 62, disabled_octaves) >= 0


func _make_prompt(c: Theory.Chord, inv: int, ctx: String, key_tonic: String, key_scale: String,
		force_strict := false, forced_root_midi := -1) -> ChordPrompt:
	var p := ChordPrompt.new()
	p.chord = c
	p.inversion = inv
	p.strict_inversion = strict_inversion or force_strict
	p.context = ctx
	p.key_tonic = key_tonic
	p.key_scale = key_scale
	p.octave_mode = octave_mode
	if forced_root_midi >= 0:
		p.root_midi = forced_root_midi
	elif octave_mode:
		var oct := target_octave
		if oct < 0:
			var options := []
			for o in range(0, 9):
				if ChordPrompt.fits_in_octave(c, inv, o, range_low, range_high, disabled_octaves):
					options.append(o)
			if options.is_empty():
				return null
			oct = options[rng.randi() % options.size()]
		if not ChordPrompt.fits_in_octave(c, inv, oct, range_low, range_high, disabled_octaves):
			return null
		p.root_midi = ChordPrompt.midi_for(c.root, oct)
	else:
		var rm := ChordPrompt.place_root(c, inv, range_low, range_high, 62, disabled_octaves)
		if rm < 0:
			return null
		p.root_midi = rm
	p.target_octave = Theory.spelled_octave(c.root, p.root_midi)
	return p


# --- multiple choice ("Name It") ---------------------------------------

## Returns `count` chords including the answer, shuffled. Distractors are
## plausible: same root with related qualities, chords sharing most notes,
## and same quality on a nearby root. Chords that sound identical to the
## answer (same pitch-class set, e.g. C6 vs Am7) are never offered.
func choices_for(answer: Theory.Chord, count: int) -> Array:
	var answer_pcs := answer.pitch_classes()
	answer_pcs.sort()
	var scored := []
	var seen := {answer.key(): true}
	var roots := Theory.DEFAULT_ROOTS.duplicate()
	if not roots.has(answer.root.name()):
		roots.append(answer.root.name())
	for r in roots:
		for q in Theory.QUALITY_ORDER:
			var c := Theory.make_chord(r, q)
			if c == null or seen.has(c.key()):
				continue
			var pcs := c.pitch_classes()
			pcs.sort()
			if pcs == answer_pcs:
				continue
			var score := 0.0
			var shared := 0
			for pc in pcs:
				if answer_pcs.has(pc):
					shared += 1
			score += shared * 1.5
			if c.root.equals(answer.root):
				score += 3.0
			if q == answer.quality:
				score += 1.0
			var a_tags: Array = answer.def()["tags"]
			for t in c.def()["tags"]:
				if a_tags.has(t):
					score += 0.75
			score -= absf(c.size() - answer.size()) * 0.5
			score += rng.randf() * 1.5   # variety
			scored.append([score, c])
			seen[c.key()] = true
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out := [answer]
	for i in mini(count - 1, scored.size()):
		out.append(scored[i][1])
	out.shuffle()
	return out
