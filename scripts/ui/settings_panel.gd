class_name SettingsPanel
extends PopupPanel
## All user options (scenes/ui/settings_panel.tscn).
##
## Controls bind to Settings through node metadata — no code needed to add
## an option in the editor:
##   setting  (String) – the Settings key, e.g. "show_notes"
##   options  (Array)  – OptionButton only: the value for each item, in order
## Supported controls: CheckButton/CheckBox (bool), OptionButton, LineEdit
## (text, saved when you press Enter or leave the field), HSlider (with a
## sibling Label named "<SliderName>Value" to show the number, optional).
##
## A few controls need code (MIDI device list, range detection, voices,
## progress); those are found by unique name (%Name).

var _learn_step := 0
var _learn_low := 0


func _ready() -> void:
	_fill_dynamic_options()
	for node in find_children("*", "", true, false):
		if node.has_meta("setting"):
			_bind(node)
	%CloseButton.pressed.connect(hide)
	var in_xr := get_tree().get_nodes_in_group("xr_keyboard_overlay").size() > 0 or XRServer.primary_interface != null
	%CalibrateXR.visible = in_xr
	%XROverlayBox.visible = in_xr
	%CalibrateXR.pressed.connect(func():
		hide()
		get_tree().call_group("xr_keyboard_overlay", "start_calibration"))
	_wire_overlay_nudges()
	%RescanButton.pressed.connect(func(): Midi.rescan())
	%BluetoothButton.visible = Midi.has_android_plugin()
	%BluetoothButton.pressed.connect(func(): Midi.scan_bluetooth(15))
	%DetectRangeButton.pressed.connect(_start_learn)
	for b in %RangePresets.get_children():
		if b.has_meta("range"):
			var r: Array = b.get_meta("range")
			b.pressed.connect(func(): _set_range(r[0], r[1]))
	%OctaveDown.pressed.connect(func(): _shift_range(-12))
	%OctaveUp.pressed.connect(func(): _shift_range(12))
	%TestVoiceButton.pressed.connect(func(): Voice.say("C sharp minor seven flat five"))
	%VoiceUnavailable.visible = not Voice.available()
	%RefreshProgress.pressed.connect(_refresh_progress)
	%ResetStats.pressed.connect(_reset_stats)
	%ResetSettings.pressed.connect(func():
		Settings.reset_to_defaults()
		_sync_all())
	%Progress.visibility_changed.connect(_refresh_progress)
	Midi.note_on.connect(_on_learn_note)
	Midi.raw_event.connect(func(t): %MidiMonitor.text = t)
	Midi.devices_changed.connect(_update_devices)
	Midi.bluetooth_status.connect(func(t): %BluetoothStatus.text = t)
	Midi.net_status.connect(func(t): %NetStatus.text = t)
	%NetStatus.text = Midi.net.status_text()


## Keyboard-overlay nudge buttons (metadata nudge + dir). Hold to repeat.
func _wire_overlay_nudges() -> void:
	var repeat := Timer.new()
	add_child(repeat)
	var nudge := func(b: Node): get_tree().call_group("xr_keyboard_overlay", "nudge", str(b.get_meta("nudge")), int(b.get_meta("dir")))
	for b in %XROverlayBox.find_children("*", "Button", true, false):
		if not b.has_meta("nudge"):
			continue
		b.button_down.connect(func():
			nudge.call(b)
			repeat.set_meta("button", b)
			repeat.start(0.45))
		b.button_up.connect(func(): repeat.stop())
	repeat.timeout.connect(func():
		var b = repeat.get_meta("button", null)
		if b is BaseButton and b.is_pressed():
			nudge.call(b)
			repeat.start(0.08)
		else:
			repeat.stop())
	%ResetOverlay.pressed.connect(func(): get_tree().call_group("xr_keyboard_overlay", "reset_adjustments"))


func open() -> void:
	var ips := NetMidiLink.local_addresses()
	%ThisDevice.text = "This device: %s  (%s)" % [Midi.net.device_name(), ", ".join(ips) if not ips.is_empty() else "no network"]
	_sync_all()
	_update_devices(Midi.devices)
	_update_range_label()
	popup_centered()


# --- generic binding -------------------------------------------------------

func _bind(node: Node) -> void:
	var key: String = node.get_meta("setting")
	if node is OptionButton:
		node.item_selected.connect(func(i):
			var opts: Array = node.get_meta("options", [])
			if i < opts.size():
				Settings.set_value(key, opts[i]))
	elif node is BaseButton and node.toggle_mode:
		node.toggled.connect(func(on): Settings.set_value(key, on))
	elif node is LineEdit:
		node.text_submitted.connect(func(t): Settings.set_value(key, t.strip_edges()))
		node.focus_exited.connect(func(): Settings.set_value(key, node.text.strip_edges()))
	elif node is Range:
		node.value_changed.connect(func(v):
			var value_label := _value_label(node)
			if value_label:
				value_label.text = str(v)
			Settings.set_value(key, v))
	_sync(node)


