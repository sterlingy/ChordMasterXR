class_name DefenseView
extends Control
## Shows Chord Defense inside the practice screen: a 3D viewport with the
## game, a HUD on top (score, wave, combo, stations), wave banners and the
## game-over card with stats and the leaderboard.

var game: DefenseGame
var _vpc: SubViewportContainer
var _vp: SubViewport
var _score: Label
var _wave: Label
var _combo: Label
var _stations: Label
var _banner_box: VBoxContainer
var _banner_title: Label
var _banner_sub: Label
var _card: PanelContainer
var _card_text: RichTextLabel
var _help: Label
var _ar_note: Label
var _card_base := ""
var _key: HBoxContainer
const SENDING := "[color=#9aa3c0]Sending to the global leaderboard…[/color]"


func _ready() -> void:
	clip_contents = true
	_vpc = SubViewportContainer.new()
	_vpc.stretch = true
	_vpc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vpc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.handle_input_locally = false
	_vpc.add_child(_vp)
	game = DefenseGame.new()
	_vp.add_child(game)

	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	_score = _hud_label(hud, 30, Color(1, 1, 1), Control.PRESET_TOP_LEFT, HORIZONTAL_ALIGNMENT_LEFT)
	_wave = _hud_label(hud, 18, Color(0.7, 0.75, 0.95), Control.PRESET_TOP_LEFT, HORIZONTAL_ALIGNMENT_LEFT)
	_wave.position.y += 40
	_combo = _hud_label(hud, 30, Color(1, 0.8, 0.3), Control.PRESET_TOP_RIGHT, HORIZONTAL_ALIGNMENT_RIGHT)
	_stations = _hud_label(hud, 18, Color(0.6, 0.9, 1.0), Control.PRESET_TOP_RIGHT, HORIZONTAL_ALIGNMENT_RIGHT)
	_stations.position.y += 40
	_key = inversion_key()
	hud.add_child(_key)

	_banner_box = VBoxContainer.new()
	# Banners sit in the upper part of the view, above the action (and above
	# the new-chord ships shown at a sector's start).
	_banner_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner_box.offset_top = 48
	_banner_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_banner_box)
	_banner_title = _plain_label(42, Color(1, 1, 1))
	_banner_sub = _plain_label(22, Color(0.85, 0.88, 1.0))
	_banner_box.add_child(_banner_title)
	_banner_box.add_child(_banner_sub)

	_help = _plain_label(20, Color(0.8, 0.85, 1.0))
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_help.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_help.offset_top = 64
	_refresh_inversion_text()
	Settings.changed.connect(func(key: String):
		if key == "defense_inversions":
			_refresh_inversion_text())
	_help.add_theme_font_size_override("font_size", 18)
	hud.add_child(_help)

	_card = PanelContainer.new()
	_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_card.custom_minimum_size = Vector2(620, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.1, 0.92)
	sb.border_color = Color(0.45, 0.6, 1.0, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	_card.add_theme_stylebox_override("panel", sb)
	_card_text = RichTextLabel.new()
	_card_text.bbcode_enabled = true
	_card_text.fit_content = true
	_card_text.scroll_active = false
	_card_text.custom_minimum_size = Vector2(580, 0)
	_card_text.add_theme_font_size_override("normal_font_size", 17)
	_card_text.add_theme_font_size_override("bold_font_size", 17)
	_card.add_child(_card_text)
	_card.visible = false
	hud.add_child(_card)

	_ar_note = _plain_label(24, Color(0.75, 0.9, 1.0))
	_ar_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ar_note.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_ar_note.text = "The game is on your keyboard — look down at your keys.
"
	_ar_note.visible = false
	hud.add_child(_ar_note)

	game.hud_changed.connect(_on_hud)
	game.banner.connect(_on_banner)
	game.game_over.connect(_on_game_over)
	game.leaderboard.result.connect(_on_global)
	_on_banner("", "")
	game.show_showcase.call_deferred()
	_on_hud({"score": 0, "wave": 0, "sector": "", "combo": 1, "stations": game.stations.size(),
		"stations_total": game.stations.size(), "best": int(game.records.lifetime["best_score"]), "running": false})


func _hud_label(parent: Control, size_px: int, color: Color, preset: int, align: int) -> Label:
	var l := _plain_label(size_px, color)
	l.set_anchors_and_offsets_preset(preset)
	l.horizontal_alignment = align
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN if align == HORIZONTAL_ALIGNMENT_RIGHT else Control.GROW_DIRECTION_END
	l.position += Vector2(-14 if align == HORIZONTAL_ALIGNMENT_RIGHT else 14, 10)
	parent.add_child(l)
	return l


func _plain_label(size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0.05, 0.9))
	l.add_theme_constant_override("outline_size", 8)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _refresh_inversion_text() -> void:
	var on := bool(Settings.get_value("defense_inversions"))
	_key.visible = on
	if on:
		_help.text = "CHORD DEFENSE — press Start below\nPlay each chord with its lowest note in the octave it attacks. The pin's colour and number show the inversion: empty = root position, 1 / 2 / 3 = that inversion. Another inversion still counts, for half the points."
	else:
		_help.text = "CHORD DEFENSE — press Start below\nPlay each chord with its lowest note in the octave it attacks. Any inversion counts."


