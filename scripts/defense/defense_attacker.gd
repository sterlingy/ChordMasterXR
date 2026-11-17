class_name DefenseAttacker
extends Node3D
## One attacking chord. Its hull is the chord's shape on the 12-note
## circle (root at the top), so every chord quality has its own silhouette:
## major and minor triads are mirror images, augmented is an equilateral
## triangle, dim7 is a square. A glowing orb sits on each chord tone,
## coloured by its job in the chord, and lights up while you hold that
## note. The name plate always faces you and is drawn on top.
##
## Movement is a progress value t (0 = just arrived, 1 = hits its station)
## along a path that depends on `kind`. The game owns lanes/stations and
## tells the attacker where they are.

signal reached_station(attacker: DefenseAttacker)

const KINDS := ["drifter", "jumper", "diver", "missile", "boss"]
## Name plate size (Label3D fixed_size pixel size): big enough to read at a glance.
const PLATE_PX := 0.0014

var kind := "drifter"
var chords: Array = []              # Theory.Chord; bosses carry several
var segment := 0                    # boss: which chord is current
var station := 0                    # index of the station it attacks
var t := 0.0                        # 0..1 progress to the station
var travel := 14.0                  # seconds from spawn to station
var spawned_ms := 0
var radius := 0.03
var dead := false

var lane_x := 0.0                   # x of the target station (animated)
var _lane_from := 0.0
var _lane_to := 0.0
var _lane_t := 1.0
var start_pos := Vector3.ZERO
var end_pos := Vector3.ZERO
var _ctrl := Vector3.ZERO           # diver bezier control point
var _side := 1.0
var _jumps: Array = []              # t values where a jumper changes lane
var _clock := 0.0
var _spin := 0.0

var _hull: Node3D
var _orbs := {}                     # pc -> MeshInstance3D
var _orb_mats := {}                 # pc -> StandardMaterial3D
var _plate: Label3D
var _notes_plate: Label3D
var _next_plate: Label3D
var _drop: MeshInstance3D            # line from the ship down to its lane
var _drop_mesh: CylinderMesh
var _marker: MeshInstance3D          # ring on the lane under the ship
var _base_color := Color.WHITE
var show_notes := false
var urgent := false


static func family_color(quality: String) -> Color:
	match quality:
		"maj", "6", "maj7", "add9", "maj9":
			return Color(0.25, 0.9, 0.75)
		"min", "m6", "m7", "m9", "mmaj7":
			return Color(0.5, 0.55, 1.0)
		"7", "9", "7sus4":
			return Color(1.0, 0.75, 0.25)
		"dim", "m7b5", "dim7":
			return Color(1.0, 0.3, 0.38)
		"aug":
			return Color(1.0, 0.5, 0.15)
		"sus2", "sus4":
			return Color(0.65, 0.95, 1.0)
	return Color(0.8, 0.8, 0.9)


## Colour of a chord tone by its interval above the root.
static func role_color(semis: int) -> Color:
	match posmod(semis, 12):
		0: return Color(1, 1, 1)                 # root
		3: return Color(0.35, 0.55, 1.0)         # minor 3rd
		4: return Color(0.35, 1.0, 0.5)          # major 3rd
		7: return Color(0.75, 0.45, 1.0)         # 5th
		6, 8: return Color(1.0, 0.55, 0.2)       # altered 5th
		9: return Color(0.55, 0.95, 0.45)        # 6th / dim 7th
		10, 11: return Color(1.0, 0.85, 0.25)    # 7th
		2, 5: return Color(0.4, 0.95, 1.0)       # 9th / sus
	return Color(0.9, 0.9, 0.9)


func chord() -> Theory.Chord:
	return chords[mini(segment, chords.size() - 1)]


func setup(p_kind: String, p_chords: Array, p_station: int, p_lane_x: float, p_travel: float, rng: RandomNumberGenerator) -> void:
	kind = p_kind
	chords = p_chords
	station = p_station
	travel = p_travel
	lane_x = p_lane_x
	_lane_from = p_lane_x
	_lane_to = p_lane_x
	radius = {"missile": 0.03, "boss": 0.075}.get(kind, 0.045)
	match kind:
		"missile":
			travel *= 0.55
		"boss":
			travel *= 1.7
		"jumper":
			_jumps = [rng.randf_range(0.25, 0.4), rng.randf_range(0.55, 0.7)]
		"diver":
			_side = -1.0 if rng.randf() < 0.5 else 1.0
	_spin = rng.randf_range(-0.6, 0.6)
	_build()


