class_name DefenseLeaderboard
extends Node
## Optional global leaderboard over HTTP. Does nothing unless the
## `leaderboard_url` setting is set. Protocol (see tools/leaderboard_worker.js
## for a ready-to-deploy server):
##
##   POST {url}/scores          body: {board, name, score, wave, kills,
##                                     accuracy, best_combo, version}
##                              reply: {rank, total}
##   GET  {url}/scores?board=…  reply: [{name, score, wave}, …] best first
##
## Results arrive through `result` as {ok, rank, total, rows, error}.

signal result(info: Dictionary)

const VERSION := "1"

var _post: HTTPRequest
var _get: HTTPRequest
var _pending := {}


func _ready() -> void:
	_post = HTTPRequest.new()
	_post.timeout = 8.0
	add_child(_post)
	_get = HTTPRequest.new()
	_get.timeout = 8.0
	add_child(_get)
	_post.request_completed.connect(_on_posted)
	_get.request_completed.connect(_on_fetched)


func base_url() -> String:
	return str(Settings.get_value("leaderboard_url")).strip_edges().trim_suffix("/")


func enabled() -> bool:
	var u := base_url()
	return u.begins_with("https://") or u.begins_with("http://")


## Sends a finished game, then fetches the board.
func submit(stations: int, g: Dictionary) -> void:
	if not enabled():
		return
	_pending = {"board": DefenseRecords.board_key(stations)}
	var body := JSON.stringify({
		"board": _pending["board"], "name": str(g.get("name", "Player")).substr(0, 16),
		"score": int(g["score"]), "wave": int(g["wave"]), "kills": int(g["kills"]),
		"accuracy": snappedf(float(g["accuracy"]), 0.001), "best_combo": int(g["best_combo"]),
		"version": VERSION,
	})
	var err := _post.request(base_url() + "/scores", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		result.emit({"ok": false, "error": "couldn't send (error %d)" % err})


func _on_posted(res: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if res != HTTPRequest.RESULT_SUCCESS or code >= 300:
		result.emit({"ok": false, "error": "server didn't accept the score (%s)" % (str(code) if res == HTTPRequest.RESULT_SUCCESS else "no connection")})
		return
	var d = JSON.parse_string(body.get_string_from_utf8())
	if d is Dictionary:
		_pending["rank"] = int(d.get("rank", 0))
		_pending["total"] = int(d.get("total", 0))
	_get.request(base_url() + "/scores?board=" + str(_pending["board"]).uri_encode())


func _on_fetched(res: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if res != HTTPRequest.RESULT_SUCCESS or code >= 300:
		result.emit({"ok": false, "error": "couldn't load the global board"})
		return
	var rows = JSON.parse_string(body.get_string_from_utf8())
	result.emit({"ok": true, "rank": _pending.get("rank", 0), "total": _pending.get("total", 0),
		"rows": rows if rows is Array else []})
