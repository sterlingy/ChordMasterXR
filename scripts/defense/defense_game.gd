class_name DefenseGame
extends Node3D
## Chord Defense: chords attack your octave stations; play them to destroy
## them. See docs/chord_defense.md.
##
## The world is built in metres: stations along +x at y = 0, z = 0 (where
## the keyboard is), attackers coming from −z. On desktop a camera sits at
## the player's eyes; in AR this node is placed on the real keyboard.
##
## Input is only the MIDI keyboard (Midi autoload). The screen calls
## start() / stop() / set_paused().

signal hud_changed(info: Dictionary)
signal banner(title: String, sub: String)
signal feedback(text: String, color: Color)
signal hint_changed(voicing: Array)
signal game_over(summary: Dictionary)

enum State { IDLE, INTRO, PLAYING, CLEAR, OVER }

const OCTAVE_W := 0.165          # one octave of real keys, metres
const FIELD_DEPTH := 1.4
const TOP_Y := 0.27
const INTRO_S := 2.6
## AR: gap between the back of the white keys and the station row. Station
## bases are ~6 cm in radius, so this leaves ~5 cm of clear space between
## the keyboard overlay and the front edge of the playfield.
const AR_GAP := 0.11
const CLEAR_S := 3.0

## Build a camera + sky for a desktop view (off in AR, where the room is
## the backdrop).
@export var desktop_view := true

var state := State.IDLE
var paused := false
var range_low := 48
var range_high := 84
var use_pool := false
## Attackers ask for an inversion (Settings "defense_inversions"). Off:
## all root position, and any inversion scores full points.
var use_inversions := true
var pool_entries: Array = []
var stats: PracticeStats          # practice stats (optional; set by the screen)
var records := DefenseRecords.new()

var stations: Array[DefenseStation] = []
var octaves: Array[int] = []
var attackers: Array[DefenseAttacker] = []
var rng := RandomNumberGenerator.new()

var wave := 0
var plan := {}
var score := 0
var streak := 0
var best_combo := 0
var kills := 0
var misfires := 0
var inv_right := 0               # kills in the inversion the ring asked for
var inv_wrong := 0               # kills in another inversion (half points)
var hits_taken := 0
var spawned := 0
var boss_spawned := false
var kill_ms: Array[int] = []
var _state_t := 0.0
var _intro_s := INTRO_S
var _spawn_t := 0.0
var _play_s := 0.0
var _hint_key := ""
## Keys hint: the attacker shown on the keyboard. Once picked (the closest
## one), it stays until it is destroyed or reaches its station.
var _hint_target: DefenseAttacker = null
var show_notes := false
var show_hints := false

var sfx := DefenseSfx.new()
var leaderboard := DefenseLeaderboard.new()
var camera: Camera3D
var _backdrop: Node3D          # desktop-only sky, stars, grid, camera
## AR: station x positions measured from the real keyboard ([] = even spacing).
var station_xs: Array[float] = []
## Lane width: a little under an octave on desktop; exactly one octave of
## the real keyboard in AR.
const DESKTOP_LANE_W := 0.15
var lane_width := DESKTOP_LANE_W
var in_ar := false
var _world_env: WorldEnvironment
var _grid_mat: StandardMaterial3D
var _nebulae: Array[MeshInstance3D] = []
var _stars: MultiMeshInstance3D
var _field: Node3D            # stations + lanes + attackers live here
var _ar_key: Node3D           # AR: inversion colour key beside the stations
var _fx: Node3D


func _ready() -> void:
	records.save_path = "user://dev_defense_records.json" if Settings.is_dev_run() else "user://defense_records.json"
	records.load_from_disk()
	_field = Node3D.new()
	add_child(_field)
	_fx = Node3D.new()
	add_child(_fx)
	add_child(sfx)
	add_child(leaderboard)
	if desktop_view:
		_build_backdrop()
	use_inversions = bool(Settings.get_value("defense_inversions"))
	Settings.changed.connect(func(key: String):
		if key == "defense_inversions":
			set_use_inversions(bool(Settings.get_value(key))))
	Midi.note_on.connect(_on_note_on)
	Midi.held_changed.connect(_on_held_changed)
	get_viewport().size_changed.connect(_place_camera)
	configure(range_low, range_high)


# --- setup --------------------------------------------------------------

## Lays out one station per full octave in [low, high].
func configure(low: int, high: int) -> void:
	range_low = low
	range_high = high
	for s in stations:
		s.queue_free()
	stations.clear()
	octaves = DefenseRules.station_octaves(low, high)
	if octaves.is_empty():
		# Tiny keyboard: still give one station on the lowest octave in range.
		octaves.append(DefenseRules.octave_of(low))
	var n := octaves.size()
	for i in n:
		var st := DefenseStation.new()
		var hue := 0.58 - 0.5 * (float(i) / maxf(1.0, n - 1.0))
		st.setup(octaves[i], Color.from_hsv(fposmod(hue, 1.0), 0.55, 1.0), FIELD_DEPTH, lane_width)
		st.position = Vector3(station_x(i), 0, 0)
		_field.add_child(st)
		stations.append(st)
	_place_camera()
	if state == State.IDLE and not _showcase.is_empty():
		show_showcase()


