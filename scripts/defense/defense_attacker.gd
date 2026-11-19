class_name DefenseAttacker
extends Node3D
## One attacking chord, drawn as a glossy map pin (an inverted teardrop):
## the chord name in the round head, the inversion number (1, 2, 3 ...) in
## the narrow tip; root position leaves the tip empty. The pin's colour is
## the inversion to play (INVERSION_COLORS). It brightens as you hold more
## of the chord's tones, and its rim turns orange, then red, as it closes
## in. The pin and note plates hold a fixed orientation in the playfield
## (facing the player's side, tipped back to read from above).
##
## The pin grows with distance (never smaller than its real size up close)
## so the name stays readable at the far end of the lanes.
##
## Movement is a progress value t (0 = just arrived, 1 = hits its station)
## along a path that depends on `kind`. The game owns lanes/stations and
## tells the attacker where they are.

signal reached_station(attacker: DefenseAttacker)

const KINDS := ["drifter", "jumper", "diver", "missile", "boss"]
## Name plate size (Label3D fixed_size pixel size): big enough to read at a
## glance. Plates keep a constant on-screen size but never turn.
const PLATE_PX := 0.0014
## Fixed pitch for hull and plates: faces the player, top tipped away so
## it reads from above (the player looks down at the keyboard).
const FACE_PITCH_DEG := -35.0
## The pin keeps its real size up to this distance, then grows with
## distance (like a fixed-size label), up to RING_MAX_SCALE.
const RING_REF_DIST := 0.8
const RING_MAX_SCALE := 2.2
## Pin shape, relative to `radius`: the round head's radius, and how far
## below the head's centre the tip is (in head radii).
const PIN_HEAD := 1.35
const PIN_TIP := 1.9
## Text sizes in head radii: the name's em height, the number's.
const NAME_EM := 0.9
const NUM_EM := 0.62
## Pin colour per inversion: root, 1st, 2nd, 3rd, 4th.
const INVERSION_COLORS := [
	Color(0.35, 0.82, 1.0),    # root position: sky blue
	Color(1.0, 0.78, 0.25),    # 1st: gold
	Color(1.0, 0.42, 0.78),    # 2nd: pink
	Color(0.55, 1.0, 0.45),    # 3rd: lime
	Color(0.75, 0.55, 1.0),    # 4th: violet
]

var kind := "drifter"
var chords: Array = []              # Theory.Chord; bosses carry several
var inversions: Array[int] = []     # inversion to play each chord in (0 = root)
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

var _hull: Node3D                   # fixed tilt; scaled with distance
var _core: Node3D                   # bob + warp-in scale
var _pin_mat: ShaderMaterial
var _name_label: Label3D
var _inv_label: Label3D
var _held_frac := 0.0
var _vis := 1.0                     # current distance scale of the pin
var _pin_s := 1.0                   # urgency scale of the pin
var _rim := Color.WHITE             # rim colour (white -> orange -> red)

const PIN_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec2 quad_size;
uniform float center_y;          // head centre, measured from the quad centre
uniform float head_r;
uniform float tip_d;             // tip distance below the head centre
uniform vec4 fill : source_color;
uniform vec4 rim : source_color;
uniform float lift = 0.0;        // 0..1 brighten (notes held)
uniform float alpha = 1.0;

float sd_pin(vec2 p) {
	// Uneven capsule: head circle at the origin, a tiny round tip below.
	float r1 = head_r;
	float r2 = head_r * 0.05;
	float h = tip_d - r2;
	vec2 q = vec2(abs(p.x), -p.y);
	float b = (r1 - r2) / h;
	float a = sqrt(1.0 - b * b);
	float k = dot(q, vec2(-b, a));
	if (k < 0.0) return length(q) - r1;
	if (k > a * h) return length(q - vec2(0.0, h)) - r2;
	return dot(q, vec2(a, b)) - r1;
}

