class_name DefenseWaves
extends RefCounted
## Level design for Chord Defense: sectors (chord families + colours) and
## the make-up of each wave. Pure data/logic, unit-tested.

const SECTORS := [
	{"name": "Triad Nebula", "from": 1,
		"qualities": ["maj", "min"],
		"types": {"drifter": 5, "missile": 2},
		"sky": Color(0.05, 0.03, 0.12), "accent": Color(0.45, 0.6, 1.0)},
	{"name": "Shadow Belt", "from": 5,
		"qualities": ["maj", "min", "dim", "aug"],
		"types": {"drifter": 4, "missile": 2, "jumper": 3},
		"sky": Color(0.09, 0.02, 0.06), "accent": Color(1.0, 0.45, 0.55)},
	{"name": "Seventh Heaven", "from": 9,
		"qualities": ["maj", "min", "7", "maj7", "m7"],
		"types": {"drifter": 3, "missile": 2, "jumper": 3, "diver": 3},
		"sky": Color(0.02, 0.07, 0.09), "accent": Color(0.35, 1.0, 0.85)},
	{"name": "Tritone Void", "from": 13,
		"qualities": ["7", "maj7", "m7", "m7b5", "dim7", "sus2", "sus4"],
		"types": {"drifter": 3, "missile": 2, "jumper": 3, "diver": 4},
		"sky": Color(0.05, 0.035, 0.02), "accent": Color(1.0, 0.7, 0.3)},
	{"name": "Ninth Gate", "from": 17,
		"qualities": ["maj", "min", "7", "maj7", "m7", "m7b5", "dim7", "6", "m6", "add9", "9", "m9", "maj9"],
		"types": {"drifter": 2, "missile": 2, "jumper": 4, "diver": 4},
		"sky": Color(0.01, 0.01, 0.02), "accent": Color(0.85, 0.55, 1.0)},
]

## Progressions carried by the boss every 5th wave (Roman numerals over a
## random major key). Each entry: [degree (0-based), quality].
const PROGRESSIONS := [
	{"name": "ii–V–I", "steps": [[1, "m7"], [4, "7"], [0, "maj7"]]},
	{"name": "I–vi–IV–V", "steps": [[0, "maj"], [5, "min"], [3, "maj"], [4, "maj"]]},
	{"name": "I–IV–V", "steps": [[0, "maj"], [3, "maj"], [4, "7"]]},
	{"name": "vi–IV–I–V", "steps": [[5, "min"], [3, "maj"], [0, "maj"], [4, "maj"]]},
]

const BOSS_EVERY := 5

## Each wave after the first has a special event that shows up in some of
## its spawns, cycling so consecutive waves feel different:
##   echo       one chord attacks 2–3 stations at once (play it in each octave)
##   formation  three ships in neighbouring lanes, side by side
##   salvo      a quick burst of missiles
const SPECIALS := ["echo", "formation", "salvo"]
const SPECIAL_TEXT := {
	"echo": "Octave echo: the same chord attacks several stations — play it in each octave",
	"formation": "Formation: ships arrive side by side",
	"salvo": "Missile salvo incoming",
	"": "",
}


static func sector_for(wave: int) -> Dictionary:
	var s: Dictionary = SECTORS[0]
	for sec in SECTORS:
		if wave >= int(sec["from"]):
			s = sec
	return s


static func sector_index(wave: int) -> int:
	var i := 0
	for k in SECTORS.size():
		if wave >= int(SECTORS[k]["from"]):
			i = k
	return i


## The plan for wave `wave` (1-based):
##   count       attackers in the wave (not counting the boss)
##   interval    seconds between spawns
##   travel      seconds an attacker takes to reach its station
##   types       {type: weight}
##   qualities   chord qualities to draw from
##   boss        true on every BOSS_EVERY-th wave
static func plan(wave: int) -> Dictionary:
	var sec := sector_for(wave)
	var in_sector := wave - int(sec["from"])            # 0.. within the sector
	var lap := sector_index(wave)
	return {
		"wave": wave,
		"sector": sec["name"],
		"count": 6 + wave * 2,
		"interval": maxf(1.1, 3.4 - 0.12 * wave),
		# Each sector starts a little easier than the last one ended.
		"travel": maxf(7.0, 17.0 - 1.6 * in_sector - 0.9 * lap),
		"types": sec["types"],
		"qualities": sec["qualities"],
		"boss": wave % BOSS_EVERY == 0,
		"max_alive": mini(2 + wave / 2, 7),
		"special": "" if wave == 1 else SPECIALS[(wave - 2) % SPECIALS.size()],
		"special_chance": 0.3,
	}


## Chord qualities that first appear in the sector starting at `wave`
## ([] if `wave` isn't the first wave of a sector, or nothing is new).
static func new_qualities(wave: int) -> Array:
	var i := sector_index(wave)
	if i == 0 or wave != int(SECTORS[i]["from"]):
		return []
	var before := {}
	for k in i:
		for q in SECTORS[k]["qualities"]:
			before[q] = true
	return (SECTORS[i]["qualities"] as Array).filter(func(q): return not before.has(q))


static func pick_weighted(weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	var r := rng.randf() * total
	for k in weights:
		r -= float(weights[k])
		if r <= 0.0:
			return k
	return weights.keys()[0]


## The chords of a progression in a major key on `tonic`.
static func progression_chords(prog: Dictionary, tonic: Theory.Note) -> Array:
	var scale := Theory.scale_notes(tonic, "major")
	var out := []
	for step in prog["steps"]:
		var root: Theory.Note = scale[int(step[0])]
		out.append(Theory.Chord.new(root, str(step[1])))
	return out