## Colour key for the attackers' pins: one coloured dot per inversion.
static func inversion_key(font_px := 17) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	row.offset_left = 14
	row.offset_top = 70
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names := ["root", "1st", "2nd", "3rd"]
	var title := Label.new()
	title.text = "Inversion:"
	_style_key_label(title, font_px, Color(0.85, 0.88, 1.0))
	row.add_child(title)
	for i in names.size():
		var l := Label.new()
		l.text = "● " + names[i]
		_style_key_label(l, font_px, DefenseAttacker.inversion_color(i))
		row.add_child(l)
	return row


static func _style_key_label(l: Label, px: int, c: Color) -> void:
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", c)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0.05, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE


## The SubViewport the game lives in on desktop (XR moves it out to the room).
func viewport() -> SubViewport:
	return _vp


## XR: the game has moved onto the real keyboard; the panel keeps the HUD.
func set_ar(on: bool) -> void:
	_vpc.visible = not on
	_ar_note.visible = on


func start() -> void:
	_card.visible = false
	_help.visible = false
	game.start()


func stop() -> void:
	game.stop()
	_card.visible = false
	_help.visible = true
	_on_banner("", "")


func _on_hud(i: Dictionary) -> void:
	_score.text = "%d" % int(i["score"])
	_wave.text = ("Wave %d · %s" % [int(i["wave"]), i["sector"]]) if int(i["wave"]) > 0 else "Best %d" % int(i["best"])
	var new_combo := "×%d" % int(i["combo"]) if int(i["combo"]) > 1 else ""
	if new_combo != _combo.text and new_combo != "":
		# Pulse when the multiplier goes up.
		_combo.pivot_offset = _combo.size * Vector2(1.0, 0.5)
		var tw := create_tween()
		tw.tween_property(_combo, "scale", Vector2.ONE * 1.5, 0.08)
		tw.tween_property(_combo, "scale", Vector2.ONE, 0.25)
	_combo.text = new_combo
	_stations.text = "Stations %d / %d" % [int(i["stations"]), int(i["stations_total"])]


func _on_banner(title: String, sub: String) -> void:
	_banner_title.text = title
	_banner_sub.text = sub
	_banner_box.visible = title != "" or sub != ""


func _on_game_over(s: Dictionary) -> void:
	_on_banner("", "")
	var lines := []
	lines.append("[center][font_size=32][b]Game over[/b][/font_size]")
	lines.append("[font_size=26][color=#ffd36b]%d[/color][/font_size]  points · reached wave %d" % [int(s["score"]), int(s["wave"])])
	var rank := int(s["rank"])
	if rank == 1:
		lines.append("[color=#7dff9b][b]New high score![/b][/color]")
	elif rank > 0:
		lines.append("[color=#7dff9b]#%d on your leaderboard[/color]" % rank)
	lines.append("[/center]")
	lines.append("Chords destroyed [b]%d[/b]   ·   accuracy [b]%d%%[/b]   ·   best combo [b]%d[/b]" % [
		int(s["kills"]), roundi(100.0 * float(s["accuracy"])), int(s["best_combo"])])
	if int(s["kills"]) > 0 and s.get("inversions", true):
		lines.append("Inversions: [color=#7dff9b][b]%d[/b] correct[/color]   ·   [color=#ffb36b][b]%d[/b] wrong[/color] (half points)" % [
			int(s.get("inv_right", 0)), int(s.get("inv_wrong", 0))])
	if int(s["kills"]) > 0:
		lines.append("Average time to destroy [b]%.1f s[/b]   ·   fastest [b]%.1f s[/b]" % [float(s["avg_ms"]) / 1000.0, float(s["fastest_ms"]) / 1000.0])
	var nem: Array = s["nemesis"]
	if not nem.is_empty():
		var names := []
		for k in nem:
			var parts := str(k).split(":")
			var c := Theory.make_chord(parts[0], parts[1]) if parts.size() == 2 else null
			names.append(c.pretty() if c else str(k))
		lines.append("Chords to practise: [color=#ffb36b]%s[/color]" % ",  ".join(names))
	lines.append("[b]Leaderboard[/b] (%d stations)" % int(s["stations"]))
	var board: Array = s["board"]
	for i in mini(board.size(), 3):
		var e: Dictionary = board[i]
		var me := int(e["score"]) == int(s["score"]) and i + 1 == rank
		var row := "%d.  %s   %d   (wave %d)" % [i + 1, e["name"], int(e["score"]), int(e["wave"])]
		lines.append(("[color=#7dff9b]%s[/color]" % row) if me else row)
	var lt: Dictionary = s["lifetime"]
	lines.append("[color=#9aa3c0]All time: %d games · %d chords destroyed · best wave %d  ·  Press Start to play again[/color]" % [int(lt["games"]), int(lt["kills"]), int(lt["best_wave"])])
	if game.leaderboard.enabled():
		lines.append(SENDING)
	_card_base = "\n".join(lines)
	_card_text.text = _card_base
	_card.visible = true


func _on_global(r: Dictionary) -> void:
	var t := _card_base.replace(SENDING, "")
	if not r.get("ok", false):
		t += "[color=#ff9a8a]Global leaderboard: %s[/color]" % r.get("error", "unavailable")
	else:
		var rows: Array = r.get("rows", [])
		var top := []
		for i in mini(3, rows.size()):
			top.append("%d. %s %d" % [i + 1, str(rows[i].get("name", "?")), int(rows[i].get("score", 0))])
		t += "[b]Global:[/b] #%d of %d   ·   %s" % [int(r.get("rank", 0)), int(r.get("total", 0)), "   ".join(top)]
	_card_text.text = t
