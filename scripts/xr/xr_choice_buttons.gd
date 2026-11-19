class_name XRChoiceButtons
extends Node3D
## "Name it" answers in XR as floating buttons (XRChoiceButton) instead of
## the flat buttons on the panel.
##
## Each new question lays its buttons out on a gentle arc within arm's
## reach, below eye level and in the direction of the panel, each turned
## to face the player's eyes (set once per question; they never follow
## your head). Pick one with the pointer ray (pinch / trigger) or press
## it with an index fingertip like a real button.
##
## A knob (a ball left of the row) moves the whole row: pinch it, or grab
## it with the ray, and drag. Where you leave it is saved relative to the
## direction you face (Settings "xr_choices_offset": right, up, back), so
## the next question's buttons appear there too. It speaks the same grab
## API as the keyboard overlay's handles, so XRPointer drives it.
##
## The session decides right/wrong (PracticeSession.answer_choice) exactly
## as the 2D buttons do; this node only mirrors its feedback.

const REACH := 0.46               # horizontal distance from the eyes, metres
const DROP := 0.3                 # below eye height
## Between buttons: grows with the buttons, plus 10% more space.
const GAP := 0.022 * XRChoiceButton.SCALE * 1.1
const KNOB_R := 0.014
const KNOB_HIT_R := 0.026
const KNOB_SIDE := 0.035          # beyond the first button's left edge
const MAX_OFFSET := 1.2
## Fingertip pokes (button-local metres, +z towards the player).
const POKE_HOVER := 0.035
const POKE_PRESS := 0.003
const POKE_REARM := 0.02
const POKE_BEHIND := -0.05
const POKE_SLACK := 0.006

var session: PracticeSession
var camera: Node3D                # the player's head
var panel: Node3D                 # buttons sit towards the panel (optional)
var origin: XROrigin3D            # hand-tracker joints are relative to this

var buttons: Array[XRChoiceButton] = []
var _poke := {}                   # hand -> {btn, armed}
var _frame := Basis.IDENTITY      # x right, y up, z back (towards the player)
var _head := Vector3.ZERO
var _knob: Node3D
var _knob_mesh: MeshInstance3D
var _knob_body: StaticBody3D
var _knob_mat: StandardMaterial3D
var _knob_hot: StandardMaterial3D
var _knob_hover := {}
var _grab := {}                   # {id, start, offset}


func _ready() -> void:
	add_to_group("xr_choice_buttons")
	_build_knob()
	if session:
		session.prompt_changed.connect(_on_prompt)
		session.choice_feedback.connect(_on_feedback)
		if not session.choices.is_empty():
			_on_prompt.call_deferred(session.prompt, session.choices)


func _on_prompt(_p: ChordPrompt, choices: Array) -> void:
	clear()
	if choices.is_empty() or session.practice_mode() != "name":
		return
	show_choices(choices)


## Lays out one button per chord (also used by the desktop preview).
func show_choices(choices: Array) -> void:
	clear()
	_aim()
	for i in choices.size():
		var b := XRChoiceButton.new()
		b.setup(choices[i])
		add_child(b)
		b.activated.connect(_on_pressed)
		b.appear(0.05 * i)
		buttons.append(b)
	_layout(saved_offset())


## Takes the head position and the direction towards the main window (the
## panel) as the frame the row is laid out in.
func _aim() -> void:
	_head = camera.global_position if camera else Vector3(0, 1.5, 0)
	var fwd := Vector3.FORWARD
	if panel:
		fwd = panel.global_position - _head
	elif camera:
		fwd = -camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	_frame = Basis(fwd.cross(Vector3.UP).normalized(), Vector3.UP, -fwd)


## Back to the default spot: within reach, below eye level, towards the
## main window (forgets where the knob left the row).
func reset_position() -> void:
	_grab = {}
	Settings.set_value("xr_choices_offset", [0.0, 0.0, 0.0])
	if not buttons.is_empty():
		_aim()
		_layout(Vector3.ZERO)
		_knob_restyle()


## Places the buttons on their arc, moved by `offset` (frame metres), each
## turned to face the eyes, and the knob beside the first one.
func _layout(offset: Vector3) -> void:
	var n := buttons.size()
	if n == 0:
		_knob.visible = false
		_knob_body.collision_layer = 0
		return
	var fwd := -_frame.z
	var right := _frame.x
	var shift := _frame * offset
	var step := (XRChoiceButton.SIZE.x + GAP) / REACH          # radians between buttons
	var yaw0 := atan2(fwd.x, fwd.z)
	for i in n:
		var yaw := yaw0 + (i - (n - 1) * 0.5) * -step
		var dir := Vector3(sin(yaw), 0.0, cos(yaw))
		var pos := _head + dir * REACH + Vector3.DOWN * DROP + shift
		# +z faces the eyes; x is the head's right axis made perpendicular, so
		# no card looks rolled from the eye, even off to the side and below.
		var z := (_head - pos).normalized()
		var x := (right - z * right.dot(z)).normalized()
		buttons[i].global_transform = Transform3D(Basis(x, z.cross(x), z), pos)
	var first := buttons[0]
	_knob.global_transform = Transform3D(first.global_basis,
			first.global_position - first.global_basis.x * (XRChoiceButton.SIZE.x * 0.5 + KNOB_SIDE))
	_knob.visible = true
	_knob_body.collision_layer = 1 << 4


func clear() -> void:
	for b in buttons:
		b.queue_free()
	buttons.clear()
	_poke.clear()
	if _knob:
		_knob.visible = false
		_knob_body.collision_layer = 0