## Where the attacker starts and ends; called by the game after setup.
func set_path(far_z: float, top_y: float, rng: RandomNumberGenerator) -> void:
	var h := top_y * rng.randf_range(0.75, 1.0)
	match kind:
		"missile":
			start_pos = Vector3(lane_x + rng.randf_range(-0.25, 0.25), top_y * 1.25, far_z)
		"diver":
			start_pos = Vector3(lane_x + _side * 0.7, h, far_z * 0.75)
			_ctrl = Vector3(lane_x + _side * 0.35, h * 1.2, far_z * 0.35)
		_:
			start_pos = Vector3(lane_x, h, far_z)
	end_pos = Vector3(lane_x, radius + 0.03, 0.0)
	position = start_pos


## The hull always faces the player with its root at the top, so the
## chord's silhouette reads the same everywhere (no spinning: major and
## minor are mirror images, and turning would blur that). A gentle bob
## keeps it alive.
func _process(_delta: float) -> void:
	if _hull == null:
		return
	var cam := get_viewport().get_camera_3d()
	var bob := sin(Time.get_ticks_msec() / 1000.0 * 2.2 + _spin * 10.0) * radius * 0.12
	_hull.position.y = bob
	if cam:
		var to_cam := cam.global_position - _hull.global_position
		if to_cam.length() > 0.001:
			var z := to_cam.normalized()
			var x := Vector3.UP.cross(z)
			if x.length() < 0.001:
				x = Vector3.RIGHT
			x = x.normalized()
			_hull.global_basis = Basis(x, z.cross(x), z).scaled(_hull.scale)


## Arrival effect: the ship scales up out of a flash.
func warp_in() -> void:
	_hull.scale = Vector3.ONE * 0.05
	var tw := create_tween()
	tw.tween_property(_hull, "scale", Vector3.ONE * 1.25, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_hull, "scale", Vector3.ONE, 0.15)
	var flash := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius * 1.4
	sm.height = radius * 2.8
	flash.mesh = sm
	var m := _flat(Color(_base_color.lightened(0.5), 0.7))
	flash.material_override = m
	add_child(flash)
	var tf := create_tween().set_parallel()
	tf.tween_property(flash, "scale", Vector3.ONE * 2.0, 0.35)
	tf.tween_property(m, "albedo_color:a", 0.0, 0.35)
	tf.chain().tween_callback(flash.queue_free)


## Moves the target lane (jumpers). The game picks the new station.
func retarget(p_station: int, x: float) -> void:
	station = p_station
	_lane_from = lane_x
	_lane_to = x
	_lane_t = 0.0


func wants_jump() -> bool:
	return not _jumps.is_empty() and t >= float(_jumps[0])


func did_jump() -> void:
	_jumps.pop_front()


func advance(delta: float) -> void:
	if dead:
		return
	_clock += delta
	var speed := 1.0 / travel
	if kind == "drifter" or kind == "boss":
		# Invader-style steps: move, hold, move, hold (same average speed).
		speed *= 2.0 if fmod(_clock, 1.2) < 0.6 else 0.0
	t = minf(1.0, t + delta * speed)
	if _lane_t < 1.0:
		_lane_t = minf(1.0, _lane_t + delta / 0.7)
		lane_x = lerpf(_lane_from, _lane_to, smoothstep(0.0, 1.0, _lane_t))
	position = _path(t)
	_update_drop()
	if t >= 1.0:
		reached_station.emit(self)


func _path(p: float) -> Vector3:
	var end := Vector3(lane_x, end_pos.y, 0.0)
	match kind:
		"diver":
			var e := p * p
			var a := start_pos.lerp(_ctrl, e)
			var b := _ctrl.lerp(end, e)
			return a.lerp(b, e)
		"missile":
			return start_pos.lerp(end, p)
		_:
			var s := Vector3(lane_x, start_pos.y, start_pos.z)
			var sway := Vector3(sin(_clock * 1.7) * 0.012, 0, 0) if kind == "drifter" else Vector3.ZERO
			return s.lerp(end, p) + sway * (1.0 - p)


# --- visuals ------------------------------------------------------------

func _build() -> void:
	_base_color = family_color(chord().quality)
	_hull = Node3D.new()
	add_child(_hull)
	_rebuild_hull()
	if kind == "missile":
		_add_trail()
	if kind == "boss":
		_build_boss_pips()
	_plate = _label(64, Color(1, 1, 1))
	_plate.position = Vector3(0, radius * 1.15 + 0.012, 0)
	_plate.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_notes_plate = _label(30, Color(1, 0.82, 0.45))
	_notes_plate.position = Vector3(0, -radius * 1.15 - 0.008, 0)
	_notes_plate.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if kind == "boss":
		_next_plate = _label(30, Color(0.75, 0.78, 0.9))
		_next_plate.position = Vector3(0, -radius * 1.15 - 0.008, 0)
		_next_plate.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_refresh_text()
	# Drop line + lane marker: shows which station (octave) it is attacking.
	_drop_mesh = CylinderMesh.new()
	_drop_mesh.top_radius = 0.0012
	_drop_mesh.bottom_radius = 0.0012
	_drop_mesh.radial_segments = 4
	_drop_mesh.rings = 1
	_drop = MeshInstance3D.new()
	_drop.mesh = _drop_mesh
	_drop.material_override = _flat(Color(_base_color, 0.45))
	add_child(_drop)
	_marker = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.022
	tm.outer_radius = 0.028
	tm.rings = 24
	tm.ring_segments = 3
	_marker.mesh = tm
	_marker.material_override = _flat(Color(_base_color, 0.7))
	add_child(_marker)
	_update_drop()


