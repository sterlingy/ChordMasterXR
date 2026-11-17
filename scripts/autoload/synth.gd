extends Node
## Built-in piano-like synth. Autoloaded as `Synth`.
##
## Tones are additive synthesis (harmonics decaying at different rates),
## baked ahead of time into res://audio/piano/note_<midi>.wav by
## tools/bake_piano.gd and shipped with the build. At runtime notes are
## loaded from those files; if one is missing it is rendered on a worker
## thread instead. Playback uses a small pool of AudioStreamPlayers.
##
## Sending chords to an external synth over MIDI ("sound_output" =
## "midi_out") needs a native plugin — Godot has no MIDI output API — and
## is not implemented yet; calls fall back to the internal synth.

const POLYPHONY := 24
const RELEASE_S := 0.25

var _cache := {}                 # midi -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _active := {}                # midi -> AudioStreamPlayer
var _next := 0
var _mutex := Mutex.new()
var _pending := {}               # midi -> true while rendering on a worker


func _ready() -> void:
	for i in POLYPHONY:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)


var _click_hi: AudioStreamWAV
var _click_lo: AudioStreamWAV
var _click_player: AudioStreamPlayer


## Metronome tick. `accent` = first beat of the bar (higher pitch).
func click(accent := false) -> void:
	if _click_player == null:
		_click_hi = _make_click(1760.0)
		_click_lo = _make_click(1175.0)
		_click_player = AudioStreamPlayer.new()
		_click_player.max_polyphony = 4
		add_child(_click_player)
	_click_player.stream = _click_hi if accent else _click_lo
	_click_player.volume_db = float(Settings.get_value("volume_db")) + (0.0 if accent else -4.0)
	_click_player.play()


static func _make_click(freq: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.035)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var env := exp(-t * 140.0)
		data.encode_s16(i * 2, int(clampf(sin(TAU * freq * t) * env * 0.8, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w


func note_on(midi: int, velocity := 90) -> void:
	var stream := _stream_for(midi)
	note_off(midi, 0.03)
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	var tw: Tween = p.get_meta("tween") if p.has_meta("tween") else null
	if tw and tw.is_valid():
		tw.kill()
	p.stream = stream
	p.volume_db = float(Settings.get_value("volume_db")) + linear_to_db(clampf(velocity / 127.0, 0.05, 1.0))
	p.play()
	_active[midi] = p


func note_off(midi: int, release := RELEASE_S) -> void:
	var p: AudioStreamPlayer = _active.get(midi)
	if p == null:
		return
	_active.erase(midi)
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -60.0, release)
	tw.tween_callback(p.stop)
	p.set_meta("tween", tw)


func all_off() -> void:
	for m in _active.keys():
		note_off(m)


## Plays a chord. `arpeggio_s` > 0 rolls it upward.
func play_chord(notes: Array, duration := 1.6, arpeggio_s := 0.0, velocity := 85) -> void:
	var i := 0
	for n in notes:
		if arpeggio_s > 0.0 and i > 0:
			await get_tree().create_timer(arpeggio_s).timeout
		note_on(int(n), velocity)
		i += 1
	await get_tree().create_timer(duration).timeout
	for n in notes:
		note_off(int(n), 0.5)


static func baked_path(midi: int) -> String:
	return PianoTone.baked_path(midi)


static func render_note(midi: int) -> AudioStreamWAV:
	return PianoTone.render(midi)


func _stream_for(midi: int) -> AudioStreamWAV:
	_mutex.lock()
	var s: AudioStreamWAV = _cache.get(midi)
	_mutex.unlock()
	if s == null and ResourceLoader.exists(baked_path(midi)):
		s = load(baked_path(midi))
	if s == null:
		# Not pre-rendered yet: render now (≈100 ms on desktop).
		s = render_note(midi)
		_mutex.lock()
		_cache[midi] = s
		_mutex.unlock()
	return s


## Loads (or renders) notes on worker threads so the main thread (and XR
## frame rate) never stalls. The user's keyboard range goes first, then the rest.
func prewarm(low: int, high: int) -> void:
	var order: Array[int] = []
	for m in range(low, high + 1):
		order.append(m)
	for m in range(21, 109):
		if not order.has(m):
			order.append(m)
	for m in order:
		_mutex.lock()
		var skip := _cache.has(m) or _pending.has(m)
		if not skip:
			_pending[m] = true
		_mutex.unlock()
		if not skip:
			WorkerThreadPool.add_task(_render_worker.bind(m), false, "synth note %d" % m)


func _render_worker(midi: int) -> void:
	var s: AudioStreamWAV
	if ResourceLoader.exists(baked_path(midi)):
		s = ResourceLoader.load(baked_path(midi))
	else:
		s = render_note(midi)
	_mutex.lock()
	_cache[midi] = s
	_pending.erase(midi)
	_mutex.unlock()