func station_x(i: int) -> float:
	if station_xs.size() == octaves.size():
		return station_xs[i]
	return (i - (octaves.size() - 1) * 0.5) * OCTAVE_W


## AR: put the game on the real keyboard. `xform` is the game frame (x along
## the keys, y up, −z away from the player); `xs` the station x positions
## in that frame, one per station octave; `octave_w` one octave of the real
## keyboard (the lane width).
func enter_ar(xform: Transform3D, xs: Array[float], octave_w := OCTAVE_W) -> void:
	lane_width = octave_w
	in_ar = true
	if _backdrop:
		_backdrop.queue_free()
		_backdrop = null
		_world_env = null
		camera = null
	global_transform = xform
	station_xs = xs
	if not is_running():
		configure(range_low, range_high)
	else:
		for i in stations.size():
			stations[i].position.x = station_x(i)
			stations[i].set_lane_width(lane_width)
	_build_ar_key()


## Game frame on a calibrated real keyboard: [Transform3D, station xs,
## octave width]. Stations sit just behind the white keys, one centred over
## each octave's seven white keys (so lanes one octave wide meet edge to
## edge); x runs along the keys (low → high), y up, −z away from the player.
static func ar_frame(lay: KeyboardLayout, low: int, high: int) -> Array:
	var ax := lay.axes()
	var along: Vector3 = ax[0]
	var up: Vector3 = ax[1]
	var back: Vector3 = ax[2]
	var behind := lay.white_width() * KeyboardLayout.WHITE_LEN + AR_GAP
	var row := lay.mid() + back * behind + up * 0.005
	var centres := {}
	for k in lay.keys():
		if not k["white"]:
			continue
		var o := DefenseRules.octave_of(int(k["midi"]))
		if not centres.has(o):
			centres[o] = []
		centres[o].append(k["center"])
	var xs: Array[float] = []
	for o in DefenseRules.station_octaves(low, high):
		var pts: Array = centres.get(o, [])
		var c := Vector3.ZERO
		for p in pts:
			c += p
		c /= maxf(1.0, float(pts.size()))
		xs.append((c - row).dot(along))
	return [Transform3D(Basis(along, up, -back), row), xs, lay.white_width() * 7.0]


## AR: the pin colour key lies on the table right of the highest station,
## tilted like the station labels so it reads from above.
func _build_ar_key() -> void:
	if _ar_key:
		_ar_key.queue_free()
		_ar_key = null
	if not use_inversions:
		return
	_ar_key = Node3D.new()
	add_child(_ar_key)
	var x := (station_x(octaves.size() - 1) if not octaves.is_empty() else 0.0) + lane_width * 0.5 + 0.06
	_ar_key.position = Vector3(x, 0.004, 0.02)
	var rows := [["INVERSION", Color(0.85, 0.88, 1.0)]]
	for i in 4:
		rows.append(["● " + ["root", "1st", "2nd", "3rd"][i], DefenseAttacker.inversion_color(i)])
	for k in rows.size():
		var l := Label3D.new()
		l.font = UITheme.ui_font()
		l.text = rows[k][0]
		l.font_size = 48
		l.pixel_size = 0.0006
		l.outline_size = 10
		l.outline_modulate = Color(0.02, 0.02, 0.05, 0.9)
		l.modulate = rows[k][1]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.no_depth_test = true
		l.rotation_degrees = Vector3(-60, 0, 0)
		# First row farthest away: it reads top-down from above.
		l.position = Vector3(0, 0, -0.05 * (rows.size() - 1 - k))
		_ar_key.add_child(l)


## Turns inversions on/off. New attackers follow at once; the start-screen
## samples and the AR colour key update.
func set_use_inversions(on: bool) -> void:
	use_inversions = on
	if in_ar:
		_build_ar_key()
	if state == State.IDLE or state == State.OVER:
		if not is_running() and _showcase.size() > 0:
			show_showcase()


func exit_ar() -> void:
	in_ar = false
	lane_width = DESKTOP_LANE_W
	if _ar_key:
		_ar_key.queue_free()
		_ar_key = null
	station_xs.clear()
	transform = Transform3D.IDENTITY
	if desktop_view and _backdrop == null:
		_build_backdrop()
	configure(range_low, range_high)


## Stations still standing in enabled octaves (Settings "disabled_octaves"):
## only these are attacked, and the game ends when none are left.
func _alive_stations() -> Array[int]:
	var off: Array = Settings.get_value("disabled_octaves")
	var out: Array[int] = []
	for i in stations.size():
		if stations[i].alive and not off.has(octaves[i]):
			out.append(i)
	if out.is_empty() and not off.is_empty():
		# Every enabled octave lost (or none has a station): fall back to all.
		var any_enabled := false
		for o in octaves:
			if not off.has(o):
				any_enabled = true
		if not any_enabled:
			for i in stations.size():
				if stations[i].alive:
					out.append(i)
	return out


# --- game flow ----------------------------------------------------------

## `first_wave` > 1 is for testing later sectors.
func start(first_wave := 1) -> void:
	_clear_showcase()
	_clear_attackers()
	configure(range_low, range_high)
	rng.randomize()
	pool_entries = Settings.pool().entries() if use_pool else []
	wave = first_wave - 1
	score = 0
	streak = 0
	best_combo = 0
	kills = 0
	misfires = 0
	inv_right = 0
	inv_wrong = 0
	hits_taken = 0
	kill_ms.clear()
	_play_s = 0.0
	paused = false
	_next_wave()


