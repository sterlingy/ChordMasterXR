extends Node
## MIDI keyboard input. Autoloaded as `Midi`.
##
## - Opens every connected MIDI input (Godot's MIDI API is all-or-nothing).
## - Filters by channel (Settings.midi_channel, -1 = Omni).
## - Tracks currently held notes. The sustain pedal (CC64) is deliberately
##   ignored: a note counts as held only while its key is down.
## - Also accepts notes from the on-screen keyboard via `inject_note_*`
##   so everything downstream works without hardware.
## - Wi-Fi relay (NetMidiLink): forwards local MIDI to a headset, or
##   receives MIDI from a laptop. See scripts/net/.

signal note_on(pitch: int, velocity: int)
signal note_off(pitch: int)
signal held_changed(held: Array)
signal devices_changed(names: PackedStringArray)
signal raw_event(text: String)   # for the MIDI monitor

signal bluetooth_status(text: String)
signal net_status(text: String)

var held: Dictionary = {}        # pitch -> velocity
var devices: PackedStringArray = []
var last_channel := -1
var _poll_t := 0.0
## Android: Godot has no MIDI driver there, so the ChordMasterMidi Android
## plugin (addons/chordmaster_midi, source in android_plugin/) supplies it.
var _android: Object = null
var net: NetMidiLink

## Computer-keyboard piano (Settings "qwerty_input"): home row = white keys,
## row above = black keys, Z/X shift the octave.
const QWERTY := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6,
	KEY_G: 7, KEY_Y: 8, KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12, KEY_O: 13,
	KEY_L: 14, KEY_P: 15, KEY_SEMICOLON: 16, KEY_APOSTROPHE: 17,
}
var qwerty_octave := 4                 # A key = C4 (middle C)
var _qwerty_down := {}                 # keycode -> midi


func _ready() -> void:
	net = NetMidiLink.new()
	net.name = "NetMidi"
	net.on_message = func(ch: int, type: int, d1: int, d2: int):
		_dispatch(ch, type, d1, d2, true)
	net.status_changed.connect(func(t: String): net_status.emit(t))
	add_child(net)
	_apply_net_settings()
	Settings.changed.connect(func(key: String):
		if key.begins_with("net_"):
			_apply_net_settings())
	if Engine.has_singleton("ChordMasterMidi"):
		_android = Engine.get_singleton("ChordMasterMidi")
		_android.connect("midi_message", _on_android_message)
		_android.connect("devices_changed", _on_android_devices)
		_android.connect("bluetooth_status", func(t: String): bluetooth_status.emit(t))
		_android.call("start")
		return
	OS.open_midi_inputs()
	_refresh_devices()


func _exit_tree() -> void:
	if _android == null:
		OS.close_midi_inputs()


func _apply_net_settings() -> void:
	net.target = str(Settings.get_value("net_target")).strip_edges()
	net.set_sending(bool(Settings.get_value("net_send")))
	var rx = Settings.get_value("net_receive")
	# Default: receive on Android/XR (the headset), not on desktop (binding a
	# port there makes Windows Firewall pop up).
	net.set_receiving(OS.has_feature("android") if rx == null else bool(rx))


func has_android_plugin() -> bool:
	return _android != null


## Android only: scan for Bluetooth LE MIDI keyboards and connect them.
func scan_bluetooth(seconds := 15) -> void:
	if _android:
		_android.call("scanBluetooth", seconds)
	else:
		bluetooth_status.emit("Bluetooth MIDI scanning is only needed on Android. On this platform, pair the keyboard in the system settings.")


func _process(delta: float) -> void:
	if _android:
		return
	# Hot-plug: re-scan every 2 s (cheap).
	_poll_t += delta
	if _poll_t >= 2.0:
		_poll_t = 0.0
		var now := OS.get_connected_midi_inputs()
		if now != devices:
			OS.close_midi_inputs()
			OS.open_midi_inputs()
			_refresh_devices()


func _refresh_devices() -> void:
	devices = OS.get_connected_midi_inputs()
	devices_changed.emit(devices)


