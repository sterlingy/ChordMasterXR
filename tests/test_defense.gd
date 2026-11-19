extends GutTest
## Chord Defense rules, level design and records.


func _c(sym: String) -> Theory.Chord:
	return Theory.parse_chord(sym)


func _t(id: int, sym: String, octave: int, progress := 0.5) -> Dictionary:
	return {"id": id, "chord": _c(sym), "octave": octave, "progress": progress}


# --- stations -------------------------------------------------------------

func test_octave_numbers_follow_middle_c() -> void:
	assert_eq(DefenseRules.octave_of(60), 4)
	assert_eq(DefenseRules.octave_of(71), 4)
	assert_eq(DefenseRules.octave_of(72), 5)
	assert_eq(DefenseRules.octave_low(4), 60)


func test_stations_are_full_octaves_in_range() -> void:
	# 61 keys, C2..C7: full octaves 2..6.
	assert_eq(DefenseRules.station_octaves(36, 96), [2, 3, 4, 5, 6] as Array[int])
	# 37 keys starting at F: only the full octaves inside.
	assert_eq(DefenseRules.station_octaves(53, 89), [4, 5] as Array[int])


func test_88_keys_capped_at_eight_stations() -> void:
	var o := DefenseRules.station_octaves(21, 108)
	assert_true(o.size() <= DefenseRules.MAX_STATIONS)
	assert_true(o.has(4), "keeps middle C's octave")


func test_voicing_starts_in_station_octave() -> void:
	var v := DefenseRules.voicing_in_octave(_c("G7"), 3, 96)
	assert_false(v.is_empty())
	assert_eq(DefenseRules.octave_of(v[0]), 3)


func test_voicing_respects_top_of_keyboard() -> void:
	# B major from octave 6 would go above C7 in root position; an inversion
	# or nothing must be returned, never notes above `high`.
	var v := DefenseRules.voicing_in_octave(_c("B"), 6, 96)
	for m in v:
		assert_true(m <= 96)


# --- judging --------------------------------------------------------------

func test_kill_needs_bass_in_station_octave() -> void:
	var targets := [_t(1, "C", 4)]
	assert_eq(DefenseRules.judge([60, 64, 67], targets)["kind"], "kill")
	assert_eq(DefenseRules.judge([48, 52, 55], targets)["kind"], "wrong_octave")


func test_any_inversion_and_spread_counts() -> void:
	var targets := [_t(1, "C", 4)]
	assert_eq(DefenseRules.judge([64, 67, 72], targets)["kind"], "kill")   # 1st inversion, E4 bass
	assert_eq(DefenseRules.judge([60, 67, 76], targets)["kind"], "kill")   # open voicing


func test_closest_attacker_wins() -> void:
	# A4 C5 E5: lowest note A4 is in octave 4.
	var r := DefenseRules.judge([69, 72, 76], [_t(1, "Am", 4, 0.2), _t(2, "Am", 4, 0.8), _t(3, "Am", 5, 0.95)])
	assert_eq(r["kind"], "kill")
	assert_eq(r["id"], 2, "the nearer of the two attacking octave 4")


func test_building_a_chord_is_pending() -> void:
	var targets := [_t(1, "Cmaj7", 4)]
	assert_eq(DefenseRules.judge([60, 64, 67], targets)["kind"], "pending")


func test_wrong_three_notes_is_misfire() -> void:
	assert_eq(DefenseRules.judge([60, 61, 62], [_t(1, "C", 4)])["kind"], "misfire")


func test_two_wrong_notes_is_not_yet_a_misfire() -> void:
	assert_eq(DefenseRules.judge([60, 61], [_t(1, "C", 4)])["kind"], "pending")


func test_extra_note_is_not_the_chord() -> void:
	assert_false(DefenseRules.plays_chord([60, 64, 67, 70], _c("C")))
	assert_true(DefenseRules.plays_chord([60, 64, 67, 70], _c("C7")))


# --- scoring --------------------------------------------------------------

func test_combo_grows_and_caps() -> void:
	assert_eq(DefenseRules.combo_multiplier(0), 1)
	assert_eq(DefenseRules.combo_multiplier(4), 2)
	assert_eq(DefenseRules.combo_multiplier(400), DefenseRules.COMBO_MAX)