func stop() -> void:
	_clear_attackers()
	state = State.IDLE
	show_showcase()
	paused = false
	hint_changed.emit([])
	_emit_hud()


func set_paused(on: bool) -> void:
	paused = on


func is_running() -> bool:
	return state in [State.INTRO, State.PLAYING, State.CLEAR]


func _next_wave() -> void:
	wave += 1
	plan = DefenseWaves.plan(wave)
	spawned = 0
	boss_spawned = false
	state = State.INTRO
	_state_t = 0.0
	_spawn_t = 0.0
	var sub := "Play each chord in the octave it attacks, in the inversion on its pin" if use_inversions \
			else "Play each chord with its lowest note in the octave it attacks"
	if plan["special"] != "":
		sub = DefenseWaves.SPECIAL_TEXT[plan["special"]]
	if plan["boss"]:
		sub = "Boss wave — a progression ship is coming!"
	# New sector: introduce its new chord types (shown on C) before they attack.
	_intro_s = INTRO_S
	var fresh := DefenseWaves.new_qualities(wave)
	if not fresh.is_empty() and pool_entries.is_empty():
		var syms := []
		var names := []
		for q in fresh:
			var c := Theory.make_chord("C", q)
			syms.append(c.pretty())
			names.append(Theory.QUALITIES[q]["spoken"])
		show_showcase(syms, [])
		sub = "New chords: " + ", ".join(names)
		_intro_s = INTRO_S + 2.5
	banner.emit("Wave %d · %s" % [wave, plan["sector"]], sub)
	_apply_sector_look()
	_emit_hud()


func _process(delta: float) -> void:
	if state == State.IDLE or state == State.OVER or paused:
		return
	_state_t += delta
	_play_s += delta
	match state:
		State.INTRO:
			if _state_t >= _intro_s:
				state = State.PLAYING
				_clear_showcase()
				banner.emit("", "")
		State.PLAYING:
			_spawn_step(delta)
			if _wave_done():
				_wave_cleared()
		State.CLEAR:
			if _state_t >= CLEAR_S:
				_next_wave()
	for a in attackers.duplicate():
		if state == State.OVER:
			return
		a.advance(delta)
		if is_instance_valid(a) and not a.dead and a.wants_jump():
			_jump(a)
	_update_threats()


func _wave_done() -> bool:
	var boss_ok: bool = not plan["boss"] or boss_spawned
	return spawned >= int(plan["count"]) and boss_ok and attackers.is_empty()


func _wave_cleared() -> void:
	state = State.CLEAR
	_state_t = 0.0
	var full := 0
	for s in stations:
		if s.alive and s.shields == DefenseRules.SHIELDS:
			full += 1
	var bonus := DefenseRules.wave_bonus(wave, full)
	score += bonus
	# One repair for the most damaged surviving station.
	var worst: DefenseStation = null
	for s in stations:
		if s.alive and s.shields < DefenseRules.SHIELDS and (worst == null or s.shields < worst.shields):
			worst = s
	var rep := ""
	if worst:
		worst.repair()
		rep = "   ·   C%d repaired" % worst.octave
	banner.emit("Wave %d cleared!" % wave, "+%d bonus%s" % [bonus, rep])
	sfx.fanfare([60, 64, 67, 72] if wave % 2 == 1 else [62, 66, 69, 74])
	hint_changed.emit([])
	_emit_hud()


func _end_game() -> void:
	state = State.OVER
	_clear_attackers()
	hint_changed.emit([])
	var acc := float(kills) / maxf(1.0, float(kills + misfires))
	var avg := 0
	var fastest := 0
	if not kill_ms.is_empty():
		var tot := 0
		fastest = kill_ms[0]
		for m in kill_ms:
			tot += m
			fastest = mini(fastest, m)
		avg = tot / kill_ms.size()
	var summary := {
		"name": str(Settings.get_value("player_name")), "score": score, "wave": wave, "kills": kills,
		"misfires": misfires, "hits_taken": hits_taken, "accuracy": acc, "best_combo": best_combo,
		"avg_ms": avg, "fastest_ms": fastest, "play_s": _play_s, "stations": stations.size(),
		"inv_right": inv_right, "inv_wrong": inv_wrong, "inversions": use_inversions,
	}
	summary["rank"] = records.add_game(stations.size(), summary)
	summary["nemesis"] = records.nemesis_chords(3)
	summary["board"] = records.top(stations.size())
	summary["lifetime"] = records.lifetime.duplicate()
	records.save()
	if stats:
		stats.save()
	leaderboard.submit(stations.size(), summary)
	banner.emit("Game over", "Score %d · wave %d" % [score, wave])
	game_over.emit(summary)
	_emit_hud()


# --- start screen: chord shapes ------------------------------------------

var _showcase: Array[DefenseAttacker] = []


