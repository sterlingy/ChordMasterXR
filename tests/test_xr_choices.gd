extends GutTest
## Floating "Name it" buttons (XR): layout and fingertip presses.


func _make(n := 4) -> XRChoiceButtons:
	var cb := XRChoiceButtons.new()
	var head := Node3D.new()
	add_child_autofree(head)
	head.position = Vector3(0, 1.5, 0)
	cb.camera = head
	add_child_autofree(cb)
	var chords := []
	for q in ["maj", "min", "7", "maj7", "dim"].slice(0, n):
		chords.append(Theory.make_chord("C", q))
	cb.show_choices(chords)
	return cb


func test_buttons_sit_within_reach_and_face_the_eyes() -> void:
	var cb := _make(4)
	assert_eq(cb.buttons.size(), 4)
	var head := Vector3(0, 1.5, 0)
	for b in cb.buttons:
		var flat := Vector2(b.global_position.x - head.x, b.global_position.z - head.z).length()
		assert_almost_eq(flat, XRChoiceButtons.REACH, 0.001, "within arm's reach")
		assert_lt(b.global_position.y, head.y, "below eye level")
		var to_eye := (head - b.global_position).normalized()
		assert_almost_eq(b.global_basis.z.normalized().dot(to_eye), 1.0, 0.001, "faces the eyes")
		assert_almost_eq(b.global_basis.x.normalized().dot(Vector3.RIGHT), 1.0, 0.1, "no roll")


func test_fingertip_press_from_the_front() -> void:
	var cb := _make(3)
	var b: XRChoiceButton = cb.buttons[1]
	b._set_fade(1.0)
	watch_signals(b)
	for z in [0.03, 0.015, 0.0, -0.01]:
		cb.poke("right", b.to_global(Vector3(0, 0, z)))
	assert_signal_emit_count(b, "activated", 1, "one press per push")
	# Staying pushed in doesn't repeat; pulling back out re-arms.
	cb.poke("right", b.to_global(Vector3(0, 0, -0.02)))
	assert_signal_emit_count(b, "activated", 1)
	for z in [0.03, 0.0]:
		cb.poke("right", b.to_global(Vector3(0, 0, z)))
	assert_signal_emit_count(b, "activated", 2)


func test_fingertip_from_behind_does_not_press() -> void:
	var cb := _make(3)
	var b: XRChoiceButton = cb.buttons[0]
	b._set_fade(1.0)
	watch_signals(b)
	for z in [-0.04, -0.02, 0.0, 0.01]:
		cb.poke("left", b.to_global(Vector3(0, 0, z)))
	assert_signal_not_emitted(b, "activated")


func test_hover_follows_the_fingertip() -> void:
	var cb := _make(2)
	var b: XRChoiceButton = cb.buttons[0]
	cb.poke("left", b.to_global(Vector3(0, 0, 0.02)))
	assert_true(b.hovered)
	cb.poke("left", null)
	assert_false(b.hovered)


func test_knob_moves_the_row_and_remembers_it() -> void:
	var keep = Settings.get_value("xr_choices_offset")
	Settings.set_value("xr_choices_offset", [0.0, 0.0, 0.0])
	var cb := _make(4)
	var before: Array = cb.buttons.map(func(b): return b.global_position)
	var k := cb.knob_position()
	assert_eq(cb.handle_near(k, 0.01), "choices", "knob grabbable")
	cb.begin_handle(7, "choices", k)
	cb.update_handle(7, k + Vector3(0.1, 0.05, 0.0))
	cb.end_handle(7)
	for i in cb.buttons.size():
		var d: Vector3 = cb.buttons[i].global_position - before[i]
		assert_almost_eq(d.x, 0.1, 0.001, "moved right")
		assert_almost_eq(d.y, 0.05, 0.001, "moved up")
	var off := XRChoiceButtons.saved_offset()
	assert_almost_eq(off.x, 0.1, 0.001)
	assert_almost_eq(off.y, 0.05, 0.001)
	# The next question appears where the row was left.
	cb.show_choices([Theory.make_chord("D", "min"), Theory.make_chord("G", "maj")])
	var fresh := _make(2)
	Settings.set_value("xr_choices_offset", [0.0, 0.0, 0.0])
	var plain := _make(2)
	assert_almost_eq(fresh.buttons[0].global_position.x - plain.buttons[0].global_position.x, 0.1, 0.001)
	Settings.set_value("xr_choices_offset", keep)


func test_buttons_are_bigger_and_further_apart() -> void:
	assert_almost_eq(XRChoiceButton.SIZE.x, 0.11 * 1.15, 0.0001)
	assert_almost_eq(XRChoiceButtons.GAP, 0.022 * 1.15 * 1.1, 0.0001)


func test_reset_puts_the_row_back() -> void:
	var keep = Settings.get_value("xr_choices_offset")
	Settings.set_value("xr_choices_offset", [0.0, 0.0, 0.0])
	var plain := _make(3)
	var home: Array = plain.buttons.map(func(b): return b.global_position)
	var k := plain.knob_position()
	plain.begin_handle(3, "choices", k)
	plain.update_handle(3, k + Vector3(-0.2, 0.1, 0.05))
	plain.end_handle(3)
	assert_gt(plain.buttons[0].global_position.distance_to(home[0]), 0.1, "moved")
	plain.reset_position()
	for i in plain.buttons.size():
		assert_almost_eq(plain.buttons[i].global_position.distance_to(home[i]), 0.0, 0.001, "back home")
	assert_eq(XRChoiceButtons.saved_offset(), Vector3.ZERO)
	Settings.set_value("xr_choices_offset", keep)
