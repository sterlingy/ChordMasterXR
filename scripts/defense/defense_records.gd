class_name DefenseRecords
extends RefCounted
## Chord Defense high scores and lifetime stats, saved to
## user://defense_records.json.
##
## Leaderboards are kept per keyboard size ("5 stations", "7 stations"…),
## because more stations means more lanes to defend.

const TOP_N := 10

var save_path := "user://defense_records.json"
var boards := {}        # board key -> [{name, score, wave, kills, accuracy, best_combo, t}]
var lifetime := {       # totals across every game
	"games": 0, "kills": 0, "misfires": 0, "hits_taken": 0,
	"best_score": 0, "best_wave": 0, "best_combo": 0, "play_s": 0.0,
}
var chords := {}        # chord key -> {kills, total_ms, fastest_ms, escapes}


static func board_key(stations: int) -> String:
	return "stations_%d" % stations


func top(stations: int) -> Array:
	return boards.get(board_key(stations), [])


## Where `score` would rank (1-based) on that board, or 0 if it wouldn't.
func rank_for(stations: int, score: int) -> int:
	var b := top(stations)
	for i in b.size():
		if score > int(b[i]["score"]):
			return i + 1
	return b.size() + 1 if b.size() < TOP_N else 0


## Adds a finished game. Returns its rank on the board (0 = not in the top).
func add_game(stations: int, g: Dictionary) -> int:
	var key := board_key(stations)
	var b: Array = boards.get(key, [])
	var entry := {
		"name": str(g.get("name", "Player")), "score": int(g["score"]), "wave": int(g["wave"]),
		"kills": int(g["kills"]), "accuracy": float(g["accuracy"]), "best_combo": int(g["best_combo"]),
		"t": Time.get_unix_time_from_system(),
	}
	b.append(entry)
	b.sort_custom(func(a, c): return int(a["score"]) > int(c["score"]))
	if b.size() > TOP_N:
		b.resize(TOP_N)
	boards[key] = b
	var rank := b.find(entry) + 1
	lifetime["games"] += 1
	lifetime["kills"] += int(g["kills"])
	lifetime["misfires"] += int(g.get("misfires", 0))
	lifetime["hits_taken"] += int(g.get("hits_taken", 0))
	lifetime["best_score"] = maxi(int(lifetime["best_score"]), int(g["score"]))
	lifetime["best_wave"] = maxi(int(lifetime["best_wave"]), int(g["wave"]))
	lifetime["best_combo"] = maxi(int(lifetime["best_combo"]), int(g["best_combo"]))
	lifetime["play_s"] += float(g.get("play_s", 0.0))
	return rank


func record_kill(chord_key: String, ms: int) -> void:
	var c: Dictionary = chords.get(chord_key, {"kills": 0, "total_ms": 0, "fastest_ms": 0, "escapes": 0})
	c["kills"] += 1
	c["total_ms"] += ms
	c["fastest_ms"] = ms if int(c["fastest_ms"]) == 0 else mini(int(c["fastest_ms"]), ms)
	chords[chord_key] = c


func record_escape(chord_key: String) -> void:
	var c: Dictionary = chords.get(chord_key, {"kills": 0, "total_ms": 0, "fastest_ms": 0, "escapes": 0})
	c["escapes"] += 1
	chords[chord_key] = c


## Chords that most often got through, or were slowest to kill.
func nemesis_chords(limit := 3) -> Array:
	var rows := []
	for k in chords:
		var c: Dictionary = chords[k]
		var avg := float(c["total_ms"]) / maxf(1.0, float(c["kills"]))
		rows.append({"key": k, "score": float(c["escapes"]) * 4000.0 + avg})
	rows.sort_custom(func(a, b): return a["score"] > b["score"])
	return rows.slice(0, limit).map(func(r): return r["key"])


func save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"boards": boards, "lifetime": lifetime, "chords": chords}))


func load_from_disk() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if d is Dictionary:
		boards = d.get("boards", {})
		chords = d.get("chords", {})
		var lt: Dictionary = d.get("lifetime", {})
		for k in lt:
			lifetime[k] = lt[k]