## Before a game: a row of sample ships so the player can learn the
## inversion rings (C in root position, 1st and 2nd inversion; G7 in 3rd).
## `invs`: inversion per ship (default root position).
func show_showcase(syms: Array = ["C", "C", "C", "G7"], invs: Array = [0, 1, 2, 3]) -> void:
	if not use_inversions and invs == [0, 1, 2, 3]:
		# No inversions: show a few chord types in root position instead.
		syms = ["C", "Cm", "G7", "Am7"]
		invs = []
	_clear_showcase()
	var span := minf(0.92, 0.16 * (syms.size() - 1))
	for i in syms.size():
		var a := DefenseAttacker.new()
		_field.add_child(a)
		a.setup("drifter", [Theory.parse_chord(syms[i])], 0, 0.0, 99.0, rng, [invs[i] if i < invs.size() else 0])
		# Alternate heights so neighbouring plates don't touch.
		var f := 0.5 if syms.size() == 1 else float(i) / (syms.size() - 1)
		a.position = Vector3(lerpf(-span * 0.5, span * 0.5, f), 0.075 + 0.045 * (i % 2), -0.1)
		a.set_show_notes(true)
		a.set_urgency(0.0, false)
		a.set_drop_visible(false)
		_showcase.append(a)


func _clear_showcase() -> void:
	for a in _showcase:
		if is_instance_valid(a):
			a.queue_free()
	_showcase.clear()


# --- spawning -----------------------------------------------------------

func _spawn_step(delta: float) -> void:
	_spawn_t -= delta
	if _spawn_t > 0.0 or attackers.size() >= mini(int(plan["max_alive"]), _alive_stations().size() + 1):
		return
	if plan["boss"] and not boss_spawned and spawned >= int(plan["count"]) / 2:
		_spawn_boss()
		boss_spawned = true
		_spawn_t = float(plan["interval"]) * 1.5
		return
	if spawned >= int(plan["count"]):
		return
	var special: String = plan["special"]
	if special != "" and int(plan["count"]) - spawned >= 3 and rng.randf() < float(plan["special_chance"]):
		spawned += _spawn_special(special)
		_spawn_t = float(plan["interval"]) * 1.8
		return
	var kind := DefenseWaves.pick_weighted(plan["types"], rng)
	if _spawn(kind):
		spawned += 1
	_spawn_t = float(plan["interval"]) * rng.randf_range(0.8, 1.2)


func _random_chord(qualities: Array, octave: int) -> Theory.Chord:
	for attempt in 30:
		var c: Theory.Chord
		if not pool_entries.is_empty():
			c = pool_entries[rng.randi() % pool_entries.size()]["chord"]
		else:
			var root: String = Theory.DEFAULT_ROOTS[rng.randi() % Theory.DEFAULT_ROOTS.size()]
			c = Theory.make_chord(root, qualities[rng.randi() % qualities.size()])
		if c and not DefenseRules.voicing_in_octave(c, octave, range_high).is_empty():
			return c
	return null


## Stations whose lane has room for a new ship (its last ship has moved
## well in), so ships in one lane don't stack up at the horizon.
func _open_stations() -> Array[int]:
	var out: Array[int] = []
	for i in _alive_stations():
		var ok := true
		for a in attackers:
			if a.station == i and a.t < 0.3:
				ok = false
		if ok:
			out.append(i)
	return out


func _spawn(kind: String) -> bool:
	var alive := _open_stations()
	if alive.is_empty():
		return false
	var si: int = alive[rng.randi() % alive.size()]
	var qs: Array = plan["qualities"]
	if kind == "missile":
		qs = qs.filter(func(q): return Theory.QUALITIES[q]["tones"].size() == 3)
		if qs.is_empty():
			qs = ["maj", "min"]
	var c := _random_chord(qs, octaves[si])
	if c == null:
		return false
	_add_attacker(kind, [c], si, float(plan["travel"]))
	return true


## Spawns a group for the wave's special event. Returns how many spawned.
func _spawn_special(special: String) -> int:
	var alive := _alive_stations()
	if alive.size() < 2:
		return 1 if _spawn("drifter") else 0
	var travel := float(plan["travel"])
	match special:
		"echo":
			# One chord, two or three octaves.
			alive.shuffle()
			var n := mini(alive.size(), 2 + (1 if wave >= 6 else 0))
			var picks := alive.slice(0, n)
			for attempt in 20:
				var c := _random_chord(plan["qualities"], octaves[picks[0]])
				if c == null:
					continue
				var ok := true
				for si in picks:
					ok = ok and not DefenseRules.voicing_in_octave(c, octaves[si], range_high).is_empty()
				if ok:
					for k in picks.size():
						_add_attacker("drifter", [c], picks[k], travel * (1.0 + 0.12 * k))
					return picks.size()
			return 1 if _spawn("drifter") else 0
		"formation":
			var start: int = rng.randi_range(0, maxi(0, stations.size() - 3))
			var n := 0
			for si in range(start, mini(start + 3, stations.size())):
				if _alive_stations().has(si):
					var c := _random_chord(plan["qualities"], octaves[si])
					if c:
						_add_attacker("drifter", [c], si, travel)
						n += 1
			return maxi(n, 1)
		"salvo":
			var n := 0
			for k in 3:
				get_tree().create_timer(0.45 * k, false).timeout.connect(func():
					if state == State.PLAYING:
						_spawn("missile"))
				n += 1
			return n
	return 0