func rescan() -> void:
	if _android:
		_on_android_devices(str(_android.call("getDeviceNames")))
		return
	OS.close_midi_inputs()
	OS.open_midi_inputs()
	_refresh_devices()


func _on_android_devices(names: String) -> void:
	devices = PackedStringArray(names.split("
", false))
	devices_changed.emit(devices)


## Raw MIDI bytes from the Android plugin (status, data1, data2).
func _on_android_message(status: int, d1: int, d2: int) -> void:
	var type := status >> 4
	_dispatch(status & 0x0F, type, d1, d2, false)


## Raw channel message -> handle_message. `from_network` messages aren't
## forwarded again (no relay loops).
func _dispatch(channel: int, type: int, d1: int, d2: int, from_network: bool) -> void:
	var is_cc := type == MIDI_MESSAGE_CONTROL_CHANGE
	handle_message(channel, type, d1, d2, d1 if is_cc else 0, d2 if is_cc else 0, from_network)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and Settings.get_value("qwerty_input"):
		_qwerty(event as InputEventKey)
		return
	if not event is InputEventMIDI:
		return
	var e := event as InputEventMIDI
	handle_message(e.channel, e.message, e.pitch, e.velocity, e.controller_number, e.controller_value, false)


## Shared by desktop/web (InputEventMIDI) and Android (plugin) input.
func handle_message(channel: int, message: int, pitch: int, velocity: int, cc_num := 0, cc_val := 0, from_network := false) -> void:
	if not from_network and net and net.sending and message >= 0x8 and message <= 0xE:
		var is_cc := message == MIDI_MESSAGE_CONTROL_CHANGE
		net.send_midi((message << 4) | channel, cc_num if is_cc else pitch, cc_val if is_cc else velocity)
	var ch_setting: int = Settings.get_value("midi_channel")
	last_channel = channel
	raw_event.emit("ch%d msg%d pitch%d vel%d cc%d=%d" % [channel + 1, message, pitch, velocity, cc_num, cc_val])
	if ch_setting >= 0 and channel != ch_setting:
		return
	match message:
		MIDI_MESSAGE_NOTE_ON:
			if velocity == 0:
				_release(pitch)
			else:
				_press(pitch, velocity)
		MIDI_MESSAGE_NOTE_OFF:
			_release(pitch)
		MIDI_MESSAGE_CONTROL_CHANGE:
			# 123 = All Notes Off, 120 = All Sound Off. CC64 (sustain) ignored.
			if cc_num == 123 or cc_num == 120:
				release_all()


func _qwerty(e: InputEventKey) -> void:
	if e.echo or e.ctrl_pressed or e.alt_pressed or e.meta_pressed:
		return
	# Don't steal typing from text fields (e.g. the custom chord list).
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var key := e.physical_keycode
	if e.pressed and key == KEY_Z:
		qwerty_octave = maxi(0, qwerty_octave - 1)
		get_viewport().set_input_as_handled()
		return
	if e.pressed and key == KEY_X:
		qwerty_octave = mini(8, qwerty_octave + 1)
		get_viewport().set_input_as_handled()
		return
	if e.pressed and QWERTY.has(key):
		var m: int = 12 * (qwerty_octave + 1) + QWERTY[key]
		_qwerty_down[key] = m
		_press(m, 96)
		get_viewport().set_input_as_handled()
	elif not e.pressed and _qwerty_down.has(key):
		_release(_qwerty_down[key])
		_qwerty_down.erase(key)
		get_viewport().set_input_as_handled()


func _press(pitch: int, velocity: int) -> void:
	held[pitch] = velocity
	note_on.emit(pitch, velocity)
	held_changed.emit(held_notes())


func _release(pitch: int) -> void:
	if held.erase(pitch):
		note_off.emit(pitch)
		held_changed.emit(held_notes())


func release_all() -> void:
	if held.is_empty():
		return
	for p in held.keys():
		note_off.emit(p)
	held.clear()
	held_changed.emit(held_notes())


func held_notes() -> Array:
	var a := held.keys()
	a.sort()
	return a


func inject_note_on(pitch: int, velocity := 90) -> void:
	_press(pitch, velocity)


func inject_note_off(pitch: int) -> void:
	_release(pitch)