func _on_pressed(b: XRChoiceButton) -> void:
	if session:
		session.answer_choice(b.chord)


func _on_feedback(chord: Theory.Chord, ok: bool) -> void:
	for b in buttons:
		if b.chord.equals(chord):
			b.show_result(ok)
		elif ok:
			b.set_enabled(false)
			b.fade_to(0.35)


func _process(_delta: float) -> void:
	if session == null or buttons.is_empty():
		return
	if session.practice_mode() != "name":
		clear()
		return
	for b in buttons:
		if b.state == "idle" and (b.enabled or session.paused):
			b.set_enabled(not session.paused)


# --- fingertip pokes ------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if buttons.is_empty():
		return
	for hand in ["left", "right"]:
		var tip: Variant = _fingertip(hand)
		poke(hand, tip)


func _fingertip(hand: String) -> Variant:
	var t := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
	if t == null or not t.has_tracking_data:
		return null
	var tf := t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	return (origin.global_transform * tf).origin if origin else tf.origin


## One fingertip update (null = hand not tracked). Presses a button when
## the tip pushes through its face from the front; it re-arms once the tip
## pulls back out.
func poke(hand: String, tip: Variant) -> void:
	var id := hash(hand)
	var st: Dictionary = _poke.get(hand, {"btn": null, "armed": true, "z": 1.0})
	var found: XRChoiceButton = null
	var fz := 1.0
	if tip != null:
		for b in buttons:
			var l: Vector3 = b.to_local(tip)
			if absf(l.x) < XRChoiceButton.SIZE.x * 0.5 + POKE_SLACK \
					and absf(l.y) < XRChoiceButton.SIZE.y * 0.5 + POKE_SLACK \
					and l.z < POKE_HOVER and l.z > POKE_BEHIND:
				found = b
				fz = l.z
				break
	var prev: XRChoiceButton = st["btn"]
	if prev != found:
		if prev and is_instance_valid(prev):
			prev.set_hover(id, false)
		if found:
			found.set_hover(id, true)
			# Only arm when entering from the front, not from behind/the side.
			st["armed"] = fz > POKE_PRESS
	st["btn"] = found
	if found:
		if st["armed"] and fz <= POKE_PRESS and float(st["z"]) > POKE_PRESS:
			st["armed"] = false
			found.press()
		elif fz > POKE_REARM:
			st["armed"] = true
	else:
		st["armed"] = true
	st["z"] = fz
	_poke[hand] = st


# --- move knob ------------------------------------------------------------

static func saved_offset() -> Vector3:
	var v = Settings.get_value("xr_choices_offset")
	if v is Array and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


func _build_knob() -> void:
	_knob_mat = _flat(Color(0.35, 0.8, 1.0, 0.85))
	_knob_hot = _flat(Color(0.4, 1.0, 0.55, 0.95))
	_knob = Node3D.new()
	add_child(_knob)
	_knob_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = KNOB_R
	sm.height = KNOB_R * 2.0
	_knob_mesh.mesh = sm
	_knob_mesh.material_override = _knob_mat
	_knob.add_child(_knob_mesh)
	var ring := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = KNOB_R * 1.5
	t.outer_radius = KNOB_R * 1.9
	ring.mesh = t
	ring.rotation.x = PI / 2.0
	ring.material_override = _knob_mat
	_knob_mesh.add_child(ring)
	_knob_body = StaticBody3D.new()
	_knob_body.collision_layer = 0
	_knob_body.collision_mask = 0
	_knob_body.set_meta("xr_kb_handle", "choices")
	_knob_body.set_meta("xr_grab_target", self)
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = KNOB_HIT_R
	cs.shape = sph
	_knob_body.add_child(cs)
	_knob.add_child(_knob_body)
	_knob.visible = false


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 2
	return m


func _knob_restyle() -> void:
	var hot := not _knob_hover.is_empty() or not _grab.is_empty()
	_knob_mesh.material_override = _knob_hot if hot else _knob_mat
	(_knob_mesh.get_child(0) as MeshInstance3D).material_override = _knob_mesh.material_override


func knob_position() -> Vector3:
	return _knob.global_position


func handle_near(point: Vector3, radius: float) -> String:
	if not _knob.visible:
		return ""
	return "choices" if _knob.global_position.distance_to(point) < maxf(radius, KNOB_HIT_R) else ""


func set_hover(id: int, which: String) -> void:
	if which == "":
		_knob_hover.erase(id)
	else:
		_knob_hover[id] = true
	_knob_restyle()


func begin_handle(id: int, _which: String, point: Vector3) -> void:
	if not _grab.is_empty():
		return
	_grab = {"id": id, "start": point, "offset": saved_offset()}
	_knob_restyle()


func update_handle(id: int, point: Vector3) -> void:
	if _grab.is_empty() or _grab["id"] != id:
		return
	var d: Vector3 = _frame.inverse() * (point - _grab["start"])
	var off: Vector3 = (_grab["offset"] + d).clamp(Vector3.ONE * -MAX_OFFSET, Vector3.ONE * MAX_OFFSET)
	_grab["current"] = off
	_layout(off)


func end_handle(id: int) -> void:
	if _grab.is_empty() or _grab["id"] != id:
		return
	var off: Vector3 = _grab.get("current", _grab["offset"])
	_grab = {}
	Settings.set_value("xr_choices_offset", [off.x, off.y, off.z])
	_layout(off)
	_knob_restyle()


func is_grabbed() -> bool:
	return not _grab.is_empty()
