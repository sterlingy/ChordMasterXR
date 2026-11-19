class_name PracticeSession
extends Node
## Runs a practice session: asks for a chord, listens for the answer,
## records stats and moves on. UI-agnostic — the 2D screen and the XR scene
## both drive and observe the same session.
##
## Practice modes:
##   play  – play the chord. Input comes from the MIDI keyboard (live), or
##           with input_mode "select" from the on-screen keyboard
##           (select notes, then submit()).
##   name  – the chord is shown on the staff; pick its name from cards
##           (answer_choice()), or play it on the keyboard: playing one of
##           the choices (any inversion/octave) picks that card.

signal prompt_changed(prompt: ChordPrompt, choices: Array)
signal feedback(result: ChordMatcher.Result, wrong_notes: Array)
signal choice_feedback(chord: Theory.Chord, correct: bool)
signal score_changed(info: Dictionary)
signal no_chords(reason: String)
signal paused_changed(paused: bool)
## Name it: a chord was played that isn't any of the choices (no penalty).
signal played_unknown_choice()

enum State { IDLE, WAITING, NEED_RELEASE, RETRY_AFTER_RELEASE, ADVANCING }

var engine := ExerciseEngine.new()
var stats := PracticeStats.new()
var prompt: ChordPrompt
var choices: Array = []
var state := State.IDLE
var _name_need_release := false     # name it: a played chord was judged; let go first

var streak := 0
var best_streak := 0
var correct_count := 0
var attempt_count := 0
var score := 0
var session_start := 0.0

var _prompt_t := 0
var _failed_this_prompt := false
var _chord_played_ms := -100000     # when the prompt chord last started sounding
var _cue_id := 0                     # bumps on each new prompt; stale cues give up

## Paused: the keyboard still sounds, but nothing is judged or recorded and
## the session doesn't move on until resumed.
var paused := false
var _paused_at := 0

## Spoken names wait this long after a chord starts, so sound and voice
## never overlap (Name It, where the name comes after the answer).
const SAY_AFTER_CHORD_S := 1.2
## When both Say and Hear are on, the chord plays this long after the name
## finishes being spoken.
const CHORD_AFTER_SAY_S := 0.15


func _ready() -> void:
	if Settings.is_dev_run():
		stats.save_path = "user://dev_stats.json"
	else:
		stats.load_from_disk()
	Midi.held_changed.connect(_on_held_changed)
	Midi.note_on.connect(_on_note_on)
	Midi.note_off.connect(_on_note_off)


func _exit_tree() -> void:
	stats.save()


func practice_mode() -> String:
	return Settings.get_value("practice_mode")


func uses_live_midi() -> bool:
	return practice_mode() == "play" and Settings.get_value("input_mode") == "midi"


func start() -> void:
	if practice_mode() in ["song", "defense"]:
		# Song mode is driven by SongSession and Chord Defense by its game;
		# this session sits idle.
		state = State.IDLE
		prompt = null
		return
	engine.configure(Settings.get_value("exercise_type"), Settings.pool(), stats)
	Settings.apply_to_engine(engine)
	streak = 0
	correct_count = 0
	attempt_count = 0
	score = 0
	session_start = Time.get_unix_time_from_system()
	Synth.prewarm(engine.range_low, engine.range_high)
	_emit_score()
	next()


func next() -> void:
	prompt = engine.next_prompt()
	choices = []
	_failed_this_prompt = false
	if prompt == null:
		state = State.IDLE
		var reason := "No chords in the pool fit your keyboard range."
		if engine.pool.size() == 0:
			reason = "The chord pool is empty — pick some chords."
		no_chords.emit(reason)
		return
	if practice_mode() == "name":
		choices = engine.choices_for(prompt.chord, int(Settings.get_value("name_choices")))
	state = State.WAITING
	if uses_live_midi() and not Midi.held.is_empty():
		state = State.NEED_RELEASE
	_prompt_t = Time.get_ticks_msec()
	prompt_changed.emit(prompt, choices)
	_cue_prompt()


## New-chord cues: say the name first (if Say is on), then play the chord
## once the voice has finished (if Hear is on).
func _cue_prompt() -> void:
	_cue_id += 1
	var id := _cue_id
	var say: bool = Settings.get_value("voice_callout") and practice_mode() == "play" and Voice.available()
	var hear: bool = Settings.get_value("play_on_prompt")
	if say:
		Voice.say_prompt(prompt)
		if hear:
			await _wait_for_voice()
			if id != _cue_id:
				return
	if hear:
		play_prompt_chord()


## Waits until the voice has finished (max ~3 s, in case the platform
## can't tell), plus a short breath.
func _wait_for_voice() -> void:
	# TTS takes a moment to start; don't read "not speaking" too early.
	await get_tree().create_timer(0.35).timeout
	var t := 0.35
	while t < 3.0 and DisplayServer.tts_is_speaking():
		await get_tree().create_timer(0.05).timeout
		t += 0.05
	await get_tree().create_timer(CHORD_AFTER_SAY_S).timeout


func set_paused(on: bool) -> void:
	if on == paused:
		return
	paused = on
	if on:
		_paused_at = Time.get_ticks_msec()
	else:
		# The pause doesn't count toward the response time.
		_prompt_t += Time.get_ticks_msec() - _paused_at
		# Whatever is still held from free play isn't an answer.
		if uses_live_midi() and state == State.WAITING and not Midi.held.is_empty():
			state = State.NEED_RELEASE
	paused_changed.emit(on)


func skip() -> void:
	if paused:
		return
	if prompt != null and state in [State.WAITING, State.NEED_RELEASE, State.RETRY_AFTER_RELEASE]:
		_record(false, {"skipped": true})
		streak = 0
		_emit_score()
	next()