func _spawn_boss() -> void:
	var alive := _alive_stations()
	if alive.is_empty():
		return
	# Prefer a middle station: bosses are big and slow.
	alive.sort_custom(func(a, b): return absf(station_x(a)) < absf(station_x(b)))
	var si: int = alive[0]
	for attempt in 20:
		var prog: Dictionary = DefenseWaves.PROGRESSIONS[rng.randi() % DefenseWaves.PROGRESSIONS.size()]
		var tonic := Theory.parse_note(Theory.DEFAULT_ROOTS[rng.randi() % 12])
		var cs := DefenseWaves.progression_chords(prog, tonic)
		var ok := true
		for c in cs:
			if DefenseRules.voicing_in_octave(c, octaves[si], range_high).is_empty():
				ok = false
		if ok:
			_add_attacker("boss", cs, si, float(plan["travel"]))
			feedback.emit("Progression ship: %s in %s — play its chords in order" % [prog["name"], tonic.pretty()], Color(1, 0.8, 0.4))
			return


func _add_attacker(kind: String, cs: Array, si: int, travel: float) -> void:
	var a := DefenseAttacker.new()
	_field.add_child(a)
	a.show_notes = show_notes
	var invs := []
	for c in cs:
		invs.append(DefenseRules.pick_inversion(c, octaves[si], range_high, rng) if use_inversions else 0)
	a.setup(kind, cs, si, station_x(si), travel, rng, invs)
	a.set_path(-FIELD_DEPTH, TOP_Y, rng)
	a.spawned_ms = _ms()
	a.reached_station.connect(_on_reached)
	attackers.append(a)
	a.warp_in()
	if kind == "boss":
		a.scale = Vector3.ONE


func _jump(a: DefenseAttacker) -> void:
	a.did_jump()
	var alive := _alive_stations()
	var options: Array[int] = []
	for i in alive:
		if i != a.station and absi(i - a.station) <= 2 \
				and not DefenseRules.voicing_in_octave(a.chord(), octaves[i], range_high, a.inversion(), true).is_empty():
			options.append(i)
	if options.is_empty():
		return
	var ni: int = options[rng.randi() % options.size()]
	a.retarget(ni, station_x(ni))


func _clear_attackers() -> void:
	for a in attackers:
		if is_instance_valid(a):
			a.queue_free()
	attackers.clear()


func _ms() -> int:
	return roundi(_play_s * 1000.0)


# --- hits ---------------------------------------------------------------

func _on_reached(a: DefenseAttacker) -> void:
	if a.dead or state == State.OVER:
		return
	a.dead = true
	attackers.erase(a)
	var st := stations[a.station]
	var dmg := 2 if a.kind == "boss" else 1
	var lost := st.hit(dmg)
	hits_taken += 1
	streak = 0
	records.record_escape(a.chord().key())
	if stats:
		stats.record(a.chord().key(), "defense", false, _ms() - a.spawned_ms, {"escaped": true})
	_explode(a.global_position, [Color(1, 0.3, 0.2), Color(1, 0.7, 0.2)], 1.4)
	sfx.play("hit", 2.0 if lost else 0.0)
	_shake(0.012 if lost else 0.006)
	a.queue_free()
	feedback.emit("Station C%d–B%d hit by the %s chord%s" % [st.octave, st.octave, a.chord().pretty(), " — station lost!" if lost else ""], Color(1, 0.4, 0.35))
	if _alive_stations().is_empty():
		_end_game()
		return
	if lost:
		# Attackers heading for a lost station pick another lane.
		for o in attackers:
			if o.station == a.station:
				_jump_forced(o)
	_emit_hud()


func _jump_forced(a: DefenseAttacker) -> void:
	var alive := _alive_stations()
	alive.sort_custom(func(x, y): return absi(x - a.station) < absi(y - a.station))
	for i in alive:
		if not DefenseRules.voicing_in_octave(a.chord(), octaves[i], range_high).is_empty():
			a.retarget(i, station_x(i))
			return
	a.retarget(alive[0], station_x(alive[0]))


# --- input --------------------------------------------------------------

func _targets() -> Array:
	var out := []
	for a in attackers:
		if not a.dead:
			out.append({"id": a.get_instance_id(), "chord": a.chord(), "octave": octaves[a.station], "progress": a.t})
	return out


func _on_note_on(_pitch: int, _velocity: int) -> void:
	if state != State.PLAYING or paused:
		return
	var held := Midi.held_notes()
	var r := DefenseRules.judge(held, _targets())
	match r["kind"]:
		"kill":
			_kill(instance_from_id(r["id"]) as DefenseAttacker, held)
		"wrong_octave":
			var a := instance_from_id(r["id"]) as DefenseAttacker
			misfires += 1
			streak = 0
			sfx.play("misfire")
			var oc := octaves[a.station]
			feedback.emit("Right chord, wrong octave — %s attacks C%d: lowest note between C%d and B%d" % [a.chord().pretty(), oc, oc, oc], Color(1, 0.75, 0.3))
			_emit_hud()
		"misfire":
			misfires += 1
			sfx.play("misfire")
			if streak >= DefenseRules.COMBO_STEP:
				feedback.emit("Misfire — combo lost", Color(1, 0.45, 0.4))
			else:
				feedback.emit("Misfire", Color(1, 0.45, 0.4))
			streak = 0
			_emit_hud()