func _value_label(node: Node) -> Label:
	return node.get_parent().get_node_or_null(NodePath(str(node.name) + "Value")) as Label


func _sync(node: Node) -> void:
	var v = Settings.get_value(node.get_meta("setting"))
	if node is OptionButton:
		var opts: Array = node.get_meta("options", [])
		var i := opts.find(v)
		if i >= 0:
			node.select(i)
	elif node is BaseButton and node.toggle_mode:
		# null = "automatic" for net_receive: show the effective state.
		if v == null and node.get_meta("setting") == "net_receive":
			v = Midi.net.receiving
		node.set_pressed_no_signal(bool(v))
	elif node is LineEdit:
		if not node.has_focus():
			node.text = str(v) if v != null else ""
	elif node is Range:
		node.set_value_no_signal(float(v))
		var value_label := _value_label(node)
		if value_label:
			value_label.text = str(v)


func _sync_all() -> void:
	for node in find_children("*", "", true, false):
		if node.has_meta("setting"):
			_sync(node)


## Options that depend on the device or on data rather than the scene.
func _fill_dynamic_options() -> void:
	var ch: OptionButton = %MidiChannel
	ch.clear()
	var ch_vals := [-1]
	ch.add_item("Omni (all channels)")
	for i in 16:
		ch.add_item("Channel %d" % (i + 1))
		ch_vals.append(i)
	ch.set_meta("options", ch_vals)

	var oct: OptionButton = %TargetOctave
	oct.clear()
	var oct_vals := [-1]
	oct.add_item("Random (within range)")
	for o in range(1, 8):
		oct.add_item("Octave %d (C%d–B%d)" % [o, o, o])
		oct_vals.append(o)
	oct.set_meta("options", oct_vals)

	var vo: OptionButton = %VoiceSelect
	vo.clear()
	var vo_vals := [""]
	vo.add_item("System default")
	for v in Voice.voices():
		vo.add_item("%s (%s)" % [v["name"], v["language"]])
		vo_vals.append(v["id"])
	vo.set_meta("options", vo_vals)


# --- MIDI devices & range ----------------------------------------------------

func _update_devices(names: PackedStringArray) -> void:
	%DeviceList.text = "Connected: " + (", ".join(names) if not names.is_empty() else "none found. Plug in a keyboard, then Rescan.")


func _start_learn() -> void:
	_learn_step = 1
	%DetectRangeButton.text = "Press your LOWEST key…"


func _on_learn_note(pitch: int, _vel: int) -> void:
	if _learn_step == 1:
		_learn_low = pitch
		_learn_step = 2
		%DetectRangeButton.text = "Now press your HIGHEST key…"
	elif _learn_step == 2:
		_learn_step = 0
		_set_range(mini(_learn_low, pitch), maxi(_learn_low, pitch))
		%DetectRangeButton.text = "Detect: press lowest key, then highest"


func _shift_range(semitones: int) -> void:
	_set_range(int(Settings.get_value("range_low")) + semitones, int(Settings.get_value("range_high")) + semitones)


func _set_range(lo: int, hi: int) -> void:
	Settings.set_value("range_low", clampi(lo, 0, 127))
	Settings.set_value("range_high", clampi(hi, 0, 127))
	_update_range_label()


func _update_range_label() -> void:
	var lo: int = Settings.get_value("range_low")
	var hi: int = Settings.get_value("range_high")
	%RangeLabel.text = "Range: %s – %s  (%d keys)" % [Theory.midi_name(lo), Theory.midi_name(hi), hi - lo + 1]


# --- progress ----------------------------------------------------------------

func _session() -> PracticeSession:
	return get_tree().root.find_child("Session", true, false) as PracticeSession


func _refresh_progress() -> void:
	var session := _session()
	if session == null:
		return
	var lines := []
	for k in session.stats.weakest(12):
		var s: Dictionary = session.stats.per_chord[k]
		lines.append("%s   %d/%d correct   avg %.1f s" % [_pretty_key(k), s["correct"], s["attempts"], float(s["avg_ms"]) / 1000.0])
	%ProgressList.text = "\n".join(lines) if not lines.is_empty() else "Play a few chords first."


func _reset_stats() -> void:
	var session := _session()
	if session:
		session.stats.reset()
		session.stats.save()
	_refresh_progress()


static func _pretty_key(k: String) -> String:
	var parts := k.split(":")
	var c := Theory.make_chord(parts[0], parts[1]) if parts.size() == 2 else null
	return c.pretty() if c else k
