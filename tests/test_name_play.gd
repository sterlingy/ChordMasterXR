extends GutTest
## "Name it": answering by playing the chord on the keyboard.


func _session(answer: String, others: Array) -> PracticeSession:
	var s := PracticeSession.new()
	s.stats.save_path = "user://test_name_play_stats.json"
	add_child_autofree(s)
	var p := ChordPrompt.new()
	p.chord = Theory.parse_chord(answer)
	s.prompt = p
	s.choices = [p.chord]
	for o in others:
		s.choices.append(Theory.parse_chord(o))
	s.state = PracticeSession.State.WAITING
	return s


func test_playing_the_answer_in_any_inversion_is_correct() -> void:
	var s := _session("C", ["Am", "F"])
	watch_signals(s)
	s._judge_played_choice([64, 67])          # still building: nothing yet
	assert_signal_not_emitted(s, "choice_feedback")
	s._judge_played_choice([64, 67, 72, 76])  # E G C E: C major, 1st inversion, doubled
	assert_signal_emitted_with_parameters(s, "choice_feedback", [s.prompt.chord, true])


func test_playing_another_choice_picks_it_as_wrong() -> void:
	var s := _session("C", ["Am", "F"])
	watch_signals(s)
	s._judge_played_choice([53, 57, 60])      # F A C
	assert_signal_emit_count(s, "choice_feedback", 1)
	var params: Array = get_signal_parameters(s, "choice_feedback")
	assert_eq(params[0].symbol(), "F")
	assert_false(params[1])
	# Holding on doesn't count again; release first.
	s._judge_played_choice([53, 57, 60, 65])
	assert_signal_emit_count(s, "choice_feedback", 1)
	s._judge_played_choice([])
	s._judge_played_choice([48, 52, 55])      # now C E G
	assert_signal_emit_count(s, "choice_feedback", 2)


func test_a_chord_that_is_not_a_choice_gives_a_hint_only() -> void:
	var s := _session("C", ["Am", "F"])
	watch_signals(s)
	s._judge_played_choice([62, 66, 69])      # D major
	assert_signal_emitted(s, "played_unknown_choice")
	assert_signal_not_emitted(s, "choice_feedback")
	assert_eq(s.attempt_count, 0, "no penalty")
