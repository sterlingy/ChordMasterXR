class_name SongEngine
extends RefCounted
## Timing judge for playing along with a song. Pure logic (no nodes), driven
## with explicit times in seconds so it can be unit-tested.
##
## Song time 0 is the downbeat of the first chord (after the count-in).
## Each chord change is a target. A chord "lands" when the held notes form
## that chord (any inversion, no wrong notes) right after a key was struck.
## Its timing offset is landing time minus the beat it belongs on.
##
## Windows: a chord can be played from EARLY_S before its beat until its
## last beat ends. If two candidate targets overlap (e.g. playing the next
## chord early), the one whose beat is nearest wins.

enum Grade { PENDING, PERFECT, GREAT, GOOD, OK, MISS }

const PERFECT_S := 0.06
const GREAT_S := 0.12
const GOOD_S := 0.20
const POINTS := {Grade.PERFECT: 100, Grade.GREAT: 75, Grade.GOOD: 50, Grade.OK: 25, Grade.MISS: 0}

var song: Song
var tempo_scale := 1.0           # 1.0 = song's own tempo
var count_in_bars := 1
var targets: Array = []          # [{chord, symbol, t, dur, section, grade, offset}]
var _struck := false             # a key went down since the last landed chord


func setup(p_song: Song, p_tempo_scale := 1.0) -> void:
	song = p_song
	tempo_scale = p_tempo_scale
	targets.clear()
	for e in song.events:
		targets.append({
			"chord": e["chord"], "symbol": e["symbol"], "section": e["section"],
			"t": e["beat"] * seconds_per_beat(), "dur": e["beats"] * seconds_per_beat(),
			"grade": Grade.PENDING, "offset": 0.0,
		})
	_struck = false


func seconds_per_beat() -> float:
	return 60.0 / (song.bpm * tempo_scale)


func early_window() -> float:
	return minf(0.35, seconds_per_beat() * 0.5)


func count_in_seconds() -> float:
	return count_in_bars * song.beats_per_bar * seconds_per_beat()


func length_seconds() -> float:
	return song.total_beats * seconds_per_beat()


## Beat number (float) at song time t; negative during the count-in.
func beat_at(t: float) -> float:
	return t / seconds_per_beat()


## Index of the target sounding at time t (-1 before start / after end).
func current_index(t: float) -> int:
	for i in targets.size():
		var tg: Dictionary = targets[i]
		if t >= tg["t"] and t < tg["t"] + tg["dur"]:
			return i
	return -1


func note_struck() -> void:
	_struck = true


## Call whenever the held notes change. Returns the index of the target
## that just landed, or -1.
func on_notes(held: Array, t: float) -> int:
	if not _struck or held.is_empty():
		return -1
	var best := -1
	var best_d := INF
	for i in targets.size():
		var tg: Dictionary = targets[i]
		if tg["grade"] != Grade.PENDING:
			continue
		if t < tg["t"] - early_window() or t > tg["t"] + tg["dur"]:
			continue
		var m := ChordMatcher.new(tg["chord"])
		if m.evaluate_live(held) != ChordMatcher.Result.CORRECT:
			continue
		var d := absf(t - tg["t"])
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return -1
	var tg: Dictionary = targets[best]
	tg["offset"] = t - tg["t"]
	tg["grade"] = grade_for(tg["offset"])
	_struck = false
	return best


## Marks targets whose window has passed as missed. Returns their indices.
func update(t: float) -> Array[int]:
	var missed: Array[int] = []
	for i in targets.size():
		var tg: Dictionary = targets[i]
		if tg["grade"] == Grade.PENDING and t > tg["t"] + tg["dur"]:
			tg["grade"] = Grade.MISS
			missed.append(i)
	return missed


func is_finished(t: float) -> bool:
	return t > length_seconds()


static func grade_for(offset: float) -> Grade:
	var a := absf(offset)
	if a <= PERFECT_S:
		return Grade.PERFECT
	if a <= GREAT_S:
		return Grade.GREAT
	if a <= GOOD_S:
		return Grade.GOOD
	return Grade.OK


static func grade_name(g: Grade) -> String:
	match g:
		Grade.PERFECT: return "Perfect"
		Grade.GREAT: return "Great"
		Grade.GOOD: return "Good"
		Grade.OK: return "OK"
		Grade.MISS: return "Miss"
	return ""


func results() -> Dictionary:
	var counts := {}
	for g in [Grade.PERFECT, Grade.GREAT, Grade.GOOD, Grade.OK, Grade.MISS]:
		counts[g] = 0
	var points := 0
	var hits := 0
	var abs_sum := 0.0
	var signed_sum := 0.0
	for tg in targets:
		var g: Grade = tg["grade"]
		if g == Grade.PENDING:
			continue
		counts[g] += 1
		points += POINTS[g]
		if g != Grade.MISS:
			hits += 1
			abs_sum += absf(tg["offset"])
			signed_sum += tg["offset"]
	var n := targets.size()
	var pct := 100.0 * points / maxf(1.0, n * 100.0)
	return {
		"points": points, "percent": pct, "hits": hits, "total": n, "counts": counts,
		"avg_abs_ms": 1000.0 * abs_sum / maxf(1.0, hits),
		"avg_ms": 1000.0 * signed_sum / maxf(1.0, hits),
		"rank": rank_for(pct),
	}


static func rank_for(pct: float) -> String:
	if pct >= 95: return "S"
	if pct >= 85: return "A"
	if pct >= 70: return "B"
	if pct >= 50: return "C"
	return "D"
