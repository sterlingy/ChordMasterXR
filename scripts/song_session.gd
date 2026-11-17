class_name SongSession
extends Node
## Plays a song's chord chart in time: count-in, metronome, optional
## backing chords, and timing judgement of what you play (SongEngine).
## Lives in practice_screen.tscn; the screen shows what it emits.

signal started(song: Song)
signal beat(beat_in_bar: int, beats_per_bar: int, count_in: bool)
signal target_changed(index: int)
signal landed(index: int, grade: SongEngine.Grade, offset: float)
signal missed(index: int)
signal finished(results: Dictionary)
signal stopped

var library: Array[Song] = []
var engine := SongEngine.new()
var running := false
## Paused: the song clock stops (no clicks, no backing, nothing judged);
## resuming carries on from the same spot.
var paused := false
var _paused_usec := 0

var _start_usec := 0
var _last_beat := -999
var _last_target := -2
var _latency := 0.0


func _ready() -> void:
	library = Song.load_library()
	Midi.note_on.connect(func(_p, _v):
		if running and not paused:
			engine.note_struck())
	Midi.held_changed.connect(_on_held)


func song_by_id(id: String) -> Song:
	for s in library:
		if s.id == id:
			return s
	return library[0] if not library.is_empty() else null


## Starts `song` at `bpm` beats per minute (<= 0 = the song's own tempo).
func start(song: Song, bpm := 0.0) -> void:
	if song == null:
		return
	engine.setup(song, (bpm / song.bpm) if bpm > 0.0 else 1.0)
	engine.count_in_bars = 1 if Settings.get_value("song_count_in") else 0
	# Players react to what they *hear*; audio comes out a little after we
	# schedule it, so judge against the heard beat.
	_latency = AudioServer.get_output_latency()
	_start_usec = Time.get_ticks_usec() + int(engine.count_in_seconds() * 1e6)
	_last_beat = -999
	_last_target = -2
	paused = false
	running = true
	started.emit(song)


func stop() -> void:
	paused = false
	if running:
		running = false
		Synth.all_off()
		stopped.emit()


func set_paused(on: bool) -> void:
	if on == paused:
		return
	paused = on
	if on:
		_paused_usec = Time.get_ticks_usec()
		Synth.all_off()
	else:
		_start_usec += Time.get_ticks_usec() - _paused_usec


## Song time in seconds (negative during the count-in).
func song_time() -> float:
	var now := _paused_usec if paused else Time.get_ticks_usec()
	return (now - _start_usec) / 1e6


func _process(_delta: float) -> void:
	if not running or paused:
		return
	var t := song_time()
	var spb := engine.seconds_per_beat()
	var b := floori(t / spb + 0.0001)
	if b != _last_beat:
		_last_beat = b
		var bpb := engine.song.beats_per_bar
		var in_bar := posmod(b, bpb)
		var count_in := t < 0.0
		if count_in or Settings.get_value("metronome_on"):
			Synth.click(in_bar == 0)
		beat.emit(in_bar, bpb, count_in)
	var idx := engine.current_index(t)
	if idx != _last_target:
		_last_target = idx
		if idx >= 0 and Settings.get_value("song_backing"):
			var tg: Dictionary = engine.targets[idx]
			var rm := ChordPrompt.place_root(tg["chord"], 0, 48, 72)
			if rm >= 0:
				Synth.play_chord(tg["chord"].voicing(rm, 0), tg["dur"] * 0.9, 0.0, 60)
		target_changed.emit(idx)
	for i in engine.update(t - _latency):
		missed.emit(i)
	if engine.is_finished(t - _latency):
		running = false
		finished.emit(engine.results())


func _on_held(held: Array) -> void:
	if not running or paused:
		return
	var i := engine.on_notes(held, song_time() - _latency)
	if i >= 0:
		var tg: Dictionary = engine.targets[i]
		landed.emit(i, tg["grade"], tg["offset"])
