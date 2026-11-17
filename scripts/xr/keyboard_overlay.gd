class_name XRKeyboardOverlay
extends Node3D
## A virtual keyboard laid over your REAL keyboard in passthrough.
##
## Calibration: touch the middle of your lowest key, near its front edge,
## with either index fingertip and hold still; a ring at the fingertip
## fills as it captures. Then the highest key. KeyboardLayout turns the two
## points (and the Settings keyboard range) into a key-by-key overlay:
## translucent white and black keys sitting on the real ones. Keys light up
## exactly as on the on-screen keyboard: the chord to play (green), keys
## you hold (blue), wrong notes (red), correct (bright green).
##
## Adjusting (Settings > Display > "Adjust handles"): three balls appear —
## one at each end and one above the middle. Pinch an end ball (with your
## hand right at it, or with the ray) and drag to move that end; the middle
## ball moves the whole keyboard. Both ends can be dragged at once with two
## hands. The nudge buttons in Settings move, turn, tilt, level and widen it
## in small steps. Everything is saved; "Reset to calibration" undoes it.
##
## Settings: xr_kb_show, xr_kb_opacity, xr_kb_adjust, xr_kb_step,
## xr_keyboard_cal ([low xyz, high xyz, tilt]), xr_keyboard_cal_base.

signal calibration_status(text: String)

const DWELL_S := 1.5            # hold still this long to capture a point
const STILL_M := 0.008          # "still" = moving less than 8 mm
const HANDS := ["right", "left"]
const HANDLE_R := 0.012          # visual radius
const HANDLE_HIT_R := 0.022      # ray hit radius
const MID_RAISE := 0.035         # middle handle floats this far above the keys
const HANDLE_LAYER := 1 << 4     # same layer the XR pointer ray looks at
## Nudge steps per tap: [metres, degrees].
const STEPS := {"fine": [0.001, 0.25], "normal": [0.003, 1.0], "coarse": [0.01, 3.0]}

var source: PianoKeyboard       # the 2D keyboard whose state we mirror
var origin: XROrigin3D          # hand-tracker joints are relative to this
var calibrating := 0            # 0 = off, 1 = waiting for low key, 2 = high key

var layout := KeyboardLayout.new()
var _calibrated := false
var _keys := {}                 # midi -> MeshInstance3D
var _mats := {}
var _dwell := {}                # hand -> {pos, t}
var _ring: MeshInstance3D
var _markers: Array[MeshInstance3D] = []
var _last_state := {}           # midi -> state string (avoid material churn)
var _handles := {}              # "low" | "high" | "mid" -> {mesh, body}
var _grabs := {}                # grabber id -> {which, start, p_low, p_high}
var _hover := {}                # grabber id -> which
var _handle_mat: StandardMaterial3D
var _handle_hot_mat: StandardMaterial3D


func _ready() -> void:
	add_to_group("xr_keyboard_overlay")
	_ring = _make_ring()
	add_child(_ring)
	for i in 2:
		var mk := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.006
		s.height = 0.012
		mk.mesh = s
		mk.material_override = _flat(Color(1.0, 0.75, 0.3, 0.9))
		mk.visible = false
		add_child(mk)
		_markers.append(mk)
	_build_materials()
	_build_handles()
	_load_calibration()
	Settings.changed.connect(func(key: String):
		if key in ["range_low", "range_high", "xr_kb_lift_mm"] and _calibrated:
			_rebuild()
		elif key in ["xr_kb_opacity"]:
			_build_materials()
			_last_state.clear()
		elif key == "xr_kb_show":
			visible_keys(bool(Settings.get_value("xr_kb_show")) or adjusting())
		elif key == "xr_kb_adjust":
			visible_keys(bool(Settings.get_value("xr_kb_show")) or adjusting())
			_update_handles())


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _build_materials() -> void:
	var a := clampf(float(Settings.get_value("xr_kb_opacity")), 0.0, 1.0)
	_mats = {
		"white": _flat(Color(1, 1, 1, 0.22 * a)),
		"black": _flat(Color(0.05, 0.05, 0.08, 0.55 * a)),
		"hint": _flat(Color(0.35, 0.85, 0.55, 0.75)),
		"held": _flat(Color(0.3, 0.6, 1.0, 0.8)),
		"selected": _flat(Color(1.0, 0.75, 0.25, 0.75)),
		"wrong": _flat(Color(0.95, 0.3, 0.3, 0.85)),
		"correct": _flat(Color(0.3, 0.95, 0.45, 0.9)),
	}
	# Black keys draw over white keys.
	for k in ["black", "hint", "held", "selected", "wrong", "correct"]:
		_mats[k].render_priority = 1


