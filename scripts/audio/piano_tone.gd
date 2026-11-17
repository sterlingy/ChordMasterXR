class_name PianoTone
extends RefCounted
## Additive-synthesis piano-like tone renderer (no scene/autoload access, so
## it can run on worker threads and from the bake tool).

const MIX_RATE := 22050
const NOTE_SECONDS := 2.6


static func baked_path(midi: int) -> String:
	return "res://audio/piano/note_%d.wav" % midi


## Renders a decaying piano-ish tone. Pure function, also used by tests.
static func render(midi: int) -> AudioStreamWAV:
	var freq := 440.0 * pow(2.0, (midi - 69) / 12.0)
	var frames := int(MIX_RATE * NOTE_SECONDS)
	var data := PackedByteArray()
	data.resize(frames * 2)
	# Harmonic amplitudes and decay rates (higher partials die faster).
	# Lower notes get brighter spectra, like a real piano.
	var brightness := clampf(1.3 - (midi - 36) / 60.0, 0.5, 1.3)
	var amps := [1.0, 0.55 * brightness, 0.3 * brightness, 0.18 * brightness, 0.1 * brightness, 0.05 * brightness]
	var decays := [1.6, 2.4, 3.4, 4.6, 6.0, 8.0]
	var nyquist := MIX_RATE / 2.0
	var two_pi_f := TAU * freq / MIX_RATE
	var attack := int(0.004 * MIX_RATE)
	# Pitch-dependent overall decay: high notes ring shorter.
	var base_decay := 0.9 + maxf(0.0, (midi - 60) / 24.0)
	var norm := 0.32
	for i in frames:
		var t := float(i) / MIX_RATE
		var v := 0.0
		for h in amps.size():
			var hf: float = freq * (h + 1)
			if hf >= nyquist:
				break
			v += amps[h] * exp(-decays[h] * base_decay * t) * sin(two_pi_f * (h + 1) * i)
		var env := 1.0 if i >= attack else float(i) / attack
		# Short fade at the very end to avoid a click.
		if i > frames - 400:
			env *= float(frames - i) / 400.0
		var sample := int(clampf(v * env * norm, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
