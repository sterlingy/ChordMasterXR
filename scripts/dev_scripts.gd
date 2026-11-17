class_name DevScripts
extends RefCounted
## Scripted UI states for automated screenshots (no hardware needed).


static func run(script_name: String, screen: PracticeScreen) -> void:
	var tree := screen.get_tree()
	var s := screen.session
	match script_name:
		"play_correct":
			for m in s.prompt.voicing():
				Midi.inject_note_on(m)
				await tree.create_timer(0.05).timeout
		"play_wrong":
			var v := s.prompt.voicing()
			Midi.inject_note_on(v[0])
			Midi.inject_note_on(v[0] + 1)
		"strip_all", "strip_nostaff":
			Settings.set_value("show_notes", true)
			Settings.set_value("show_keyboard_hint", true)
			Settings.set_value("play_on_prompt", true)
			Settings.set_value("strict_inversion", true)
			if script_name == "strip_nostaff":
				Settings.set_value("show_staff", false)
		"notes_inv", "notes_inv7":
			Settings.set_value("show_notes", true)
			if script_name == "notes_inv7":
				s.prompt.chord = Theory.parse_chord("Bbm7b5")
				s.prompt.inversion = 3
			else:
				s.prompt.inversion = 1
			screen._refresh_prompt_view()
		"defense", "defense_kill", "defense_over", "defense_notes":
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("show_notes", script_name == "defense_notes")
			Settings.set_value("show_keyboard_hint", true)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			var g: DefenseGame = screen._defense.game
			screen.find_child("DefenseStart", true, false).emit_signal("pressed")
			if script_name == "defense_over":
				Settings.set_value("player_name", "Tester")
				if OS.get_environment("CMX_BOARD") != "":
					Settings.set_value("leaderboard_url", OS.get_environment("CMX_BOARD"))
				await tree.create_timer(0.5).timeout
				g.score = 12450
				g.wave = 7
				g.kills = 38
				g.misfires = 5
				g.best_combo = 14
				g.kill_ms.assign([2100, 3400, 1800, 5200])
				g.records.record_kill("F#:min", 5200)
				g.records.record_escape("Bb:dim")
				g._end_game()
				await tree.create_timer(1.5).timeout
				return
			await tree.create_timer(2.6 + 9.0).timeout
			print("DEV attackers=", g.attackers.size(), " state=", g.state)
			if script_name == "defense_kill" and not g.attackers.is_empty():
				var a: DefenseAttacker = g.attackers[0]
				var v := DefenseRules.voicing_in_octave(a.chord(), g.octaves[a.station], g.range_high)
				print("DEV playing ", a.chord().pretty(), " ", v, " for octave ", g.octaves[a.station])
				for m in v:
					Midi.inject_note_on(m)
				await tree.create_timer(0.12).timeout
				print("DEV kills=", g.kills, " score=", g.score)
				for m in v:
					Midi.inject_note_off(m)
				await tree.create_timer(0.1).timeout
		"defense_bot", "defense_boss":
			# Plays the game at high speed, killing most attackers and letting
			# some through, to exercise waves, bosses, hits and game over.
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("show_keyboard_hint", true)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			var g: DefenseGame = screen._defense.game
			screen.find_child("DefenseStart", true, false).emit_signal("pressed")
			Engine.time_scale = 6.0
			var rng := RandomNumberGenerator.new()
			rng.seed = 3
			var until_wave := 5 if script_name == "defense_boss" else 99
			var limit := 0.0
			while limit < 400.0 and g.state != DefenseGame.State.OVER:
				await tree.create_timer(0.35).timeout
				limit += 0.35
				if g.wave >= until_wave and g.state == DefenseGame.State.PLAYING:
					var has_boss := false
					for a in g.attackers:
						has_boss = has_boss or a.kind == "boss"
					if has_boss:
						break
				if g.attackers.is_empty() or g.state != DefenseGame.State.PLAYING:
					continue
				var top: DefenseAttacker = null
				for a in g.attackers:
					if a.t > 0.3 and (top == null or a.t > top.t):
						top = a
				if top == null:
					continue
				# The plain bot lets some attackers through to test hits / game over.
				if script_name == "defense_bot":
					if not top.has_meta("bot_skip"):
						top.set_meta("bot_skip", rng.randf() < 0.3)
					if top.get_meta("bot_skip"):
						var others := g.attackers.filter(func(o): return not o.get_meta("bot_skip", false) and o.t > 0.3)
						if others.is_empty():
							continue
						top = others[0]
				var miss := rng.randf() < (0.08 if script_name == "defense_boss" else 0.25)
				var v := DefenseRules.voicing_in_octave(top.chord(), g.octaves[top.station], g.range_high)
				if miss:
					v = [v[0], v[0] + 1, v[0] + 2]
				for m in v:
					Midi.inject_note_on(m)
				await tree.process_frame
				for m in v:
					Midi.inject_note_off(m)
			Engine.time_scale = 1.0
			print("DEV bot: wave=", g.wave, " score=", g.score, " kills=", g.kills, " misfires=", g.misfires, " hits=", g.hits_taken, " state=", g.state, " stations=", g._alive_stations().size())
			await tree.create_timer(0.3).timeout
		"defense_w5", "defense_w9", "defense_w13", "defense_w17":
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			screen._defense._help.visible = false
			var g: DefenseGame = screen._defense.game
			g.start(int(script_name.trim_prefix("defense_w")))
			await tree.create_timer(2.6 + 14.0).timeout
			print("DEV wave ", g.wave, " attackers=", g.attackers.size())
			var cam := g.get_viewport().get_camera_3d()
			for a in g.attackers:
				print("DEV plate ", a.plate_text(), " t=%.2f lift=%.3f scale=%.2f at %s" % [a.t, a.plate_lift, a.plate_scale, cam.unproject_position(a.plate_anchor())])
		"defense_pause":
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			var g: DefenseGame = screen._defense.game
			screen.find_child("DefenseStart", true, false).emit_signal("pressed")
			await tree.create_timer(8.0).timeout
			var a: DefenseAttacker = g.attackers[0]
			screen._set_paused(true)
			var t0 := a.t
			await tree.create_timer(1.5).timeout
			var v := DefenseRules.voicing_in_octave(a.chord(), g.octaves[a.station], g.range_high)
			for m in v:
				Midi.inject_note_on(m)
			await tree.process_frame
			for m in v:
				Midi.inject_note_off(m)
			print("DEV paused: moved=", a.t != t0, " kills=", g.kills)
			screen._set_paused(false)
			await tree.create_timer(0.5).timeout
			print("DEV resumed: moving=", a.t != t0)
			# Switch mode mid-game.
			screen._mode_btn.select(0)
			screen._mode_btn.item_selected.emit(0)
			await tree.create_timer(0.5).timeout
			print("DEV after switch: running=", g.is_running(), " attackers=", g.attackers.size(), " mode=", Settings.get_value("practice_mode"))
		"defense_sector":
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			screen._defense._help.visible = false
			screen._defense.game.start(9)
			await tree.create_timer(1.5).timeout
		"defense_idle":
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			Settings.set_value("practice_mode", "defense")
			screen._apply_display_settings()
			await tree.create_timer(0.6).timeout
		"paused":
			Settings.set_value("show_notes", true)
			Settings.set_value("show_keyboard_hint", true)
			screen._set_paused(true)
			for m in s.prompt.voicing():
				Midi.inject_note_on(m)
			await tree.create_timer(0.4).timeout
			print("DEV paused state=", s.state, " correct=", s.correct_count)
		"hold_after_correct":
			for m in s.prompt.voicing():
				Midi.inject_note_on(m)
			var first := s.prompt
			await tree.create_timer(float(Settings.get_value("advance_delay")) + 1.0).timeout
			print("DEV still held: same prompt=", s.prompt == first, " state=", s.state)
			for m in first.voicing():
				Midi.inject_note_off(m)
			await tree.create_timer(0.3).timeout
			print("DEV released: same prompt=", s.prompt == first, " state=", s.state)
		"one_panel":
			screen.find_child("ChordsButton", true, false).emit_signal("pressed")
			await tree.create_timer(0.3).timeout
			screen.find_child("SettingsButton", true, false).emit_signal("pressed")
			await tree.create_timer(0.3).timeout
			print("DEV pool visible=", screen._pool_panel.visible, " settings visible=", screen._settings_panel.visible)
		"settings":
			screen._settings_panel.open()
		"pool":
			screen._pool_panel.open()
		"name":
			Settings.set_value("practice_mode", "name")
			s.start()
		"select":
			Settings.set_value("input_mode", "select")
			Settings.set_value("practice_mode", "play")
			s.start()
			for m in s.prompt.voicing():
				screen._keyboard.toggle_selected(m)
		"grand":
			Settings.set_value("clef_mode", "grand")
			Settings.set_value("accidental_mode", "key_signature")
			var pool := ChordPool.new()
			pool.source = "custom"
			pool.custom = ["Ebmaj9"]
			Settings.set_pool(pool)
			s.start()
		"compile_all":
			for path in ["res://scripts/xr/xr_main.gd", "res://scripts/xr/xr_panel.gd", "res://scripts/xr/xr_pointer.gd", "res://scripts/xr/keyboard_overlay.gd", "res://scripts/xr/keyboard_layout.gd", "res://scripts/xr/xr_hand_touch.gd", "res://scenes/xr_main.tscn"]:
				var r = load(path)
				print("LOADED ", path, " -> ", r != null and (not r is GDScript or r.can_instantiate()))
		"reset":
			Settings.reset_to_defaults()
			s.start()
		"song_key", "song_key_play":
			Settings.set_value("song_id", "hotel_california")
			Settings.set_value("song_transpose", {"hotel_california": 1})
			Settings.set_value("practice_mode", "song")
			screen._apply_display_settings()
			if script_name == "song_key_play":
				Settings.set_value("song_bpm", {"hotel_california": 92})
				var hc := screen._current_song()
				screen._song.start(hc, screen._bpm_for(hc))
				await tree.create_timer(screen._song.engine.count_in_seconds() + 3.5).timeout
		"song_idle":
			Settings.set_value("practice_mode", "song")
			screen._apply_display_settings()
		"song_mid", "song_sim":
			Settings.set_value("practice_mode", "song")
			Settings.set_value("show_keyboard_hint", true)
			screen._apply_display_settings()
			var sg := Song.from_dict({"id": "dev", "title": "Dev Test", "artist": "Chord Master", "year": 2026,
				"bpm": 120, "beats_per_bar": 4, "sections": {"A": ["C", "G", "Am F", "C"]}, "order": ["A"]})
			screen._song.start(sg)
			var plan := [[0.0, 0.0], [4.0, -0.04], [8.0, 0.15], [10.0, 999.0], [12.0, 0.02]]  # [beat, offset s]
			var t0 := Time.get_ticks_usec()
			for step in plan:
				if step[1] > 100.0:
					continue  # miss this one
				var at: float = screen._song.engine.count_in_seconds() + step[0] * 0.5 + step[1] + AudioServer.get_output_latency()
				while (Time.get_ticks_usec() - t0) / 1e6 < at:
					await tree.process_frame
				var idx := screen._song.engine.current_index(step[0] * 0.5 + 0.01)
				var c: Theory.Chord = screen._song.engine.targets[idx]["chord"]
				Midi.release_all()
				for m in c.voicing(ChordPrompt.place_root(c, 0, 48, 84), 0):
					Midi.inject_note_on(m)
				print("DEV played ", c.symbol(), " target ", idx)
				if script_name == "song_mid" and step[0] >= 8.0:
					return
			while screen._song.running:
				await tree.process_frame
			print("DEV results ", screen._song.engine.results())
		"qwerty":
			Settings.set_value("qwerty_input", true)
			for k in [KEY_A, KEY_D, KEY_G]:
				var e := InputEventKey.new()
				e.physical_keycode = k
				e.keycode = k
				e.pressed = true
				Input.parse_input_event(e)
				await tree.process_frame
			print("DEV held ", Midi.held_notes())
			var z := InputEventKey.new()
			z.physical_keycode = KEY_X
			z.pressed = true
			Input.parse_input_event(z)
			await tree.process_frame
			print("DEV octave ", Midi.qwerty_octave)
		"acc_inversions":
			# Same layout as a printed example: Ebm7 root, 1st, 2nd inversion.
			Settings.set_value("clef_mode", "treble")
			Settings.set_value("accidental_mode", "accidentals")
			var c := Theory.parse_chord("Ebm7")
			screen._staff.show_chord(c.voiced_tones(63, int(OS.get_environment("CM_INV"))), 0)
		"acc_sharps", "acc_flats", "acc_keysig":
			Settings.set_value("clef_mode", "treble")
			var sym: String = {"acc_sharps": "F#7", "acc_flats": "Ebm7", "acc_keysig": "Dbmaj7"}[script_name]
			Settings.set_value("accidental_mode", "key_signature" if script_name == "acc_keysig" else "accidentals")
			var c := Theory.parse_chord(sym)
			var rm := ChordPrompt.place_root(c, 0, 60, 84)
			screen._staff.show_chord(c.voiced_tones(rm, 0), Theory.key_signature(c.root) if script_name == "acc_keysig" else 0)
			screen._staff.set_meta("debug_lines", true)
			print("DEV ink sharp ", screen._staff._glyph_ink("â™¯", 50), " flat ", screen._staff._glyph_ink("â™­", 50))
		"type_ip":
			screen._settings_panel.open()
			await tree.create_timer(0.3).timeout
			var le: LineEdit = screen._settings_panel.find_child("NetTarget", true, false)
			var sc: ScrollContainer = screen._settings_panel.find_child("Input", true, false)
			sc.ensure_control_visible(le)
			await tree.create_timer(0.3).timeout
			print("DEV lineedit editable=", le.editable, " focus_mode=", le.focus_mode, " visible=", le.is_visible_in_tree())
			var r := le.get_global_rect()
			var win := le.get_window()
			var p := r.get_center() + (Vector2(win.position) if win != tree.root else Vector2.ZERO)
			await _click(tree, p)
			await tree.create_timer(0.2).timeout
			print("DEV click at ", p, " rect ", r, " win pos ", win.position, " hit=", win.gui_get_hovered_control() if win.has_method("gui_get_hovered_control") else "?")
			print("DEV focus owner in popup=", win.gui_get_focus_owner(), " root focus=", tree.root.gui_get_focus_owner())
			for ch in "10.0.0.220":
				var e := InputEventKey.new()
				e.unicode = ch.unicode_at(0)
				e.keycode = OS.find_keycode_from_string(ch) if ch != "." else KEY_PERIOD
				e.pressed = true
				Input.parse_input_event(e)
				await tree.process_frame
				var u := e.duplicate()
				u.pressed = false
				Input.parse_input_event(u)
				await tree.process_frame
			print("DEV typed text='", le.text, "'")
		"net_discover":
			Settings.set_value("net_send", true)
			var t0 := Time.get_ticks_msec()
			while Midi.net.receivers.is_empty() and Time.get_ticks_msec() - t0 < 8000:
				await tree.process_frame
			print("DEV receivers after %d ms: %s" % [Time.get_ticks_msec() - t0, Midi.net.receivers])
			# Play a C major chord "from the laptop keyboard".
			for m in [60, 64, 67]:
				Midi.handle_message(0, MIDI_MESSAGE_NOTE_ON, m, 100)
			await tree.create_timer(1.5).timeout
			for m in [60, 64, 67]:
				Midi.handle_message(0, MIDI_MESSAGE_NOTE_OFF, m, 0)
			print("DEV packets sent: ", Midi.net.packets_sent, "  status: ", Midi.net.status_text())
		"defense_ar_left", "defense_ar_right":
			# Desktop preview of Chord Defense placed on a calibrated real
			# keyboard (as in XR), seen from the left or right of the player.
			screen.visible = false
			var world := Node3D.new()
			tree.root.add_child(world)
			var cam := Camera3D.new()
			world.add_child(cam)
			var side := -0.35 if script_name == "defense_ar_left" else 0.35
			cam.position = Vector3(side, 1.25, 0.45)
			cam.look_at(Vector3(0, 0.8, -0.25))
			cam.fov = 60
			cam.current = true
			var light := DirectionalLight3D.new()
			light.rotation_degrees = Vector3(-60, 20, 0)
			world.add_child(light)
			Settings.set_value("range_low", 36)
			Settings.set_value("range_high", 96)
			var ov := XRKeyboardOverlay.new()
			ov.source = screen._keyboard
			world.add_child(ov)
			ov.layout.viewer = Vector3(0, 1.25, 0.45)
			ov.layout.p_low = Vector3(-0.42, 0.80, 0.0)
			ov.layout.p_high = Vector3(0.42, 0.80, 0.0)
			ov._calibrated = true
			ov._rebuild()
			var g := DefenseGame.new()
			g.desktop_view = false
			world.add_child(g)
			var frame := DefenseGame.ar_frame(ov.layout, 36, 96)
			g.enter_ar(frame[0], frame[1])
			g.set_show_notes(true)
			g.show_showcase()
			await tree.create_timer(0.8).timeout
			for st in g.stations:
				var l: Label3D = st._label
				print("DEV label ", l.text, " basis ", l.global_basis, " billboard ", l.billboard)
		"overlay_preview", "overlay_adjust":
			# Desktop preview of the XR keyboard overlay (no headset): a fake
			# table-height keyboard seen from where a player's eyes would be.
			screen.visible = false
			var world := Node3D.new()
			tree.root.add_child(world)
			var cam := Camera3D.new()
			world.add_child(cam)
			cam.position = Vector3(0.26, 1.18, 0.42)
			cam.look_at(Vector3(0.26, 0.78, -0.07))
			cam.fov = 55
			cam.current = true
			var table := MeshInstance3D.new()
			var tb := BoxMesh.new()
			tb.size = Vector3(0.62, 0.05, 0.22)
			table.mesh = tb
			var tm := StandardMaterial3D.new()
			tm.albedo_color = Color(0.18, 0.18, 0.2)
			table.material_override = tm
			table.position = Vector3(0.247, 0.765, -0.075)
			world.add_child(table)
			var light := DirectionalLight3D.new()
			light.rotation_degrees = Vector3(-60, 20, 0)
			world.add_child(light)
			var ov := XRKeyboardOverlay.new()
			ov.source = screen._keyboard
			world.add_child(ov)
			Settings.set_value("range_low", 48)
			Settings.set_value("range_high", 84)
			ov.layout.p_low = Vector3(0.0, 0.80, 0.0)
			ov.layout.p_high = Vector3(0.0235 * 21, 0.80, 0.0)
			ov._calibrated = true
			ov._rebuild()
			if script_name == "overlay_adjust":
				Settings.set_value("xr_kb_adjust", true)
				for i in 4:
					ov.nudge("turn", 1)
				ov.nudge("tilt", 1)
				ov.begin_handle(1, "high", ov.layout.p_high)
				ov.update_handle(1, ov.layout.p_high + Vector3(0, 0.0, 0.02))
				ov.end_handle(1)
				ov.set_hover(2, "low")
				print("DEV cal ", Settings.get_value("xr_keyboard_cal"))
			screen._keyboard.set_hints([60, 64, 67, 71])
			screen._keyboard.set_held([60, 64])
			screen._keyboard.set_wrong([66])
			await tree.create_timer(0.5).timeout
		"settings_overlay":
			screen._settings_panel.open()
			await tree.create_timer(0.2).timeout
			var tabs: TabContainer = screen._settings_panel.find_child("Tabs", true, false)
			var disp := tabs.find_child("Display", false, false)
			tabs.current_tab = disp.get_index()
			var box: Control = screen._settings_panel.find_child("XROverlayBox", true, false)
			box.visible = true
			await tree.create_timer(0.2).timeout
			var sc := disp as ScrollContainer if disp is ScrollContainer else disp.find_child("*", true, false) as ScrollContainer
			if sc:
				sc.ensure_control_visible(screen._settings_panel.find_child("WidthRow", true, false))
		"settings_wifi":
			screen._settings_panel.open()
			await tree.create_timer(0.2).timeout
			var sc: ScrollContainer = screen._settings_panel.find_child("Input", true, false)
			sc.scroll_vertical = 100000
		"click_mode", "click_exercise":
			# Real mouse clicks through the input system, like a user.
			var btn: Control = screen._mode_btn if script_name == "click_mode" else screen._exercise_btn
			await _click(tree, btn.get_global_rect().get_center())
			await tree.create_timer(0.4).timeout
			var popup: PopupMenu = btn.get_popup()
			print("POPUP visible=", popup.visible, " items=", popup.item_count, " pos=", popup.position, " size=", popup.size)
		"select_mode_item":
			await _pick(tree, screen._mode_btn, 1)
			print("MODE now ", Settings.get_value("practice_mode"), " selected=", screen._mode_btn.selected)
		"select_exercise_item":
			await _pick(tree, screen._exercise_btn, 2)
			print("EXERCISE now ", Settings.get_value("exercise_type"), " selected=", screen._exercise_btn.selected)
		"select_settings_item":
			screen._settings_panel.open()
			await tree.create_timer(0.3).timeout
			var ob: OptionButton = screen._settings_panel.find_child("InputMode", true, false)
			await _pick(tree, ob, 1)
			print("INPUT now ", Settings.get_value("input_mode"), " selected=", ob.selected, " panel visible=", screen._settings_panel.visible)


## Clicks an OptionButton, then clicks item `index` in its popup.
static func _pick(tree: SceneTree, btn: OptionButton, index: int) -> void:
	var win := btn.get_window()
	var local := btn.get_global_rect().get_center()
	await _click(tree, local + Vector2(win.position) if win != tree.root else local)
	await tree.create_timer(0.4).timeout
	var popup := btn.get_popup()
	print("PICK popup visible=", popup.visible, " at ", popup.position, " size ", popup.size)
	if not popup.visible:
		return
	var item_h := popup.size.y / float(popup.item_count)
	var target := Vector2(popup.position) + Vector2(popup.size.x * 0.5, item_h * (index + 0.5))
	await _click(tree, target)
	await tree.create_timer(0.4).timeout


static func _click(tree: SceneTree, pos: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	Input.parse_input_event(move)
	await tree.process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await tree.process_frame
