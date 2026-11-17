class_name PracticeScreen
extends Control
## The main practice screen (scenes/ui/practice_screen.tscn).
##
## The layout lives in the scene — open it in the editor to change it. This
## script only looks nodes up by their unique name (%Name) and wires them
## to the PracticeSession. The same scene runs full-window on desktop/web
## and inside a SubViewport panel in XR.

@onready var session: PracticeSession = %Session
@onready var _mode_btn: OptionButton = %ModeButton
@onready var _exercise_btn: OptionButton = %ExerciseButton
@onready var _midi_label: Label = %MidiLabel
@onready var _score_label: Label = %ScoreLabel
@onready var _pool_label: Label = %PoolLabel
@onready var _chord_label: Label = %ChordLabel
@onready var _sub_label: Label = %SubLabel
@onready var _notes_label: Label = %NotesLabel
@onready var _below_label: Label = %BelowLabel
@onready var _feedback: Label = %Feedback
@onready var _staff: StaffView = %Staff
@onready var _staff_panel: Control = %StaffPanel
@onready var _keyboard: PianoKeyboard = %Keyboard
@onready var _choices_box: HBoxContainer = %Choices
@onready var _select_box: HBoxContainer = %SelectBar
@onready var _settings_panel: SettingsPanel = %SettingsPanel
@onready var _pool_panel: PoolPanel = %PoolPanel
@onready var _song: SongSession = %SongSession
@onready var _song_bar: HBoxContainer = %SongBar
@onready var _song_select: OptionButton = %SongSelect
@onready var _beats: BeatIndicator = %Beats
@onready var _defense: DefenseView = %GameArea

const MODES := ["play", "name", "song", "defense"]
## Font size of the top-bar dropdown lists (the theme default is 18).
const MENU_FONT_SIZE := 19

var _feedback_tw: Tween


func _ready() -> void:
	RenderingServer.set_default_clear_color(UITheme.BG)
	# The bundled music font supplies ♭/♯ everywhere, including web.
	Theory.unicode_accidentals = UITheme.music_font().has_char(0x266D)
	_wire_controls()
	session.prompt_changed.connect(_on_prompt)
	session.feedback.connect(_on_feedback)
	session.choice_feedback.connect(_on_choice_feedback)
	session.score_changed.connect(_on_score)
	session.no_chords.connect(_on_no_chords)
	Midi.held_changed.connect(_on_held)
	Midi.devices_changed.connect(_on_devices)
	Midi.net_status.connect(func(_t): _on_devices(Midi.devices))
	Settings.changed.connect(_on_setting_changed)
	_on_devices(Midi.devices)
	_staff_panel.resized.connect(_center_labels)
	resized.connect(_center_labels)
	_apply_display_settings()
	session.start()
	_center_labels.call_deferred()


