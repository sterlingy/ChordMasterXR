extends GutTest


func _layout() -> KeyboardLayout:
	# A 37-key board (C3..C6 = 22 white keys, 21 gaps), white keys 23.5 mm,
	# lying along +X at table height, player standing at +Z.
	var l := KeyboardLayout.new()
	l.low = 48
	l.high = 84
	l.p_low = Vector3(0, 0.80, 0)
	l.p_high = Vector3(0.0235 * 21, 0.80, 0)
	l.viewer = Vector3(0.25, 1.6, 0.6)
	return l


func test_key_index() -> void:
	assert_eq(KeyboardLayout.key_index(60), 35.0)        # C4
	assert_eq(KeyboardLayout.key_index(61), 35.5)        # C#4 between C4 and D4
	assert_eq(KeyboardLayout.key_index(62), 36.0)        # D4
	assert_eq(KeyboardLayout.key_index(66), 38.5)        # F#4 between F4 and G4
	assert_eq(KeyboardLayout.key_index(72) - KeyboardLayout.key_index(60), 7.0)


func test_white_width_from_touches() -> void:
	assert_almost_eq(_layout().white_width(), 0.0235, 0.0001)


func test_key_count_and_kinds() -> void:
	var keys := _layout().keys()
	assert_eq(keys.size(), 37)
	var whites := keys.filter(func(k): return k["white"]).size()
	assert_eq(whites, 22)


func test_keys_lie_along_line_and_away_from_player() -> void:
	var l := _layout()
	var by := {}
	for k in l.keys():
		by[k["midi"]] = k
	# C4 is 7 white keys up from C3.
	assert_almost_eq(by[60]["center"].x, 0.0235 * 7, 0.0005)
	# White keys extend BACK from the touch (away from the player at +Z).
	assert_lt(by[60]["center"].z, 0.0)
	# C#4 sits halfway between C4 and D4, further back and raised.
	assert_almost_eq(by[61]["center"].x, (by[60]["center"].x + by[62]["center"].x) / 2.0, 0.0005)
	assert_lt(by[61]["center"].z, by[60]["center"].z)
	assert_gt(by[61]["center"].y, by[60]["center"].y)
	# Overlay sits just under the fingertip pad, on the key top.
	assert_almost_eq(by[60]["center"].y, 0.80 - KeyboardLayout.PAD, 0.0005)


func test_player_on_other_side_flips_back() -> void:
	var l := _layout()
	l.viewer = Vector3(0.25, 1.6, -0.6)
	var c4: Dictionary = l.keys().filter(func(k): return k["midi"] == 60)[0]
	assert_gt(c4["center"].z, 0.0)


func test_lift_nudge() -> void:
	var l := _layout()
	l.lift = 0.005
	var c4: Dictionary = l.keys().filter(func(k): return k["midi"] == 60)[0]
	assert_almost_eq(c4["center"].y, 0.80 - KeyboardLayout.PAD + 0.005, 0.0005)


func test_invalid_when_points_too_close() -> void:
	var l := _layout()
	l.p_high = l.p_low + Vector3(0.05, 0, 0)
	assert_false(l.valid())
	assert_eq(l.keys().size(), 0)


func test_translate_moves_both_ends() -> void:
	var l := _layout()
	var a := l.p_low
	l.translate(Vector3(0.01, 0.002, -0.003))
	assert_almost_eq(l.p_low.distance_to(a + Vector3(0.01, 0.002, -0.003)), 0.0, 0.00001)
	assert_almost_eq(l.white_width(), 0.0235, 0.0001)


func test_turn_keeps_width_and_middle() -> void:
	var l := _layout()
	var m := l.mid()
	l.turn(deg_to_rad(10.0))
	assert_almost_eq(l.white_width(), 0.0235, 0.0001)
	assert_almost_eq(l.mid().distance_to(m), 0.0, 0.00001)
	# + turn sends the high (right) end away from the player (-Z here).
	assert_lt(l.p_high.z, m.z)
	assert_almost_eq(l.p_high.y, 0.80, 0.00001)


func test_level_raises_low_end_keeps_length() -> void:
	var l := _layout()
	var length := l.p_low.distance_to(l.p_high)
	l.level(0.004)
	assert_gt(l.p_low.y, 0.80)
	assert_lt(l.p_high.y, 0.80)
	assert_almost_eq(l.p_low.distance_to(l.p_high), length, 0.00001)


func test_widen_changes_key_width() -> void:
	var l := _layout()
	l.widen(0.021)
	assert_almost_eq(l.white_width(), 0.0245, 0.0001)


func test_tilt_raises_back_of_keys() -> void:
	var l := _layout()
	var flat: Dictionary = l.keys().filter(func(k): return k["midi"] == 60)[0]
	l.tilt = deg_to_rad(10.0)
	var tilted: Dictionary = l.keys().filter(func(k): return k["midi"] == 60)[0]
	# Key centre is behind the touch line, so raising the back lifts it.
	assert_gt(tilted["center"].y, flat["center"].y)
	var ax := l.axes()
	assert_almost_eq(ax[1].dot(ax[2]), 0.0, 0.00001)