func test_early_kills_score_more() -> void:
	var c := _c("C")
	assert_gt(DefenseRules.kill_points(c, 0.1, 0), DefenseRules.kill_points(c, 0.9, 0))
	assert_gt(DefenseRules.kill_points(_c("C7"), 0.5, 0), DefenseRules.kill_points(c, 0.5, 0))


# --- level design ---------------------------------------------------------

func test_waves_get_harder() -> void:
	var a := DefenseWaves.plan(1)
	var b := DefenseWaves.plan(4)
	assert_gt(b["count"], a["count"])
	assert_lt(b["interval"], a["interval"])
	assert_lt(b["travel"], a["travel"])


func test_sectors_bring_new_chords() -> void:
	assert_eq(DefenseWaves.plan(1)["sector"], "Triad Nebula")
	assert_true((DefenseWaves.plan(9)["qualities"] as Array).has("m7"))
	assert_false((DefenseWaves.plan(1)["qualities"] as Array).has("m7"))


func test_boss_every_fifth_wave() -> void:
	assert_false(DefenseWaves.plan(4)["boss"])
	assert_true(DefenseWaves.plan(5)["boss"])
	assert_true(DefenseWaves.plan(10)["boss"])


func test_all_sector_qualities_exist() -> void:
	for sec in DefenseWaves.SECTORS:
		for q in sec["qualities"]:
			assert_true(Theory.QUALITIES.has(q), q)


func test_progression_chords_in_key() -> void:
	var cs := DefenseWaves.progression_chords(DefenseWaves.PROGRESSIONS[0], Theory.parse_note("C"))
	assert_eq(cs.map(func(c): return c.pretty()), ["Dm7", "G7", "Cmaj7"])


# --- records --------------------------------------------------------------

func test_leaderboard_keeps_top_scores_in_order() -> void:
	var r := DefenseRecords.new()
	r.save_path = "user://test_defense_records.json"
	for s in [500, 3000, 1200]:
		r.add_game(5, {"score": s, "wave": 2, "kills": 3, "accuracy": 0.8, "best_combo": 4})
	var top := r.top(5)
	assert_eq(top.map(func(e): return int(e["score"])), [3000, 1200, 500])
	assert_eq(r.rank_for(5, 2000), 2)
	assert_eq(r.top(7), [], "boards are per keyboard size")


func test_leaderboard_trims_to_top_n() -> void:
	var r := DefenseRecords.new()
	for i in DefenseRecords.TOP_N + 5:
		r.add_game(5, {"score": i * 10, "wave": 1, "kills": 1, "accuracy": 1.0, "best_combo": 1})
	assert_eq(r.top(5).size(), DefenseRecords.TOP_N)
	assert_eq(r.rank_for(5, 0), 0)


func test_records_round_trip() -> void:
	var r := DefenseRecords.new()
	r.save_path = "user://test_defense_records.json"
	r.add_game(5, {"score": 900, "wave": 3, "kills": 9, "accuracy": 0.9, "best_combo": 6})
	r.record_kill("C:maj", 2000)
	r.record_escape("F#:min")
	r.save()
	var r2 := DefenseRecords.new()
	r2.save_path = r.save_path
	r2.load_from_disk()
	assert_eq(int(r2.top(5)[0]["score"]), 900)
	assert_eq(int(r2.lifetime["games"]), 1)
	assert_eq(r2.nemesis_chords(1), ["F#:min"])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(r.save_path))


# --- AR placement ---------------------------------------------------------

func test_ar_frame_puts_stations_over_their_octaves() -> void:
	var lay := KeyboardLayout.new()
	lay.low = 36
	lay.high = 96
	lay.viewer = Vector3(0, 1.5, 0.6)
	# Fingertip points on the lowest and highest keys, 61 keys ≈ 0.84 m.
	lay.p_low = Vector3(-0.42, 0.8, 0.0)
	lay.p_high = Vector3(0.42, 0.8, 0.0)
	var f := DefenseGame.ar_frame(lay, 36, 96)
	var xform: Transform3D = f[0]
	var xs: Array = f[1]
	assert_eq(xs.size(), 5)
	for i in range(1, xs.size()):
		assert_almost_eq(float(xs[i]) - float(xs[i - 1]), lay.white_width() * 7.0, 0.01, "one octave apart")
	assert_lt(float(xs[0]), 0.0)
	assert_gt(float(xs[-1]), 0.0)
	# −z of the game frame points away from the player.
	var away: Vector3 = -xform.basis.z
	assert_lt(away.dot(lay.viewer - xform.origin), 0.0)
	# Stations sit behind the keys (further from the player than the keys).
	assert_gt(xform.origin.distance_to(lay.viewer), lay.mid().distance_to(lay.viewer))