func _on_held_changed(held: Array) -> void:
	var pcs := DefenseRules.pc_set(held)
	for a in attackers:
		if DefenseRules.partial_of(held, a.chord()):
			a.show_held(pcs)
		else:
			a.show_held({})


func _kill(a: DefenseAttacker, held: Array = []) -> void:
	if a == null or a.dead:
		return
	var ms := _ms() - a.spawned_ms
	# Right inversion: full points. Another inversion still destroys it,
	# for half the points and a duller, broken-ring effect.
	var played := DefenseRules.held_inversion(held, a.chord()) if not held.is_empty() else a.inversion()
	var right := played == a.inversion() or not use_inversions
	if use_inversions:
		if right:
			inv_right += 1
		else:
			inv_wrong += 1
	var pts := DefenseRules.kill_points(a.chord(), a.t, streak, right)
	score += pts
	streak += 1
	best_combo = maxi(best_combo, streak)
	kills += 1
	kill_ms.append(ms)
	records.record_kill(a.chord().key(), ms)
	if stats:
		stats.record(a.chord().key(), "defense", true, ms, {"octave": octaves[a.station]})
	var st := stations[a.station]
	sfx.play("zap")
	sfx.play("boom", -6.0)
	_beam(st.global_position + Vector3(0, 0.03, 0), a.global_position, a.orb_colors())
	var mult := DefenseRules.combo_multiplier(streak)
	var mult_text := "   ×%d" % mult if mult > 1 else ""
	var at := a.global_position
	var ring_col := DefenseAttacker.inversion_color(a.inversion())
	var ring_r := a.ring_radius()
	var colors := a.orb_colors()
	var fb_col := Color(0.4, 1, 0.6)
	var inv_note := ""
	if right:
		_pop_text("+%d" % pts, at, Color(1, 0.9, 0.4) if mult > 1 else Color(0.6, 1, 0.7))
	else:
		_pop_text("½  +%d" % pts, at, Color(1, 0.62, 0.3))
		var wanted := Theory.inversion_name(a.inversion()) if a.inversion() > 0 else "root position"
		var got := Theory.inversion_name(played) if played > 0 else "root position"
		inv_note = " — wrong inversion (wanted %s, played %s): half points" % [wanted, got]
		fb_col = Color(1, 0.7, 0.35)
	# Right inversion: bright explosion. Wrong: the ring shatters.
	var burst := func(size: float) -> void:
		if right:
			_explode(at, colors, size)
		else:
			_shatter(at, ring_col, ring_r)
	if a.kind == "boss":
		burst.call(0.8)
		if not a.next_segment():
			feedback.emit("%s down%s! Next: %s  +%d%s" % [a.chords[a.segment - 1].pretty(), inv_note, a.chord().pretty(), pts, mult_text], fb_col)
			_emit_hud()
			return
		score += 1000
		var notes: Array = []
		for c in a.chords:
			notes.append(DefenseRules.voicing_in_octave(c, octaves[a.station], range_high)[0])
		sfx.fanfare(notes)
		feedback.emit("Progression ship destroyed!  +%d%s" % [pts + 1000, inv_note], fb_col)
		_explode(at, colors + [Color(1, 1, 1)], 2.2)
	else:
		feedback.emit("%s  +%d%s%s" % [a.chord().pretty(), pts, mult_text, inv_note], fb_col)
		burst.call(1.0)
	a.dead = true
	attackers.erase(a)
	a.queue_free()
	_emit_hud()


# --- per-frame presentation ---------------------------------------------

func _update_threats() -> void:
	var threat := []
	threat.resize(stations.size())
	threat.fill(0.0)
	var top: DefenseAttacker = null
	for a in attackers:
		threat[a.station] = maxf(threat[a.station], a.t)
		if top == null or a.t > top.t:
			top = a
	for i in stations.size():
		stations[i].set_threat(threat[i])
	var training: bool = int(records.lifetime["games"]) == 0 and wave == 1
	var hinting := show_hints or training
	# Keys hint sticks to one attacker until it's gone, then takes the
	# closest one; the target ring marks whichever chord the keys show.
	if not hinting:
		_hint_target = null
	elif not hint_target_alive():
		_hint_target = top
	var focus: DefenseAttacker = _hint_target if hinting and _hint_target else top
	for a in attackers:
		a.set_urgency(a.t, a == focus)
	_declutter_plates()
	var key := ""
	var v: Array = []
	if hinting and _hint_target:
		var h := _hint_target
		key = "%s@%d:%d#%d" % [h.chord().key(), h.station, h.inversion(), h.get_instance_id()]
		if key != _hint_key:
			v = DefenseRules.voicing_in_octave(h.chord(), octaves[h.station], range_high, h.inversion())
	if key != _hint_key:
		_hint_key = key
		hint_changed.emit(v)