void fragment() {
	vec2 p = (UV - 0.5) * quad_size;
	p.y = -p.y;
	p.y -= center_y;
	float d = sd_pin(p);
	float aa = max(fwidth(d), 1e-5);
	float inside = 1.0 - smoothstep(-aa, aa, d);
	// Body: bright core below the head's centre, deep edges.
	vec3 base = fill.rgb;
	vec3 light = mix(base, vec3(1.0), 0.18);
	vec3 dark = base * 0.24;
	float t = clamp(length(p - vec2(0.0, -0.2 * head_r)) / (1.45 * head_r), 0.0, 1.0);
	vec3 col = mix(light, dark, pow(t, 0.9));
	col = mix(col, light, lift * 0.55);
	// Glossy highlight across the top of the head.
	vec2 e = (p - vec2(0.0, 0.42 * head_r)) / vec2(0.74 * head_r, 0.44 * head_r);
	float hl = (1.0 - smoothstep(0.82, 1.0, length(e)));
	hl *= 0.12 + 0.38 * clamp((p.y - 0.15 * head_r) / (0.7 * head_r), 0.0, 1.0);
	col += vec3(hl);
	// White rim.
	float bw = 0.09 * head_r;
	float edge = smoothstep(-bw - aa, -bw + aa, d);
	col = mix(col, rim.rgb, edge);
	// Soft shadow outside.
	float sh = (1.0 - inside) * exp(-max(d, 0.0) / (0.07 * head_r)) * 0.4;
	ALBEDO = mix(vec3(0.0), col, inside);
	ALPHA = max(inside, sh) * alpha;
}
"""
static var _pin_shader: Shader
var _plate: Label3D
var _notes_plate: Label3D
var _next_plate: Label3D
var _drop: MeshInstance3D            # line from the ship down to its lane
var _drop_mesh: CylinderMesh
var _marker: MeshInstance3D          # ring on the lane under the ship
var _base_color := Color.WHITE
var show_notes := false
var urgent := false


static func inversion_color(inv: int) -> Color:
	return INVERSION_COLORS[clampi(inv, 0, INVERSION_COLORS.size() - 1)]


## Text inside the ring: nothing for root position, else the number.
static func inversion_text(inv: int) -> String:
	return "" if inv <= 0 else str(inv)


func chord() -> Theory.Chord:
	return chords[mini(segment, chords.size() - 1)]


## The inversion the current chord should be played in (0 = root).
func inversion() -> int:
	var i := mini(segment, chords.size() - 1)
	return inversions[i] if i < inversions.size() else 0


func setup(p_kind: String, p_chords: Array, p_station: int, p_lane_x: float, p_travel: float, rng: RandomNumberGenerator, p_inversions: Array = []) -> void:
	kind = p_kind
	chords = p_chords
	inversions.clear()
	for i in chords.size():
		inversions.append(int(p_inversions[i]) if i < p_inversions.size() else 0)
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


## The ring has a fixed orientation (FACE_PITCH_DEG) and never turns. It
## grows with distance to keep pace with the fixed-size name; a gentle bob
## keeps it alive.
func _process(_delta: float) -> void:
	if _hull == null:
		return
	var bob := sin(Time.get_ticks_msec() / 1000.0 * 2.2 + _spin * 10.0) * radius * 0.12
	_core.position.y = bob
	var cam := get_viewport().get_camera_3d()
	var v := 1.0
	if cam:
		v = clampf(cam.global_position.distance_to(global_position) / RING_REF_DIST, 1.0, RING_MAX_SCALE)
	if absf(v - _vis) > 0.002:
		_vis = v
		_apply_scale()


func _apply_scale() -> void:
	_hull.scale = Vector3.ONE * _vis * _pin_s
	_place_plates()


## Radius of the pin's round head as drawn right now (metres).
func ring_radius() -> float:
	return radius * PIN_HEAD * _vis * _pin_s


func _place_plates() -> void:
	var below := -ring_radius() * (PIN_TIP + 0.05) - 0.006
	if _plate:
		_plate.position.y = ring_radius() * 1.08 + 0.012 + plate_lift
	if _notes_plate:
		_notes_plate.position.y = below
	if _next_plate:
		_next_plate.position.y = below
	_update_leader()


## Arrival effect: the ship scales up out of a flash.
func warp_in() -> void:
	_core.scale = Vector3.ONE * 0.05
	var tw := create_tween()
	tw.tween_property(_core, "scale", Vector3.ONE * 1.25, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_core, "scale", Vector3.ONE, 0.15)
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
	_base_color = inversion_color(inversion())
	_hull = Node3D.new()
	_hull.rotation_degrees.x = FACE_PITCH_DEG
	add_child(_hull)
	_core = Node3D.new()
	_hull.add_child(_core)
	_rebuild_hull()
	if kind == "missile":
		_add_trail()
	if kind == "boss":
		_build_boss_pips()
	# The name lives inside the pin; this plate only feeds plate_text()
	# (decluttering) and stays hidden.
	_plate = _label(64, Color(1, 1, 1))
	_plate.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_plate.visible = false
	_notes_plate = _label(30, Color(1, 0.82, 0.45))
	_notes_plate.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if kind == "boss":
		_next_plate = _label(30, Color(0.75, 0.78, 0.9))
		_next_plate.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_place_plates()
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
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	l.fixed_size = true
	l.pixel_size = PLATE_PX
	l.rotation_degrees.x = FACE_PITCH_DEG
	l.no_depth_test = true
	l.render_priority = 10
	l.outline_render_priority = 9
	add_child(l)
	return l


func _rebuild_hull() -> void:
	for c in _core.get_children():
		c.queue_free()
	if _pin_shader == null:
		_pin_shader = Shader.new()
		_pin_shader.code = PIN_SHADER
	var col := inversion_color(inversion())
	var r := radius * PIN_HEAD
	var tip := r * PIN_TIP
	var m := r * 0.25                       # room for the shadow
	var qs := Vector2(2.0 * r + 2.0 * m, r + tip + 2.0 * m)
	var pin := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = qs
	pin.mesh = q
	pin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Quad centre sits halfway between the head's top and the tip.
	var cy := (r - tip) * 0.5
	pin.position.y = cy
	_pin_mat = ShaderMaterial.new()
	_pin_mat.shader = _pin_shader
	_pin_mat.render_priority = 6
	_pin_mat.set_shader_parameter("quad_size", qs)
	_pin_mat.set_shader_parameter("center_y", -cy)
	_pin_mat.set_shader_parameter("head_r", r)
	_pin_mat.set_shader_parameter("tip_d", tip)
	_pin_mat.set_shader_parameter("fill", col)
	pin.material_override = _pin_mat
	_core.add_child(pin)
	# Chord name in the head (shrunk to fit long names).
	_name_label = _pin_text(chord().pretty(), r * NAME_EM, r * 1.6)
	_name_label.position.y = r * 0.04
	_core.add_child(_name_label)
	# Inversion number in the tip (root position: none).
	_inv_label = _pin_text(inversion_text(inversion()), r * NUM_EM, r * 0.9)
	_inv_label.position.y = -r * 1.08
	_core.add_child(_inv_label)
	_apply_held()
	_apply_rim()


## White text sized in metres: `em` font height, at most `max_w` wide.
func _pin_text(text: String, em: float, max_w: float) -> Label3D:
	var l := Label3D.new()
	l.font = UITheme.ui_font()
	l.font_size = 72
	l.pixel_size = em / 72.0
	l.text = text
	l.outline_size = 14
	l.outline_modulate = Color(0.0, 0.04, 0.12, 0.55)
	l.modulate = Color(1, 1, 1)
	l.no_depth_test = true
	l.render_priority = 9
	l.outline_render_priority = 8
	l.position.z = 0.0008
	if text != "":
		var w := l.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.font_size).x * l.pixel_size
		if w > max_w:
			l.pixel_size *= max_w / w
	return l


func _torus(inner: float, outer: float) -> TorusMesh:
	var tm := TorusMesh.new()
	tm.inner_radius = inner
	tm.outer_radius = outer
	tm.rings = 48
	tm.ring_segments = 6
	return tm


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _refresh_text() -> void:
	var ch := chord()
	_plate.text = ch.pretty()
	# Notes from the bass up, in the inversion asked for.
	var names := []
	var ts := ch.tones()
	for i in ts.size():
		names.append(ts[(i + inversion()) % ts.size()].pretty())
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
		_reticle.mesh = _torus(radius * PIN_HEAD * 1.18, radius * PIN_HEAD * 1.27)
		_reticle.rotation.x = PI / 2
		_reticle.material_override = _flat(Color(1, 1, 1, 0.75))
		_hull.add_child(_reticle)
	if _reticle:
		_reticle.visible = most_urgent
		if most_urgent:
			_reticle.scale = Vector3.ONE * (1.0 + 0.12 * sin(_clock * 8.0))
	# The rim warms up as it closes in.
	var col := Color(1, 1, 1)
	if p > 0.85:
		col = Color(1.0, 0.35, 0.3)
	elif p > 0.6:
		col = Color(1.0, 0.72, 0.3)
	_rim = col
	_apply_rim()
	# Far-away pins are a bit smaller (less clutter at the horizon); the
	# most urgent one is the biggest.
	var s := lerpf(0.72, 1.1, clampf(p * 1.4, 0.0, 1.0))
	if most_urgent:
		s = maxf(s, 1.0) * 1.2
	if kind == "boss":
		s *= 1.15
	plate_scale = s
	_plate.pixel_size = PLATE_PX * s
	var ps := clampf(s, 0.85, 1.3)
	if absf(ps - _pin_s) > 0.01 and _hull:
		_pin_s = ps
		_apply_scale()


func _apply_rim() -> void:
	if _pin_mat:
		_pin_mat.set_shader_parameter("rim", _rim)


var plate_scale := 1.0
## Extra height (metres) the game adds to keep plates from overlapping.
var plate_lift := 0.0:
	set(v):
		plate_lift = v
		_place_plates()

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
	var lo := ring_radius() * 1.05
	var hi := ring_radius() * 1.08 + 0.006 + plate_lift
	_leader.visible = _plate != null and _plate.visible and plate_lift > 0.008
	_leader_mesh.height = maxf(0.001, hi - lo)
	_leader.position.y = (lo + hi) * 0.5


func plate_anchor() -> Vector3:
	return global_position + Vector3(0, ring_radius() * 1.08 + 0.012, 0)


func plate_text() -> String:
	return _plate.text


## Brightens the pin by how many of the chord's tones are held.
func show_held(held_pcs: Dictionary) -> void:
	var n := 0
	var pcs := chord().pitch_classes()
	for pc in pcs:
		if held_pcs.has(pc):
			n += 1
	_held_frac = float(n) / maxf(1.0, pcs.size())
	_apply_held()


func _apply_held() -> void:
	if _pin_mat:
		_pin_mat.set_shader_parameter("lift", _held_frac)


## Boss: moves to the next chord. Returns true if that was the last one.
func next_segment() -> bool:
	segment += 1
	if segment >= chords.size():
		return true
	_base_color = inversion_color(inversion())
	_held_frac = 0.0
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
		pip.position = Vector3(sin(a), cos(a), 0) * radius * PIN_HEAD * 1.22
		_hull.add_child(pip)
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


## Colours for beams and explosions: the ring's.
func orb_colors() -> Array:
	var c := inversion_color(inversion())
	return [c, c.lightened(0.45), Color(1, 1, 1)]