func test_ar_lanes_are_one_octave_wide_and_meet_edge_to_edge() -> void:
	var lay := KeyboardLayout.new()
	lay.low = 36
	lay.high = 96
	lay.viewer = Vector3(0, 1.5, 0.6)
	lay.p_low = Vector3(-0.42, 0.8, 0.0)
	lay.p_high = Vector3(0.42, 0.8, 0.0)
	var f := DefenseGame.ar_frame(lay, 36, 96)
	var xs: Array = f[1]
	var w: float = f[2]
	assert_almost_eq(w, lay.white_width() * 7.0, 0.0001)
	for i in range(1, xs.size()):
		assert_almost_eq(float(xs[i]) - float(xs[i - 1]), w, 0.0005, "neighbouring lanes touch")
	# Each lane's left edge is the octave's C left edge.
	var xform: Transform3D = f[0]
	var c_left: Vector3 = lay.keys()[0]["center"] - lay.axes()[0] * lay.white_width() * 0.5
	var lane_left := float(xs[0]) - w * 0.5
	assert_almost_eq((c_left - xform.origin).dot(lay.axes()[0]), lane_left, 0.0005)


func test_ar_frame_leaves_space_between_keys_and_playfield() -> void:
	var lay := KeyboardLayout.new()
	lay.low = 36
	lay.high = 96
	lay.viewer = Vector3(0, 1.5, 0.6)
	lay.p_low = Vector3(-0.42, 0.8, 0.0)
	lay.p_high = Vector3(0.42, 0.8, 0.0)
	var xform: Transform3D = DefenseGame.ar_frame(lay, 36, 96)[0]
	var back: Vector3 = lay.axes()[2]
	var keys_back_edge := lay.white_width() * KeyboardLayout.WHITE_LEN
	var row := (xform.origin - lay.mid()).dot(back)
	# Station bases are 5.8 cm in radius: keep ≥ 3 cm clear in front of them.
	assert_gt(row - keys_back_edge - 0.058, 0.03, "playfield front edge clears the keys")


func test_field_handle_offset_moves_along_game_frame() -> void:
	var h := XRFieldHandle.new()
	h.base = Transform3D(Basis(Vector3(0, 1, 0), PI / 2.0), Vector3(1, 0.8, 0))
	var t := h.placed(Vector3(0, 0, -0.1))
	# 10 cm along the frame's −z (away from the player), not world −z.
	assert_almost_eq(t.origin.distance_to(h.base.origin), 0.1, 0.0001)
	assert_almost_eq((t.origin - h.base.origin).normalized().dot(-h.base.basis.z), 1.0, 0.0001)
	h.free()


func test_waves_cycle_special_events() -> void:
	assert_eq(DefenseWaves.plan(1)["special"], "")
	var seen := {}
	for w in range(2, 5):
		seen[DefenseWaves.plan(w)["special"]] = true
	assert_eq(seen.size(), 3, "three different specials in a row")


func test_new_sector_introduces_new_qualities() -> void:
	assert_eq(DefenseWaves.new_qualities(1), [])
	assert_eq(DefenseWaves.new_qualities(5), ["dim", "aug"])
	assert_eq(DefenseWaves.new_qualities(6), [], "only on a sector's first wave")
	assert_true(DefenseWaves.new_qualities(9).has("m7"))


# --- inversions -----------------------------------------------------------

func test_held_inversion_reads_the_bass() -> void:
	var c := _c("C")
	assert_eq(DefenseRules.held_inversion([60, 64, 67], c), 0, "C in the bass: root position")
	assert_eq(DefenseRules.held_inversion([64, 67, 72], c), 1, "E in the bass: 1st inversion")
	assert_eq(DefenseRules.held_inversion([55, 60, 64], c), 2, "G in the bass: 2nd inversion")
	assert_eq(DefenseRules.held_inversion([58, 64, 67, 72], _c("C7")), 3, "Bb in the bass: 3rd inversion")
	assert_eq(DefenseRules.held_inversion([62, 64, 67], c), -1, "not a chord tone")