func play_prompt_chord() -> void:
	if prompt != null:
		_chord_played_ms = Time.get_ticks_msec()
		Synth.play_chord(prompt.voicing(), 1.6, 0.0)


## Speaks the chord name, waiting until a chord that just started playing
## has mostly rung out so the two never overlap. `only_if_current`: skip it
## if the prompt has moved on meanwhile.
func _say_after_chord(p: ChordPrompt, only_if_current: bool) -> void:
	var wait := SAY_AFTER_CHORD_S - (Time.get_ticks_msec() - _chord_played_ms) / 1000.0
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout
		if only_if_current and prompt != p:
			return
	Voice.say_prompt(p)


# --- play mode: live MIDI ---------------------------------------------

func _on_note_on(pitch: int, velocity: int) -> void:
	if Settings.get_value("echo_input"):
		Synth.note_on(pitch, velocity)


func _on_note_off(pitch: int) -> void:
	if Settings.get_value("echo_input"):
		Synth.note_off(pitch)


func _on_held_changed(held: Array) -> void:
	if practice_mode() == "name":
		_judge_played_choice(held)
		return
	if not uses_live_midi() or prompt == null:
		return
	if paused:
		if state == State.WAITING and not held.is_empty():
			state = State.NEED_RELEASE
		return
	match state:
		State.NEED_RELEASE:
			if held.is_empty():
				state = State.WAITING
			return
		State.RETRY_AFTER_RELEASE:
			if held.is_empty():
				state = State.WAITING
			return
		State.WAITING:
			pass
		_:
			return
	var m := prompt.matcher()
	var r := m.evaluate_live(held)
	if r == ChordMatcher.Result.PENDING:
		return
	_handle_result(r, m.wrong_notes(held), held)


# --- play mode: select & submit ---------------------------------------

func submit(selected: Array) -> ChordMatcher.Result:
	if paused or prompt == null or state != State.WAITING:
		return ChordMatcher.Result.PENDING
	var m := prompt.matcher()
	var r := m.evaluate_submit(selected)
	_handle_result(r, m.wrong_notes(selected), selected)
	return r


# --- name mode --------------------------------------------------------

## Name it by playing: once the held notes are exactly one choice's notes
## (any inversion, octave or doubling), that choice is answered. A full
## chord that matches none of them gets a hint, no penalty. Keys must be
## released before the next chord is judged.
func _judge_played_choice(held: Array) -> void:
	if held.is_empty():
		_name_need_release = false
		return
	if _name_need_release or paused or prompt == null or state != State.WAITING:
		return
	var hs := {}
	for m in held:
		hs[posmod(int(m), 12)] = true
	var building := false
	for c in choices:
		var pcs: Array = c.pitch_classes()
		var inside := true
		for pc in hs:
			if not pcs.has(pc):
				inside = false
				break
		if not inside:
			continue
		if hs.size() == pcs.size():
			_name_need_release = true
			answer_choice(c)
			return
		building = true
	if not building and hs.size() >= 3:
		_name_need_release = true
		played_unknown_choice.emit()

func answer_choice(c: Theory.Chord) -> bool:
	if paused or prompt == null or state != State.WAITING:
		return false
	var ok := c.equals(prompt.chord)
	choice_feedback.emit(c, ok)
	if ok:
		_on_correct({"picked": c.key()})
		if Settings.get_value("voice_callout"):
			_say_after_chord(prompt, false)
	else:
		_on_fail({"picked": c.key()})
	return ok


# --- shared -----------------------------------------------------------

func _handle_result(r: ChordMatcher.Result, wrong: Array, notes: Array) -> void:
	feedback.emit(r, wrong)
	var extra := {"notes": notes.duplicate(), "result": ChordMatcher.Result.keys()[r]}
	if r == ChordMatcher.Result.CORRECT:
		_on_correct(extra)
	elif ChordMatcher.is_fail(r):
		_on_fail(extra)
		if uses_live_midi():
			state = State.RETRY_AFTER_RELEASE


func _on_correct(extra: Dictionary) -> void:
	var ms := Time.get_ticks_msec() - _prompt_t
	_record(true, extra)
	correct_count += 1
	if not _failed_this_prompt:
		streak += 1
		best_streak = maxi(best_streak, streak)
		# Points: base + speed bonus (under 5 s) + streak bonus.
		score += 10 + int(clampf((5000.0 - ms) / 500.0, 0.0, 10.0)) + mini(streak, 10)
	else:
		score += 3
	_emit_score()
	state = State.ADVANCING
	if Settings.get_value("play_on_correct") and not (uses_live_midi() and Settings.get_value("echo_input")):
		play_prompt_chord()
	await get_tree().create_timer(float(Settings.get_value("advance_delay"))).timeout
	# Play mode: the next chord waits until the keys of this one are let go.
	while state == State.ADVANCING and (paused or (uses_live_midi() and not Midi.held.is_empty())):
		await get_tree().process_frame
	if state == State.ADVANCING:
		next()


func _on_fail(extra: Dictionary) -> void:
	if not _failed_this_prompt:
		_record(false, extra)
	_failed_this_prompt = true
	streak = 0
	_emit_score()


func _record(ok: bool, extra: Dictionary) -> void:
	attempt_count += 1
	var ms := Time.get_ticks_msec() - _prompt_t
	var e := extra.duplicate()
	e["inv"] = prompt.inversion
	e["strict"] = prompt.strict_inversion
	e["exercise"] = engine.type
	stats.record(prompt.chord.key(), practice_mode(), ok, ms, e)
	if attempt_count % 5 == 0:
		stats.save()


func _emit_score() -> void:
	score_changed.emit({
		"score": score, "streak": streak, "best_streak": best_streak,
		"correct": correct_count, "attempts": attempt_count,
	})
