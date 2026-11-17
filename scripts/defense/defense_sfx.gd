class_name DefenseSfx
extends Node
## Chord Defense sound effects, synthesised once at start-up (no audio
## files): laser zap, explosion, station hit, misfire buzz. Musical cues
## (wave clear, boss down) use the piano Synth so they sound in tune.

const RATE := 22050

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	_streams["zap"] = _render(0.16, func(t: float, ph: Array) -> float:
		var f := lerpf(1600.0, 260.0, t / 0.16)
		ph[0] += TAU * f / RATE
		return sin(ph[0]) * exp(-t * 14.0) * 0.5)
	_streams["boom"] = _render(0.45, func(t: float, ph: Array) -> float:
		ph[0] += TAU * lerpf(110.0, 40.0, t / 0.45) / RATE
		var noise := randf_range(-1.0, 1.0)
		ph[1] = lerpf(ph[1], noise, 0.18)          # low-passed noise
		return (ph[1] * 0.8 + sin(ph[0]) * 0.5) * exp(-t * 7.0) * 0.6)
	_streams["hit"] = _render(0.5, func(t: float, ph: Array) -> float:
		ph[0] += TAU * lerpf(90.0, 45.0, t / 0.5) / RATE
		var sq := 1.0 if sin(ph[0]) > 0.0 else -1.0
		return sq * exp(-t * 5.0) * 0.35)
	_streams["misfire"] = _render(0.18, func(t: float, ph: Array) -> float:
		ph[0] += TAU * 140.0 / RATE
		var saw := fposmod(ph[0] / TAU, 1.0) * 2.0 - 1.0
		return saw * exp(-t * 12.0) * 0.25)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play(sound: String, gain_db := 0.0) -> void:
	if not _streams.has(sound):
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _streams[sound]
	p.volume_db = float(Settings.get_value("volume_db")) - 6.0 + gain_db
	p.play()


## A short rising arpeggio of `notes` (MIDI) on the piano.
func fanfare(notes: Array) -> void:
	Synth.play_chord(notes, 1.4, 0.07, 70)


func _render(seconds: float, gen: Callable) -> AudioStreamWAV:
	var n := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(n * 2)
	var ph := [0.0, 0.0]
	for i in n:
		var t := float(i) / RATE
		# Short fade-in avoids clicks.
		var v: float = gen.call(t, ph) * minf(1.0, t * 400.0)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = data
	return w