func test_wrong_inversion_scores_half() -> void:
	var c := _c("Cm")
	var full := DefenseRules.kill_points(c, 0.4, 5)
	var half := DefenseRules.kill_points(c, 0.4, 5, false)
	assert_eq(half, roundi(full * DefenseRules.WRONG_INVERSION_FACTOR))
	assert_lt(half, full)


func test_voicing_in_octave_honours_the_asked_inversion() -> void:
	for inv in 3:
		var v := DefenseRules.voicing_in_octave(_c("F"), 4, 96, inv, true)
		assert_false(v.is_empty(), "F inversion %d fits in octave 4" % inv)
		assert_eq(DefenseRules.octave_of(v[0]), 4)
		assert_eq(DefenseRules.held_inversion(v, _c("F")), inv)


func test_picked_inversion_is_playable_in_the_station_octave() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var seen := {}
	for k in 60:
		var c := _c(["C", "Am", "G7", "Dm7", "B"][k % 5])
		var inv := DefenseRules.pick_inversion(c, 4, 84, rng)
		seen[inv] = true
		var v := DefenseRules.voicing_in_octave(c, 4, 84, inv, true)
		assert_false(v.is_empty(), "%s inversion %d playable" % [c.pretty(), inv])
	assert_true(seen.size() >= 3, "mixes inversions")


func test_attacker_ring_shows_inversion_number_but_not_root() -> void:
	assert_eq(DefenseAttacker.inversion_text(0), "")
	assert_eq(DefenseAttacker.inversion_text(1), "1")
	assert_eq(DefenseAttacker.inversion_text(3), "3")
	var cols := {}
	for i in 4:
		cols[DefenseAttacker.inversion_color(i).to_html()] = true
	assert_eq(cols.size(), 4, "each inversion has its own colour")


# --- keys hint ------------------------------------------------------------

func test_keys_hint_sticks_to_one_attacker_until_destroyed() -> void:
	var g := DefenseGame.new()
	g.desktop_view = false
	add_child_autofree(g)
	g.configure(36, 96)
	g.set_show_hints(true)
	var shown := []
	g.hint_changed.connect(func(v): shown.append(v))
	g._add_attacker("drifter", [_c("C")], 1, 14.0)
	g._add_attacker("drifter", [_c("G")], 2, 14.0)
	var a: DefenseAttacker = g.attackers[0]
	var b: DefenseAttacker = g.attackers[1]
	a.t = 0.5
	b.t = 0.2
	g._update_threats()
	assert_eq(g._hint_target, a, "starts on the closest attacker")
	assert_false(shown.is_empty())
	# b overtakes a: the hint stays on a.
	b.t = 0.8
	var n := shown.size()
	g._update_threats()
	assert_eq(g._hint_target, a, "doesn't jump to a closer attacker")
	assert_eq(shown.size(), n, "keyboard hint unchanged")
	# a destroyed: the hint moves to b.
	g._kill(a)
	g._update_threats()
	assert_eq(g._hint_target, b)
	assert_eq(DefenseRules.pc_set(shown[-1]), DefenseRules.pc_set([67, 71, 74]), "now shows G")


func test_inversions_off_means_root_position_and_full_points() -> void:
	var g := DefenseGame.new()
	g.desktop_view = false
	add_child_autofree(g)
	g.configure(36, 96)
	g.use_inversions = false
	for k in 6:
		g._add_attacker("drifter", [_c(["C", "Am", "G7"][k % 3])], 1 + k % 3, 14.0)
	for a in g.attackers:
		assert_eq(a.inversion(), 0, "root position only")
	var a: DefenseAttacker = g.attackers[0]
	a.t = 0.3
	var expected := DefenseRules.kill_points(a.chord(), a.t, 0, true)
	# C chord played with E in the bass: still full points.
	g._kill(a, [64, 67, 72])
	assert_eq(g.score, expected)
	assert_eq(g.inv_right + g.inv_wrong, 0, "inversions not counted")


func test_defense_attacks_only_enabled_octaves() -> void:
	var keep: Array = Settings.get_value("disabled_octaves")
	Settings.set_value("disabled_octaves", [2, 4])
	var g := DefenseGame.new()
	g.desktop_view = false
	add_child_autofree(g)
	g.configure(36, 96)
	var alive := g._alive_stations()
	for i in alive:
		assert_false(g.octaves[i] in [2, 4], "octave %d is off" % g.octaves[i])
	assert_eq(alive.size(), g.octaves.size() - 2)
	Settings.set_value("disabled_octaves", keep)
