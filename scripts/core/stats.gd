class_name PracticeStats
extends RefCounted
## Per-chord performance history plus a raw attempt log.
##
## Every attempt is logged (for future gamification and analytics), and a
## per-chord summary drives adaptive weighting: chords you miss or play
## slowly come up more often; mastered chords fade back.

const LOG_LIMIT := 5000

var per_chord := {}   # key -> {attempts, correct, fails, avg_ms, streak, last_t}
var attempt_log := []          # [{t, key, mode, result, ms, wrong:[...], inv, oct}]
var save_path := "user://stats.json"


func record(chord_key: String, mode: String, correct: bool, ms: int, extra := {}) -> void:
	var now := Time.get_unix_time_from_system()
	var s: Dictionary = per_chord.get(chord_key, {"attempts": 0, "correct": 0, "fails": 0, "avg_ms": 0.0, "streak": 0, "last_t": 0.0})
	s["attempts"] += 1
	if correct:
		s["correct"] += 1
		s["streak"] += 1
		# exponential moving average of solve time (correct answers only)
		s["avg_ms"] = float(ms) if s["correct"] == 1 else lerpf(s["avg_ms"], float(ms), 0.3)
	else:
		s["fails"] += 1
		s["streak"] = 0
	s["last_t"] = now
	per_chord[chord_key] = s
	var entry := {"t": now, "key": chord_key, "mode": mode, "ok": correct, "ms": ms}
	entry.merge(extra)
	attempt_log.append(entry)
	if attempt_log.size() > LOG_LIMIT:
		attempt_log = attempt_log.slice(attempt_log.size() - LOG_LIMIT)


## Sampling weight for adaptive practice. Unseen chords get a moderate
## boost so they get introduced; weak/slow chords get more.
func weight(chord_key: String) -> float:
	if not per_chord.has(chord_key):
		return 2.0
	var s: Dictionary = per_chord[chord_key]
	var attempts := float(s["attempts"])
	var fail_rate := float(s["fails"]) / maxf(attempts, 1.0)
	var slow := clampf((float(s["avg_ms"]) - 2500.0) / 5000.0, 0.0, 1.5)
	var mastery := clampf(float(s["streak"]) / 6.0, 0.0, 1.0)
	return maxf(0.15, 1.0 + 3.0 * fail_rate + slow - 0.7 * mastery)


func accuracy(chord_key: String) -> float:
	if not per_chord.has(chord_key):
		return -1.0
	var s: Dictionary = per_chord[chord_key]
	return float(s["correct"]) / maxf(float(s["attempts"]), 1.0)


## Chords sorted weakest-first (only ones attempted).
func weakest(limit := 10) -> Array:
	var keys := per_chord.keys()
	keys.sort_custom(func(a, b): return weight(a) > weight(b))
	return keys.slice(0, limit)


func session_summary(since_t: float) -> Dictionary:
	var n := 0
	var ok := 0
	var total_ms := 0
	for e in attempt_log:
		if e["t"] >= since_t:
			n += 1
			if e["ok"]:
				ok += 1
				total_ms += int(e["ms"])
	return {"attempts": n, "correct": ok, "avg_ms": (total_ms / ok) if ok > 0 else 0}


func save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"per_chord": per_chord, "attempt_log": attempt_log}))


func load_from_disk() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		per_chord = d.get("per_chord", {})
		attempt_log = d.get("attempt_log", [])


func reset() -> void:
	per_chord = {}
	attempt_log = []