func set_drop_visible(on: bool) -> void:
	if _drop:
		_drop.visible = on
		_marker.visible = on


func _update_drop() -> void:
	if _drop == null:
		return
	var h := maxf(0.001, position.y)
	_drop_mesh.height = h
	_drop.position = Vector3(0, -h * 0.5, 0)
	_marker.position = Vector3(0, -h + 0.002, 0)


func _label(size_px: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.font = UITheme.ui_font()
	l.font_size = size_px
	l.outline_size = maxi(8, size_px / 4)
	l.outline_modulate = Color(0.02, 0.02, 0.05, 0.95)
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = PLATE_PX
	l.no_depth_test = true
	l.render_priority = 10
	l.outline_render_priority = 9
	add_child(l)
	return l


func _rebuild_hull() -> void:
	for c in _hull.get_children():
		c.queue_free()
	_orbs.clear()
	_orb_mats.clear()
	var ch := chord()
	var semis := ch.semitones()
	var pcs := ch.pitch_classes()
	var pts := PackedVector2Array()
	var order := []
	for i in semis.size():
		order.append([posmod(semis[i], 12), i])
	order.sort_custom(func(a, b): return a[0] < b[0])
	for o in order:
		var a := float(o[0]) / 12.0 * TAU
		pts.append(Vector2(sin(a), cos(a)) * radius)
	# Filled hull (front and back faces) + bright edges.
	var fill := _flat(Color(_base_color, 0.35))
	_hull.add_child(_polygon_mesh(pts, fill))
	var edge := _flat(Color(_base_color, 0.95))
	for i in pts.size():
		_hull.add_child(_edge(pts[i], pts[(i + 1) % pts.size()], edge))
	# Faint 12-note ring so the shape reads as "on the clock face".
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = radius * 0.985
	tm.outer_radius = radius * 1.015
	tm.rings = 32
	tm.ring_segments = 4
	ring.mesh = tm
	ring.rotation.x = PI / 2
	ring.material_override = _flat(Color(_base_color, 0.25))
	_hull.add_child(ring)
	for o in order:
		var s: int = o[0]
		var a := float(s) / 12.0 * TAU
		var orb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = radius * 0.2
		sm.height = radius * 0.4
		sm.radial_segments = 12
		sm.rings = 6
		orb.mesh = sm
		var m := _flat(role_color(s).darkened(0.35))
		orb.material_override = m
		orb.position = Vector3(sin(a), cos(a), 0) * radius
		_hull.add_child(orb)
		var pc := pcs[o[1]]
		_orbs[pc] = orb
		_orb_mats[pc] = [m, role_color(s)]


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _polygon_mesh(pts: PackedVector2Array, mat: Material) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := Geometry2D.triangulate_polygon(pts)
	for i in idx:
		st.add_vertex(Vector3(pts[i].x, pts[i].y, 0))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi


func _edge(a: Vector2, b: Vector2, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var l := a.distance_to(b)
	bm.size = Vector3(l, radius * 0.07, radius * 0.07)
	mi.mesh = bm
	mi.material_override = mat
	var mid := (a + b) * 0.5
	mi.position = Vector3(mid.x, mid.y, 0)
	mi.rotation.z = (b - a).angle()
	return mi


func _refresh_text() -> void:
	var ch := chord()
	_plate.text = ch.pretty()
	var names := []
	for n in ch.tones():
		names.append(n.pretty())
	_notes_plate.text = "  ".join(names)
	_notes_plate.visible = show_notes
	if _next_plate:
		var rest := []
		for i in range(segment + 1, chords.size()):
			rest.append(chords[i].pretty())
		_next_plate.text = ("then " + "  →  ".join(rest)) if not rest.is_empty() else "last one!"
		_next_plate.visible = not show_notes
	set_urgency(t, false)


func set_show_notes(on: bool) -> void:
	show_notes = on
	_refresh_text()


## Plate grows and turns orange → red as the attacker closes in; the most
## urgent attacker gets a bigger plate.
var _reticle: MeshInstance3D


func set_urgency(p: float, most_urgent: bool) -> void:
	urgent = most_urgent
	# Pulsing target ring around the most urgent ship.
	if most_urgent and _reticle == null:
		_reticle = MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = radius * 1.55
		tm.outer_radius = radius * 1.7
		tm.rings = 32
		tm.ring_segments = 4
		_reticle.mesh = tm
		_reticle.rotation.x = PI / 2
		_reticle.material_override = _flat(Color(1, 0.85, 0.35, 0.8))
		add_child(_reticle)
	if _reticle:
		_reticle.visible = most_urgent
		if most_urgent:
			_reticle.scale = Vector3.ONE * (1.0 + 0.12 * sin(_clock * 8.0))
	var col := Color(1, 1, 1)
	if p > 0.85:
		col = Color(1.0, 0.35, 0.3)
	elif p > 0.6:
		col = Color(1.0, 0.72, 0.3)
	_plate.modulate = col
	# Far-away ships get smaller plates (less clutter at the horizon); the
	# most urgent one is the biggest.
	var s := lerpf(0.72, 1.1, clampf(p * 1.4, 0.0, 1.0))
	if most_urgent:
		s = maxf(s, 1.0) * 1.2
	if kind == "boss":
		s *= 1.15
	plate_scale = s
	_plate.pixel_size = PLATE_PX * s


var plate_scale := 1.0
## Extra height (metres) the game adds to keep plates from overlapping.
var plate_lift := 0.0:
	set(v):
		plate_lift = v
		if _plate:
			_plate.position.y = radius * 1.15 + 0.012 + v
		_update_leader()

var _leader: MeshInstance3D          # line from a lifted plate down to its ship
var _leader_mesh: CylinderMesh
var _boss_pips: Array[MeshInstance3D] = []


func _update_leader() -> void:
	if _leader == null:
		_leader_mesh = CylinderMesh.new()
		_leader_mesh.top_radius = 0.0008
		_leader_mesh.bottom_radius = 0.0008
		_leader_mesh.radial_segments = 4
		_leader_mesh.rings = 1
		_leader = MeshInstance3D.new()
		_leader.mesh = _leader_mesh
		_leader.material_override = _flat(Color(1, 1, 1, 0.5))
		add_child(_leader)
	var lo := radius * 1.05
	var hi := radius * 1.15 + 0.006 + plate_lift
	_leader.visible = plate_lift > 0.008
	_leader_mesh.height = maxf(0.001, hi - lo)
	_leader.position.y = (lo + hi) * 0.5


func plate_anchor() -> Vector3:
	return global_position + Vector3(0, radius * 1.15 + 0.012, 0)


func plate_text() -> String:
	return _plate.text


## Lights the orbs of chord tones currently held.
func show_held(held_pcs: Dictionary) -> void:
	for pc in _orbs:
		var on := held_pcs.has(pc)
		var pair: Array = _orb_mats[pc]
		(pair[0] as StandardMaterial3D).albedo_color = pair[1] if on else (pair[1] as Color).darkened(0.35)
		_orbs[pc].scale = Vector3.ONE * (1.6 if on else 1.0)


## Boss: moves to the next chord. Returns true if that was the last one.
func next_segment() -> bool:
	segment += 1
	if segment >= chords.size():
		return true
	_base_color = family_color(chord().quality)
	_rebuild_hull()
	_refresh_text()
	_update_boss_pips()
	return false


## Boss: a ring of pips, one per chord still to destroy.
func _build_boss_pips() -> void:
	for i in chords.size():
		var pip := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = radius * 0.09
		sm.height = radius * 0.18
		pip.mesh = sm
		pip.material_override = _flat(Color(1, 0.85, 0.4))
		var a := TAU * i / chords.size()
		pip.position = Vector3(sin(a), cos(a), 0) * radius * 1.45
		add_child(pip)
		_boss_pips.append(pip)
	_update_boss_pips()


func _update_boss_pips() -> void:
	for i in _boss_pips.size():
		_boss_pips[i].visible = i >= segment


## Missiles leave a short glowing trail.
func _add_trail() -> void:
	var p := CPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.45
	p.local_coords = false
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 0.01
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var sm := SphereMesh.new()
	sm.radius = 0.003
	sm.height = 0.006
	sm.radial_segments = 4
	sm.rings = 2
	p.mesh = sm
	var m := _flat(Color(1, 1, 1))
	m.vertex_color_use_as_albedo = true
	p.material_override = m
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(_base_color, 0.9), Color(_base_color, 0.0)])
	p.color_ramp = g
	add_child(p)


func orb_colors() -> Array:
	var out := []
	for pc in _orb_mats:
		out.append(_orb_mats[pc][1])
	return out