func _wire_controls() -> void:
	# Exercise list comes from the engine so new exercise types appear here
	# automatically.
	_exercise_btn.clear()
	for i in ExerciseEngine.TYPES.size():
		var t: String = ExerciseEngine.TYPES[i]
		_exercise_btn.add_item(ExerciseEngine.TYPE_LABELS[t], i)
		_exercise_btn.set_item_tooltip(i, ExerciseEngine.TYPE_HINTS[t])
	for ob in [_mode_btn, _exercise_btn]:
		ob.get_popup().add_theme_font_size_override("font_size", MENU_FONT_SIZE)
	_mode_btn.item_selected.connect(func(i):
		_set_paused(false)
		_song.stop()
		_stop_defense()
		Settings.set_value("practice_mode", MODES[i])
		session.start()
		_apply_display_settings())
	_exercise_btn.item_selected.connect(func(i):
		Settings.set_value("exercise_type", ExerciseEngine.TYPES[i])
		session.start())
	# Only one panel open at a time: opening one closes the other.
	%ChordsButton.pressed.connect(func():
		_settings_panel.hide()
		_pool_panel.open())
	%SettingsButton.pressed.connect(func():
		_pool_panel.hide()
		_settings_panel.open())
	%PauseButton.toggled.connect(_set_paused)
	# Paused = yellow, so it's obvious the app isn't checking you.
	for st in ["pressed", "hover_pressed"]:
		var sb := (%PauseButton.get_theme_stylebox(st) as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color = Color(1.0, 0.86, 0.2)
		%PauseButton.add_theme_stylebox_override(st, sb)
	for c in ["font_pressed_color", "font_hover_pressed_color"]:
		%PauseButton.add_theme_color_override(c, UITheme.BG)
	# Hear / Say are toggles (play / speak every new chord); switching one on
	# also plays or speaks the current chord so you hear the effect at once.
	%HearButton.toggled.connect(func(on): if on: session.play_prompt_chord())
	%SayButton.toggled.connect(func(on): if on and session.prompt: Voice.say_prompt(session.prompt))
	%SayButton.disabled = not Voice.available()
	%SkipButton.pressed.connect(func(): session.skip())
	# Toggle buttons in the left strip bind to a Settings key (metadata
	# "setting"), like the Settings panel; they stay in sync with it.
	for b in %PromptButtons.find_children("*", "BaseButton", true, false):
		if b.has_meta("setting") and b.toggle_mode:
			var key: String = b.get_meta("setting")
			b.set_pressed_no_signal(bool(Settings.get_value(key)))
			b.toggled.connect(func(on): Settings.set_value(key, on))
	%ClearButton.pressed.connect(func():
		_keyboard.clear_selection()
		_keyboard.set_wrong([]))
	%SubmitButton.pressed.connect(_submit_selection)
	_keyboard.key_pressed.connect(func(m): Midi.inject_note_on(m))
	_keyboard.key_released.connect(func(m): Midi.inject_note_off(m))
	_keyboard.selection_changed.connect(_on_selection_changed)
	_pool_panel.pool_applied.connect(func(): session.start())
	_wire_song()
	_wire_defense()


# --- display state ------------------------------------------------------

func _apply_display_settings() -> void:
	_keyboard.low = Settings.get_value("range_low")
	_keyboard.high = Settings.get_value("range_high")
	_staff.clef_mode = Settings.get_value("clef_mode")
	_staff.accidental_mode = Settings.get_value("accidental_mode")
	var mode := session.practice_mode()
	var name_mode := mode == "name"
	var song_mode := mode == "song"
	var defense_mode := mode == "defense"
	_mode_btn.select(maxi(0, MODES.find(mode)))
	_exercise_btn.select(maxi(0, ExerciseEngine.TYPES.find(Settings.get_value("exercise_type"))))
	_exercise_btn.visible = not song_mode and not defense_mode
	%ExerciseHeading.visible = not song_mode and not defense_mode
	%SkipButton.visible = not song_mode and not defense_mode
	%ChordsButton.visible = not song_mode
	_pool_label.visible = not song_mode
	_score_label.visible = not song_mode and not defense_mode
	# Chord Defense: the game replaces the notation; names are always shown.
	_defense.visible = defense_mode
	%DefenseBar.visible = defense_mode
	%NameToggle.visible = not defense_mode
	%TextCol.visible = not defense_mode
	_defense.game.set_show_notes(bool(Settings.get_value("show_notes")))
	_defense.game.set_show_hints(bool(Settings.get_value("show_keyboard_hint")))
	%DefensePool.set_pressed_no_signal(bool(Settings.get_value("defense_use_pool")))
	if not _defense.game.is_running():
		_defense.game.configure(int(Settings.get_value("range_low")), int(Settings.get_value("range_high")))
	var select_mode: bool = mode == "play" and Settings.get_value("input_mode") == "select"
	_choices_box.visible = name_mode
	_select_box.visible = select_mode
	_song_bar.visible = song_mode
	_beats.visible = song_mode
	%ActionBox.visible = not song_mode and not defense_mode
	for b in %PromptButtons.find_children("*", "BaseButton", true, false):
		if b.has_meta("setting") and b.toggle_mode:
			b.set_pressed_no_signal(bool(Settings.get_value(b.get_meta("setting"))))
	_keyboard.interaction = "none" if name_mode else ("select" if select_mode else "play")
	_staff.visible = (Settings.get_value("show_staff") or name_mode) and not defense_mode
	_pool_label.text = "Pool: " + Settings.pool().describe()
	_refresh_prompt_view()


func _on_setting_changed(key: String) -> void:
	_apply_display_settings()
	if key == "midi_channel":
		_on_devices(Midi.devices)
	if key in ["range_low", "range_high", "strict_inversion", "random_inversions", "octave_mode",
			"target_octave", "input_mode", "name_choices"]:
		session.start()


func _refresh_prompt_view() -> void:
	if session.practice_mode() == "song":
		_song_idle_view()
		return
	if session.practice_mode() == "defense":
		_set_big("")
		_set_sub("")
		_set_notes("")
		_set_below("")
		return
	var p := session.prompt
	if p == null:
		return
	var name_mode := session.practice_mode() == "name"
	var answered := session.state == PracticeSession.State.ADVANCING
	# Without the staff, the chord name is the prompt, so show it big.
	_set_big("" if _staff.visible else p.title())
	_set_sub("Which chord is this?" if name_mode else p.subtitle(false))
	_set_notes(_notes_text(p) if Settings.get_value("show_notes") and not name_mode else "")
	_set_below("")
	var voiced := p.voiced_tones()
	# Name It: the written chord name is the answer, so only show it after.
	var show_name: bool = (name_mode and answered) or (not name_mode and Settings.get_value("show_chord_name"))
	_staff.chord_label = p.chord.pretty() if show_name else ""
	_staff.show_chord(voiced, _key_sig_for(p))
	var hint_on: bool = Settings.get_value("show_keyboard_hint") and not name_mode and not session.paused
	_keyboard.set_hints(p.voicing() if hint_on else [])


## Chord name, notes and the other notation-panel text are centred on the
## whole window (like the chord on the staff), not just on this panel.
func _center_labels() -> void:
	# Each label starts at the panel's left edge and is made just wide
	# enough that its middle is the window's middle.
	for l in [_chord_label, _sub_label, _notes_label, _below_label]:
		var r: Rect2 = l.get_parent().get_global_rect()
		var w := 2.0 * (get_viewport_rect().size.x * 0.5 - r.position.x)
		var fits := w > 50.0 and w <= r.size.x
		l.custom_minimum_size.x = w if fits else 0.0
		l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if fits else Control.SIZE_FILL
	_staff.queue_redraw()


## Pause: the keyboard still plays, but nothing is checked or scored and
## the session (or song) waits where it is until resumed.
func _set_paused(on: bool) -> void:
	%PauseButton.set_pressed_no_signal(on)
	%PauseButton.text = "Resume" if on else "Pause"
	session.set_paused(on)
	_song.set_paused(on)
	_defense.game.set_paused(on)
	%SkipButton.disabled = on
	for c in _choices_box.get_children():
		if c is BaseButton and not c.has_meta("answered"):
			c.disabled = on
	_keyboard.set_wrong([])
	if on:
		_keyboard.set_hints([])
		_show_feedback("Paused — play freely. Press Resume to carry on.", UITheme.ACCENT)
	else:
		_show_feedback(" ", UITheme.TEXT)
		if session.practice_mode() == "defense":
			_defense.game.set_show_hints(bool(Settings.get_value("show_keyboard_hint")))
		elif session.practice_mode() != "song":
			_refresh_prompt_view()


func _notes_text(p: ChordPrompt) -> String:
	var parts := []
	for pair in p.voiced_tones():
		parts.append(pair[1].pretty())
	var t := "  –  ".join(parts)
	# Say which inversion the written notes are in, unless it's root position.
	if p.inversion > 0:
		t += "   ·   " + Theory.inversion_name(p.inversion)
	return t


## Big text in the notation panel (count-in, song title, rank, or the chord
## when the staff is off). Hidden when empty.
func _set_big(t: String, font_size := 64) -> void:
	_chord_label.text = t
	_chord_label.add_theme_font_size_override("font_size", font_size)
	_chord_label.visible = t != ""


func _set_sub(t: String) -> void:
	_sub_label.text = t
	_sub_label.visible = t != ""


func _set_notes(t: String) -> void:
	# If notes + inversion would run into the Skip/Pause buttons, put the
	# inversion on its own line.
	var sep := "   ·   "
	if t.contains(sep):
		var font := _notes_label.get_theme_font("font")
		var fs := _notes_label.get_theme_font_size("font_size")
		var half := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x * 0.5
		var room: float = %SkipButton.get_parent().get_global_rect().position.x - get_viewport_rect().size.x * 0.5 - 12.0
		if half > room:
			t = t.replace(sep, "\n")
	_notes_label.text = t
	_notes_label.visible = t != ""


func _set_below(t: String) -> void:
	_below_label.text = t
	_below_label.visible = t != ""


func _key_sig_for(p: ChordPrompt) -> int:
	if p.key_tonic != "":
		return Theory.key_signature(Theory.parse_note(p.key_tonic), p.key_scale)
	var tags: Array = p.chord.def()["tags"]
	var minorish := tags.has("minor") or tags.has("diminished")
	return Theory.key_signature(p.chord.root, "natural_minor" if minorish else "major")


# --- session events ----------------------------------------------------

func _on_prompt(p: ChordPrompt, choices: Array) -> void:
	_keyboard.set_wrong([])
	_keyboard.clear_selection()
	_show_feedback(" ", UITheme.TEXT)
	_refresh_prompt_view()
	for c in _choices_box.get_children():
		c.queue_free()
	for chord in choices:
		var b := Button.new()
		b.text = chord.pretty()
		b.custom_minimum_size = Vector2(170, 84)
		b.add_theme_font_size_override("font_size", 32)
		b.set_meta("chord", chord)
		b.disabled = session.paused
		b.pressed.connect(func(): session.answer_choice(chord))
		_choices_box.add_child(b)


func _on_feedback(r: ChordMatcher.Result, wrong: Array) -> void:
	if r == ChordMatcher.Result.CORRECT:
		_show_feedback("✓ " + ChordMatcher.result_text(r), UITheme.GOOD)
		_keyboard.flash_correct(session.prompt.voicing() if Settings.get_value("input_mode") == "select" else Midi.held_notes())
	else:
		var msg := ChordMatcher.result_text(r)
		if r == ChordMatcher.Result.WRONG_NOTE and not wrong.is_empty():
			var names := []
			for m in wrong:
				names.append(Theory.midi_name(int(m), session.prompt.chord.root.alter < 0))
			msg += ": " + ", ".join(names)
		if Settings.get_value("input_mode") == "midi":
			msg += " — release and try again"
		_show_feedback("✗ " + msg, UITheme.BAD)
		_keyboard.set_wrong(wrong)


func _on_choice_feedback(chord: Theory.Chord, ok: bool) -> void:
	for b in _choices_box.get_children():
		if b.get_meta("chord").equals(chord):
			b.add_theme_color_override("font_color", UITheme.GOOD if ok else UITheme.BAD)
			b.disabled = not ok
			b.set_meta("answered", true)
	if ok:
		_show_feedback("✓ " + session.prompt.chord.pretty(), UITheme.GOOD)
		_staff.chord_label = session.prompt.chord.pretty()
	else:
		_show_feedback("✗ Not " + chord.pretty() + " — try again", UITheme.BAD)


func _on_score(info: Dictionary) -> void:
	var acc := ""
	if info["attempts"] > 0:
		acc = "   ·   accuracy %d%%" % roundi(100.0 * info["correct"] / info["attempts"])
	_score_label.text = "Score %d   ·   streak %d (best %d)%s" % [info["score"], info["streak"], info["best_streak"], acc]


func _on_no_chords(reason: String) -> void:
	_set_big("—")
	_set_sub(reason)
	_set_notes("")
	_staff.clear()
	for c in _choices_box.get_children():
		c.queue_free()


func _on_held(held: Array) -> void:
	_keyboard.set_held(held)
	if held.is_empty():
		_keyboard.set_wrong([])


func _on_devices(names: PackedStringArray) -> void:
	# MIDI arriving over Wi-Fi from the laptop counts as a device.
	var wifi := []
	if Midi.net and Midi.net.receiving:
		for ip in Midi.net.senders:
			wifi.append(str(Midi.net.senders[ip].get("name", ip)))
	if names.is_empty() and not wifi.is_empty():
		_midi_label.text = "MIDI: Wi-Fi (%s)" % ", ".join(wifi)
		_midi_label.tooltip_text = "MIDI from another device over Wi-Fi"
		_midi_label.add_theme_color_override("font_color", UITheme.GOOD)
	elif names.is_empty():
		_midi_label.text = "MIDI: no device"
		_midi_label.add_theme_color_override("font_color", UITheme.WARN)
	else:
		var ch: int = Settings.get_value("midi_channel")
		var ch_text := "omni" if ch < 0 else "ch %d" % (ch + 1)
		_midi_label.text = ("MIDI: %s (%s)" % [names[0], ch_text]) if names.size() == 1 else ("MIDI: %d devices (%s)" % [names.size(), ch_text])
		if not wifi.is_empty():
			_midi_label.text += " + Wi-Fi"
		_midi_label.tooltip_text = "
".join(names)
		_midi_label.add_theme_color_override("font_color", UITheme.GOOD)


func _on_selection_changed(_sel: Array) -> void:
	_keyboard.set_wrong([])


func _submit_selection() -> void:
	var sel := _keyboard.selected.duplicate()
	session.submit(sel)


func _show_feedback(text: String, color: Color) -> void:
	_feedback.text = text
	_feedback.add_theme_color_override("font_color", color)
	if _feedback_tw and _feedback_tw.is_valid():
		_feedback_tw.kill()
	_feedback.modulate.a = 1.0


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	if Settings.get_value("qwerty_input") and Midi.QWERTY.has(event.physical_keycode):
		return
	match event.keycode:
		KEY_SPACE:
			if not session.paused:
				session.play_prompt_chord()
		KEY_ENTER, KEY_KP_ENTER:
			if _select_box.visible:
				_submit_selection()
		KEY_S:
			session.skip()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var i: int = event.keycode - KEY_1
			if _choices_box.visible and i < _choices_box.get_child_count():
				_choices_box.get_child(i).emit_signal("pressed")


# --- song mode ------------------------------------------------------------

func _wire_song() -> void:
	_song_select.clear()
	var current := str(Settings.get_value("song_id"))
	for i in _song.library.size():
		var sg: Song = _song.library[i]
		_song_select.add_item("%s  (%s)" % [sg.title, sg.artist], i)
		if sg.id == current:
			_song_select.select(i)
	_song_select.item_selected.connect(func(i):
		_set_paused(false)
		_song.stop()
		Settings.set_value("song_id", _song.library[i].id)
		_song_idle_view())
	%KeyDown.pressed.connect(func(): _shift_key(-1))
	%KeyUp.pressed.connect(func(): _shift_key(1))
	var spin: SpinBox = %BpmSpin
	spin.value_changed.connect(func(v):
		_song.stop()
		_set_bpm(roundi(v)))
	%BpmReset.pressed.connect(func():
		_song.stop()
		_set_bpm(0))
	%MetronomeCheck.button_pressed = bool(Settings.get_value("metronome_on"))
	%MetronomeCheck.toggled.connect(func(on): Settings.set_value("metronome_on", on))
	%BackingCheck.button_pressed = bool(Settings.get_value("song_backing"))
	%BackingCheck.toggled.connect(func(on): Settings.set_value("song_backing", on))
	%SongStart.pressed.connect(func():
		_set_paused(false)
		if _song.running:
			_song.stop()
		else:
			var sg := _current_song()
			_song.start(sg, _bpm_for(sg)))
	_song.started.connect(_on_song_started)
	_song.stopped.connect(func():
		%SongStart.text = "Start"
		_song_idle_view())
	_song.beat.connect(_on_song_beat)
	_song.target_changed.connect(_on_song_target)
	_song.landed.connect(_on_song_landed)
	_song.missed.connect(func(_i): _show_feedback("Miss", UITheme.BAD))
	_song.stopped.connect(func(): _set_paused(false))
	_song.finished.connect(_on_song_finished)


func _current_song() -> Song:
	var base := _song.song_by_id(str(Settings.get_value("song_id")))
	if base == null:
		return null
	return base.transposed(_transpose_for(base.id))


## The BPM to play `sg` at: the user's choice for this song, else its own.
func _bpm_for(sg: Song) -> float:
	var d: Dictionary = Settings.get_value("song_bpm")
	return float(d.get(sg.id, sg.bpm))


## 0 = back to the song's own tempo.
func _set_bpm(bpm: int) -> void:
	var sg := _current_song()
	if sg == null:
		return
	var d: Dictionary = (Settings.get_value("song_bpm") as Dictionary).duplicate()
	if bpm <= 0 or bpm == roundi(sg.bpm):
		d.erase(sg.id)
	else:
		d[sg.id] = bpm
	Settings.set_value("song_bpm", d)
	_song_idle_view()


func _transpose_for(id: String) -> int:
	var t: Dictionary = Settings.get_value("song_transpose")
	return int(t.get(id, 0))


## Moves the current song by a semitone, keeping it within ±6 of the
## original so it never drifts an octave away.
func _shift_key(step: int) -> void:
	_song.stop()
	var id := str(Settings.get_value("song_id"))
	var t: Dictionary = (Settings.get_value("song_transpose") as Dictionary).duplicate()
	var n := int(t.get(id, 0)) + step
	if n > 6:
		n -= 12
	elif n < -6:
		n += 12
	t[id] = n
	Settings.set_value("song_transpose", t)
	_song_idle_view()


func _update_key_label(sg: Song) -> void:
	var sig := sg.key_signature()
	var sig_text := "no ♯/♭" if sig == 0 else "%d%s" % [absi(sig), "♯" if sig > 0 else "♭"]
	var shift := "" if sg.transpose == 0 else "  (%+d)" % sg.transpose
	%KeyLabel.text = "Key: %s · %s%s" % [sg.key_name(), sig_text, shift]


func _song_idle_view() -> void:
	if _song == null or _song.running:
		return
	var sg := _current_song()
	if sg == null:
		_set_big("—")
		_set_sub("No songs found in data/songs.json")
		return
	_set_big(sg.title, 48)
	_set_below("")
	# Keep the song bar in sync if settings changed elsewhere.
	for i in _song.library.size():
		if _song.library[i].id == sg.id:
			_song_select.select(i)
	var bpm_now := roundi(_bpm_for(sg))
	%BpmSpin.set_value_no_signal(bpm_now)
	%BpmReset.disabled = bpm_now == roundi(sg.bpm)
	%MetronomeCheck.set_pressed_no_signal(bool(Settings.get_value("metronome_on")))
	%BackingCheck.set_pressed_no_signal(bool(Settings.get_value("song_backing")))
	var bpm := bpm_now
	var bpm_note := "%d bpm" % bpm if bpm == roundi(sg.bpm) else "%d bpm (original %d)" % [bpm, roundi(sg.bpm)]
	_set_sub("%s · %d · %s · %d bars · %s\nPress Start, then play each chord on the beat where it changes." % [sg.artist, sg.year, sg.key_name(), sg.bars(), bpm_note])
	_set_notes("")
	_staff.chord_label = ""
	_update_key_label(sg)
	_staff.accidental_mode = "key_signature"
	_staff.show_chord([], sg.key_signature())
	_keyboard.set_hints([])


func _on_song_started(sg: Song) -> void:
	%SongStart.text = "Stop"
	_update_key_label(sg)
	_set_big("")
	_set_sub("Get ready…")
	_show_feedback(" ", UITheme.TEXT)


func _on_song_beat(in_bar: int, bpb: int, count_in: bool) -> void:
	_beats.set_beat(in_bar, bpb, count_in)
	if count_in:
		_set_big(str(bpb - in_bar), 72)
	elif _chord_label.text.is_valid_int():
		_set_big("")


func _on_song_target(i: int) -> void:
	if i < 0:
		return
	var targets: Array = _song.engine.targets
	var tg: Dictionary = targets[i]
	var chord: Theory.Chord = tg["chord"]
	_set_big("" if _staff.visible else chord.pretty())
	_set_sub("")
	var next: String = "Next: " + (targets[i + 1]["chord"].pretty() if i + 1 < targets.size() else "end")
	_set_below("%s   ·   %s   ·   %d / %d" % [next, tg["section"], i + 1, targets.size()])
	var rm := ChordPrompt.place_root(chord, 0, int(Settings.get_value("range_low")), int(Settings.get_value("range_high")))
	if rm < 0:
		rm = ChordPrompt.midi_for(chord.root, 4)
	var voiced := chord.voiced_tones(rm, 0)
	_staff.accidental_mode = "key_signature"
	_staff.chord_label = chord.pretty() if Settings.get_value("show_chord_name") else ""
	_staff.show_chord(voiced, _song.engine.song.key_signature())
	if Settings.get_value("show_notes"):
		var parts := []
		for pair in voiced:
			parts.append(pair[1].pretty())
		_set_notes("  –  ".join(parts))
	else:
		_set_notes("")
	_keyboard.set_hints(chord.voicing(rm, 0) if Settings.get_value("show_keyboard_hint") else [])


func _on_song_landed(_i: int, grade: SongEngine.Grade, offset: float) -> void:
	var ms := roundi(offset * 1000.0)
	var when := "on time" if absi(ms) <= 10 else ("%d ms %s" % [absi(ms), "early" if ms < 0 else "late"])
	var col := UITheme.GOOD if grade in [SongEngine.Grade.PERFECT, SongEngine.Grade.GREAT] else UITheme.WARN
	_show_feedback("%s  ·  %s" % [SongEngine.grade_name(grade), when], col)


func _on_song_finished(r: Dictionary) -> void:
	_set_paused(false)
	%SongStart.text = "Start"
	_keyboard.set_hints([])
	_staff.show_chord([], _song.engine.song.key_signature())
	var c: Dictionary = r["counts"]
	_staff.chord_label = ""
	_set_notes("")
	_set_below("")
	_set_big("Rank " + str(r["rank"]), 72)
	var lean := ""
	if r["hits"] > 0:
		if absf(r["avg_ms"]) > 15.0:
			lean = " (you tend to be %d ms %s)" % [absi(roundi(r["avg_ms"])), "early" if r["avg_ms"] < 0 else "late"]
		else:
			lean = " (nicely centred on the beat)"
	_set_sub("%d%%  ·  Perfect %d · Great %d · Good %d · OK %d · Miss %d\nAverage timing error %d ms%s" % [
		roundi(r["percent"]), c[SongEngine.Grade.PERFECT], c[SongEngine.Grade.GREAT], c[SongEngine.Grade.GOOD],
		c[SongEngine.Grade.OK], c[SongEngine.Grade.MISS], roundi(r["avg_abs_ms"]), lean])
	_show_feedback("Song complete — press Start to play again", UITheme.ACCENT)
	var sg := _current_song()
	session.stats.record("song:" + sg.id, "song", r["percent"] >= 70.0, roundi(r["avg_abs_ms"]),
		{"percent": r["percent"], "rank": r["rank"]})
	session.stats.save()


# --- Chord Defense ----------------------------------------------------------

func _wire_defense() -> void:
	var g := _defense.game
	g.stats = session.stats
	g.hint_changed.connect(func(v: Array): _keyboard.set_hints(v))
	g.feedback.connect(func(t: String, c: Color): _show_feedback(t, c))
	g.hud_changed.connect(func(i: Dictionary):
		%DefenseStart.text = "Stop" if i["running"] else "Start")
	g.game_over.connect(func(_s): _set_paused(false))
	%DefenseStart.pressed.connect(func():
		if g.is_running():
			_stop_defense()
		else:
			_set_paused(false)
			g.use_pool = bool(Settings.get_value("defense_use_pool"))
			g.configure(int(Settings.get_value("range_low")), int(Settings.get_value("range_high")))
			_show_feedback(" ", UITheme.TEXT)
			_defense.start())
	%DefensePool.toggled.connect(func(on): Settings.set_value("defense_use_pool", on))


func _stop_defense() -> void:
	if _defense.game.is_running():
		_defense.stop()
	_set_paused(false)
	_keyboard.set_hints([])