## Keeps name plates from overlapping on screen: the most urgent plates are
## placed first, and any later plate that would overlap is lifted above.
func _declutter_plates() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or attackers.size() < 2:
		for a in attackers:
			a.plate_lift = 0.0
		return
	var vp_h := get_viewport().get_visible_rect().size.y
	var tan_half := tan(deg_to_rad(cam.fov) * 0.5)
	var order := attackers.duplicate()
	order.sort_custom(func(x, y): return x.t > y.t)
	var placed: Array[Rect2] = []
	for a in order:
		var anchor: Vector3 = a.plate_anchor()
		if cam.is_position_behind(anchor):
			continue
		var p := cam.unproject_position(anchor)
		# Fixed-size label: on-screen height doesn't depend on distance.
		var h: float = DefenseAttacker.PLATE_PX * a.plate_scale * 64.0 * vp_h / (2.0 * tan_half) * 0.82
		var w: float = h * 0.58 * maxf(1.0, a.plate_text().length())
		var r := Rect2(p.x - w * 0.5, p.y - h, w, h)
		var lift_px := 0.0
		for tries in 6:
			var hit := false
			for o in placed:
				if r.grow(2.0).intersects(o):
					var dy := r.end.y - o.position.y + 3.0
					r.position.y -= dy
					lift_px += dy
					hit = true
					break
			if not hit:
				break
		placed.append(r)
		var dist := cam.global_position.distance_to(anchor)
		var lift := lift_px / vp_h * 2.0 * dist * tan_half
		a.plate_lift = lerpf(a.plate_lift, lift, 0.45)


func set_show_notes(on: bool) -> void:
	show_notes = on
	for a in attackers:
		a.set_show_notes(on)


func hint_target_alive() -> bool:
	return _hint_target != null and is_instance_valid(_hint_target) \
			and not _hint_target.dead and attackers.has(_hint_target)


func set_show_hints(on: bool) -> void:
	show_hints = on
	_hint_key = "-"


func _emit_hud() -> void:
	var alive := 0
	for s in stations:
		if s.alive:
			alive += 1
	hud_changed.emit({
		"score": score, "wave": wave, "sector": plan.get("sector", ""), "combo": DefenseRules.combo_multiplier(streak),
		"streak": streak, "kills": kills, "stations": alive, "stations_total": stations.size(),
		"best": int(records.lifetime["best_score"]), "running": is_running(),
	})


# --- effects ------------------------------------------------------------

func _beam(from: Vector3, to: Vector3, colors: Array) -> void:
	for k in colors.size():
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0025
		cm.bottom_radius = 0.0025
		var d := from.distance_to(to)
		cm.height = d
		cm.radial_segments = 6
		cm.rings = 1
		mi.mesh = cm
		var col: Color = colors[k]
		var m := DefenseAttacker._flat(Color(col, 0.9))
		mi.material_override = m
		_fx.add_child(mi)
		var off := Vector3((k - (colors.size() - 1) * 0.5) * 0.006, 0, 0)
		mi.global_position = (from + to) * 0.5 + off
		var dir := (to - from).normalized()
		mi.global_basis = Basis(Quaternion(Vector3.UP, dir))
		var tw := create_tween()
		tw.tween_property(m, "albedo_color:a", 0.0, 0.35)
		tw.tween_callback(mi.queue_free)


