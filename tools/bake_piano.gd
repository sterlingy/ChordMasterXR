extends SceneTree
## Bakes the built-in piano tones to res://audio/piano/*.wav so the app
## loads them instead of synthesizing at startup.
## Run:  godot --headless --path . -s tools/bake_piano.gd



func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://audio/piano")
	var t := Time.get_ticks_msec()
	for m in range(21, 109):
		var wav: AudioStreamWAV = PianoTone.render(m)
		wav.save_to_wav(PianoTone.baked_path(m))
	print("Baked 88 notes in %d ms" % (Time.get_ticks_msec() - t))
	quit()