func _build_handles() -> void:
	_handle_mat = _flat(Color(1.0, 0.75, 0.3, 0.85))
	_handle_hot_mat = _flat(Color(0.4, 1.0, 0.55, 0.95))
	_handle_mat.render_priority = 2
	_handle_hot_mat.render_priority = 2
	for which in ["low", "high", "mid"]:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = HANDLE_R * (1.25 if which == "mid" else 1.0)
		sm.height = sm.radius * 2.0
		mi.mesh = sm
		mi.material_override = _handle_mat
		mi.visible = false
		add_child(mi)
		var body := StaticBody3D.new()
		body.collision_layer = 0
		body.collision_mask = 0
		body.set_meta("xr_kb_handle", which)
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = HANDLE_HIT_R
		cs.shape = sph
		body.add_child(cs)
		add_child(body)
		_handles[which] = {"mesh": mi, "body": body}


func _make_ring() -> MeshInstance3D:
	var r := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = 0.008
	t.outer_radius = 0.011
	r.mesh = t
	r.material_override = _flat(Color(0.36, 0.62, 1.0, 0.9))
	r.visible = false
	return r


# --- calibration -------------------------------------------------------------

func start_calibration() -> void:
	calibrating = 1
	_dwell.clear()
	_update_handles()
	for mk in _markers:
		mk.visible = false
	calibration_status.emit("Touch the middle of your LOWEST key, near the front edge, and hold still…")


func _fingertip(hand: String) -> Variant:
	var t := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
	if t == null or not t.has_tracking_data:
		return null
	var tf := t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	return (origin.global_transform * tf).origin if origin else tf.origin


func _calibrate_step(delta: float) -> void:
	# Whichever index fingertip holds still first is captured.
	var best_progress := 0.0
	var best_pos := Vector3.ZERO
	var any := false
	for hand in HANDS:
		var tip = _fingertip(hand)
		if tip == null:
			_dwell.erase(hand)
			continue
		var d: Dictionary = _dwell.get(hand, {"pos": tip, "t": 0.0})
		if tip.distance_to(d["pos"]) > STILL_M:
			d = {"pos": tip, "t": 0.0}
		else:
			d["t"] += delta
		_dwell[hand] = d
		var progress: float = d["t"] / DWELL_S
		if not any or progress > best_progress:
			any = true
			best_progress = progress
			best_pos = tip
		if d["t"] >= DWELL_S:
			_capture(tip)
			return
	_ring.visible = any
	if any:
		_ring.global_position = best_pos
		var s := 0.6 + 0.8 * clampf(best_progress, 0.0, 1.0)
		_ring.scale = Vector3.ONE * s
		(_ring.material_override as StandardMaterial3D).albedo_color = Color(0.36, 0.62, 1.0, 0.9).lerp(Color(0.3, 0.95, 0.45, 0.95), clampf(best_progress, 0.0, 1.0))


func _capture(tip: Vector3) -> void:
	_dwell.clear()
	_ring.visible = false
	if calibrating == 1:
		layout.p_low = tip
		_markers[0].global_position = tip
		_markers[0].visible = true
		calibrating = 2
		calibration_status.emit("Got it. Now touch the middle of your HIGHEST key and hold still…")
		return
	calibrating = 0
	layout.p_high = tip
	_markers[1].global_position = tip
	_markers[1].visible = true
	_apply_range()
	if not layout.valid():
		calibration_status.emit("Those two points are too close together — press Calibrate and try again.")
		return
	_calibrated = true
	layout.tilt = 0.0
	_save_calibration()
	Settings.set_value("xr_keyboard_cal_base", Settings.get_value("xr_keyboard_cal"))
	_rebuild()
	calibration_status.emit("Keyboard overlay placed (%d keys, white keys %.1f mm wide)." % [layout.high - layout.low + 1, layout.white_width() * 1000.0])
	await get_tree().create_timer(4.0).timeout
	for mk in _markers:
		mk.visible = false


# --- overlay -----------------------------------------------------------------

func _apply_range() -> void:
	layout.low = int(Settings.get_value("range_low"))
	layout.high = int(Settings.get_value("range_high"))
	layout.lift = float(Settings.get_value("xr_kb_lift_mm")) / 1000.0
	var cam := get_viewport().get_camera_3d()
	if cam:
		layout.viewer = cam.global_position


func _rebuild() -> void:
	_apply_range()
	var ks := layout.keys()
	# Reuse the key meshes when the range hasn't changed (smooth dragging).
	var same := ks.size() == _keys.size()
	for k in ks:
		if not _keys.has(k["midi"]):
			same = false
			break
	if not same:
		for k in _keys.values():
			k.queue_free()
		_keys.clear()
		_last_state.clear()
		for k in ks:
			var mi := MeshInstance3D.new()
			mi.mesh = BoxMesh.new()
			add_child(mi)
			mi.material_override = _mats["white" if k["white"] else "black"]
			mi.set_meta("white", k["white"])
			_keys[k["midi"]] = mi
	for k in ks:
		var mi: MeshInstance3D = _keys[k["midi"]]
		(mi.mesh as BoxMesh).size = k["size"]
		mi.global_transform = Transform3D(k["basis"], k["center"])
	visible_keys(bool(Settings.get_value("xr_kb_show")) or adjusting())
	_update_handles()


func visible_keys(on: bool) -> void:
	for k in _keys.values():
		k.visible = on