func _explode(at: Vector3, colors: Array, size := 1.0) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = int(36 * size)
	p.lifetime = 0.8
	p.explosiveness = 1.0
	p.spread = 180.0
	p.direction = Vector3.UP
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 0.12 * size
	p.initial_velocity_max = 0.35 * size
	p.damping_min = 0.2
	p.damping_max = 0.4
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var sm := SphereMesh.new()
	sm.radius = 0.0035
	sm.height = 0.007
	sm.radial_segments = 6
	sm.rings = 3
	p.mesh = sm
	var mat := DefenseAttacker._flat(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	p.material_override = mat
	var g := Gradient.new()
	g.colors = PackedColorArray(colors.map(func(c): return c) if colors.size() >= 2 else [colors[0], colors[0]])
	p.color_initial_ramp = g
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	p.color_ramp = fade
	_fx.add_child(p)
	p.global_position = at
	p.emitting = true
	# Shock ring.
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.018
	tm.outer_radius = 0.022
	ring.mesh = tm
	var rm := DefenseAttacker._flat(Color(colors[0], 0.8))
	ring.material_override = rm
	ring.rotation.x = PI / 2
	_fx.add_child(ring)
	ring.global_position = at
	var tw := create_tween().set_parallel()
	tw.tween_property(ring, "scale", Vector3.ONE * 4.0 * size, 0.45)
	tw.tween_property(rm, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(func():
		ring.queue_free()
		p.queue_free())


## Wrong-inversion kill: the ring cracks into dull shards that drift apart
## and fade, with a few grey sparks (no bright explosion).
func _shatter(at: Vector3, color: Color, r: float) -> void:
	var dull := color.lerp(Color(0.55, 0.55, 0.6), 0.55)
	var n := 8
	for i in n:
		var ang := TAU * (i + 0.5) / n
		var shard := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(TAU * r / n * 0.8, r * 0.16, r * 0.08)
		shard.mesh = bm
		var m := DefenseAttacker._flat(Color(dull, 0.9))
		shard.material_override = m
		_fx.add_child(shard)
		var out := Vector3(cos(ang), sin(ang), 0.0)
		shard.global_position = at + out * r
		shard.rotation.z = ang + PI / 2
		var tw := create_tween().set_parallel()
		tw.tween_property(shard, "global_position", at + out * r * 1.9 + Vector3.DOWN * r * 0.8, 0.6).set_ease(Tween.EASE_OUT)
		tw.tween_property(shard, "rotation:z", shard.rotation.z + randf_range(-1.5, 1.5), 0.6)
		tw.tween_property(m, "albedo_color:a", 0.0, 0.6)
		tw.chain().tween_callback(shard.queue_free)
	_explode(at, [Color(0.6, 0.6, 0.65), dull], 0.45)


## Floating score text that rises and fades where a chord was destroyed.
func _pop_text(text: String, at: Vector3, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font = UITheme.ui_font()
	l.font_size = 48
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0.05, 0.9)
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.no_depth_test = true
	l.render_priority = 12
	_fx.add_child(l)
	l.global_position = at
	var tw := create_tween().set_parallel()
	tw.tween_property(l, "position:y", l.position.y + 0.08, 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(l, "modulate:a", 0.0, 0.9).set_delay(0.3)
	tw.tween_property(l, "outline_modulate:a", 0.0, 0.9).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


## Desktop: a short camera shake when a station is hit.
func _shake(amount: float) -> void:
	if camera == null:
		return
	var base := camera.position
	var tw := create_tween()
	for k in 6:
		tw.tween_property(camera, "position", base + Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * amount, 0.04)
	tw.tween_property(camera, "position", base, 0.05)


# --- desktop backdrop ---------------------------------------------------

func _build_backdrop() -> void:
	_backdrop = Node3D.new()
	add_child(_backdrop)
	_world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.02, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.6)
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.15
	_world_env.environment = env
	_backdrop.add_child(_world_env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 20, 0)
	_backdrop.add_child(light)
	# Stars.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var sm := SphereMesh.new()
	sm.radius = 0.004
	sm.height = 0.008
	sm.radial_segments = 4
	sm.rings = 2
	mm.mesh = sm
	mm.instance_count = 420
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in mm.instance_count:
		var pos := Vector3(r.randf_range(-3.5, 3.5), r.randf_range(-0.4, 2.4), r.randf_range(-4.5, -1.6))
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * r.randf_range(0.5, 2.2)), pos))
		mm.set_instance_color(i, Color(1, 1, 1).lerp(Color(0.6, 0.7, 1.0), r.randf()) * r.randf_range(0.5, 1.0))
	_stars = MultiMeshInstance3D.new()
	_stars.multimesh = mm
	var smat := DefenseAttacker._flat(Color.WHITE)
	smat.vertex_color_use_as_albedo = true
	_stars.material_override = smat
	_backdrop.add_child(_stars)
	# Floor grid.
	var grid := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in range(-20, 21):
		var x := k * 0.1
		im.surface_add_vertex(Vector3(x, -0.002, 0.3))
		im.surface_add_vertex(Vector3(x, -0.002, -FIELD_DEPTH - 0.4))
	for k in range(-3, int(FIELD_DEPTH / 0.1) + 5):
		var z := -k * 0.1
		im.surface_add_vertex(Vector3(-2.0, -0.002, z))
		im.surface_add_vertex(Vector3(2.0, -0.002, z))
	im.surface_end()
	grid.mesh = im
	_grid_mat = DefenseAttacker._flat(Color(0.3, 0.35, 0.8, 0.18))
	grid.material_override = _grid_mat
	_backdrop.add_child(grid)
	# Nebulae: big soft glows far behind the field, tinted per sector.
	var tex := GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0)])
	tex.gradient = g
	var spots := [Vector3(-1.4, 0.9, -4.0), Vector3(1.6, 1.3, -4.3), Vector3(0.2, 0.5, -4.6)]
	for k in spots.size():
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(3.2, 2.2) * (1.0 + 0.3 * k)
		q.mesh = qm
		var m := DefenseAttacker._flat(Color(1, 1, 1, 0.5))
		m.albedo_texture = tex
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		q.material_override = m
		q.position = spots[k]
		_backdrop.add_child(q)
		_nebulae.append(q)
	camera = Camera3D.new()
	camera.current = true
	_backdrop.add_child(camera)


func _apply_sector_look() -> void:
	if _world_env == null:
		return
	var sec := DefenseWaves.sector_for(maxi(1, wave))
	_world_env.environment.background_color = sec["sky"]
	var accent: Color = sec["accent"]
	if _grid_mat:
		_grid_mat.albedo_color = Color(accent, 0.16)
	for k in _nebulae.size():
		var c := accent.lerp(Color(sec["sky"]).lightened(0.4), 0.35 * k)
		(_nebulae[k].material_override as StandardMaterial3D).albedo_color = Color(c, 0.2)


func _place_camera() -> void:
	if camera == null:
		return
	# Frame the whole field vertically (station row to the far top), then
	# widen if the stations don't fit across.
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.position = Vector3(0, 0.38, 0.55)
	camera.look_at(Vector3(0, 0.05, -0.55))
	var vfov := 46.0
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(1.0, size.y)
	var half_w := octaves.size() * OCTAVE_W * 0.5 + 0.08
	var need_h := rad_to_deg(2.0 * atan(half_w / 0.67))          # horizontal fov needed
	var need_v := rad_to_deg(2.0 * atan(tan(deg_to_rad(need_h) * 0.5) / maxf(0.5, aspect)))
	camera.fov = clampf(maxf(vfov, need_v), 40.0, 100.0)