func _process(delta: float) -> void:
	if calibrating > 0:
		_calibrate_step(delta)
		return
	if not _calibrated or source == null or _keys.is_empty():
		return
	for m in _keys:
		var state := "white" if _keys[m].get_meta("white") else "black"
		if source.correct_flash.has(m):
			state = "correct"
		elif source.wrong.has(m):
			state = "wrong"
		elif source.held.has(m):
			state = "held"
		elif source.selected.has(m):
			state = "selected"
		elif source.hints.has(m):
			state = "hint"
		if _last_state.get(m, "") != state:
			_last_state[m] = state
			_keys[m].material_override = _mats[state]


func _save_calibration() -> void:
	var a := layout.p_low
	var b := layout.p_high
	Settings.set_value("xr_keyboard_cal", [a.x, a.y, a.z, b.x, b.y, b.z, layout.tilt])


func _load_calibration(key := "xr_keyboard_cal") -> bool:
	var c = Settings.get_value(key)
	if c is Array and c.size() >= 6:
		layout.p_low = Vector3(c[0], c[1], c[2])
		layout.p_high = Vector3(c[3], c[4], c[5])
		layout.tilt = float(c[6]) if c.size() >= 7 else 0.0
		_calibrated = true
		_rebuild.call_deferred()
		return true
	return false


## Undo all nudges and drags since the last calibration.
func reset_adjustments() -> void:
	if _load_calibration("xr_keyboard_cal_base"):
		_save_calibration()
		calibration_status.emit("Overlay reset to your last calibration.")
	else:
		calibration_status.emit("Calibrate the real keyboard first.")


# --- adjusting ---------------------------------------------------------------

func adjusting() -> bool:
	return _calibrated and calibrating == 0 and bool(Settings.get_value("xr_kb_adjust"))


func _update_handles() -> void:
	var on := adjusting() and layout.valid()
	var pos := {}
	if on:
		var up: Vector3 = layout.axes()[1]
		pos = {"low": layout.p_low, "high": layout.p_high, "mid": layout.mid() + up * MID_RAISE}
	for which in _handles:
		var h: Dictionary = _handles[which]
		var mesh: MeshInstance3D = h["mesh"]
		var body: StaticBody3D = h["body"]
		mesh.visible = on
		body.collision_layer = HANDLE_LAYER if on else 0
		if on:
			mesh.global_position = pos[which]
			body.global_position = pos[which]
		var hot: bool = _hover.values().has(which) or is_handle_grabbed(which)
		mesh.material_override = _handle_hot_mat if hot else _handle_mat


## The handle within `radius` of `point` ("" if none).
func handle_near(point: Vector3, radius: float) -> String:
	if not adjusting():
		return ""
	var best := ""
	var best_d := radius
	for which in _handles:
		var d: float = (_handles[which]["mesh"] as Node3D).global_position.distance_to(point)
		if d < best_d:
			best_d = d
			best = which
	return best


func set_hover(id: int, which: String) -> void:
	if _hover.get(id, "") == which:
		return
	if which == "":
		_hover.erase(id)
	else:
		_hover[id] = which
	_update_handles()


func is_handle_grabbed(which: String) -> bool:
	for g in _grabs.values():
		if g["which"] == which:
			return true
	return false


func begin_handle(id: int, which: String, point: Vector3) -> void:
	_grabs[id] = {"which": which, "start": point, "p_low": layout.p_low, "p_high": layout.p_high}
	_update_handles()


func update_handle(id: int, point: Vector3) -> void:
	if not _grabs.has(id):
		return
	var g: Dictionary = _grabs[id]
	var d: Vector3 = point - g["start"]
	var keep_low := layout.p_low
	var keep_high := layout.p_high
	match g["which"]:
		"low":
			layout.p_low = g["p_low"] + d
		"high":
			layout.p_high = g["p_high"] + d
		"mid":
			layout.p_low = g["p_low"] + d
			layout.p_high = g["p_high"] + d
	if not layout.valid():
		layout.p_low = keep_low
		layout.p_high = keep_high
		return
	_rebuild()


func end_handle(id: int) -> void:
	if _grabs.erase(id):
		_save_calibration()
		_update_handles()


## One nudge-button tap. kind: move_x (along the keys), move_z (away from
## you), move_y (up), turn, tilt, level, width; dir: +1 / -1.
func nudge(kind: String, dir: int) -> void:
	if not _calibrated:
		calibration_status.emit("Calibrate the real keyboard first.")
		return
	var step: Array = STEPS.get(str(Settings.get_value("xr_kb_step")), STEPS["normal"])
	var m: float = step[0] * dir
	var a: float = deg_to_rad(step[1]) * dir
	var ax := layout.axes()
	match kind:
		"move_x": layout.translate(ax[0] * m)
		"move_z": layout.translate(ax[2] * m)
		"move_y": layout.translate(Vector3.UP * m)
		"turn": layout.turn(a)
		"tilt": layout.tilt = clampf(layout.tilt + a, deg_to_rad(-30.0), deg_to_rad(30.0))
		"level": layout.level(m)
		"width": layout.widen(m)
	_rebuild()
	_save_calibration()


func is_calibrated() -> bool:
	return _calibrated and layout.valid()
