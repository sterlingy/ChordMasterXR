class_name XRPointer
extends Node3D
## A ray from a hand/controller aim pose that clicks on XRPanels and grabs
## their handles. Parent must be an XRController3D. "Pinch" is the trigger,
## or a pinch on hand tracking (Android XR maps pinch to select/trigger).
##
## Pinch while...
##   - your hand is right at a handle (within NEAR_M)  -> grab it directly
##   - the ray points at a handle                      -> grab it at a distance
##   - the ray points at the panel                     -> click
## The same works for the keyboard overlay's adjust handles (if `kb` is set)
## and anything else in `grabbables` with the same handle API
## (handle_near / set_hover / begin_handle / update_handle / end_handle), e.g.
## the Chord Defense playfield handle. Their hit bodies carry the meta
## "xr_kb_handle" (handle name) and optionally "xr_grab_target" (the owner;
## defaults to `kb`).

const LENGTH := 3.0
const NEAR_M := 0.06

var panel: XRPanel
var kb: XRKeyboardOverlay            # keyboard overlay (optional)
var grabbables: Array = []           # objects with the handle API (kb is added if missing)
var touch: XRHandTouch               # same hand's fingertip toucher (optional)
var ray: RayCast3D
var beam: MeshInstance3D
var dot: MeshInstance3D
var _pressed := false
var _controller: XRController3D
var _grabbing := false
var _grab_ray_dist := -1.0          # >= 0 when grabbing along the ray
var _grab_target: Object = null      # grabbable being dragged (null = panel)
var _hovered: Node = null
var _hover_btn: XRChoiceButton = null  # floating answer button under the ray
var _id := 0


func _ready() -> void:
	_controller = get_parent() as XRController3D
	_id = get_instance_id()
	if kb and not grabbables.has(kb):
		grabbables.push_front(kb)
	ray = RayCast3D.new()
	ray.target_position = Vector3(0, 0, -LENGTH)
	ray.collision_mask = 1 << 4
	ray.collide_with_bodies = true
	add_child(ray)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.7, 1.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0015
	cyl.bottom_radius = 0.0015
	cyl.height = 1.0
	beam.mesh = cyl
	beam.material_override = mat
	beam.rotation_degrees.x = -90
	add_child(beam)

	dot = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.005
	sph.height = 0.01
	dot.mesh = sph
	dot.material_override = mat
	dot.top_level = true
	add_child(dot)


func _physics_process(_delta: float) -> void:
	var active := _controller != null and _controller.get_has_tracking_data()
	visible = active
	if not active:
		if _grabbing:
			_end_grab()
		_set_hover(null)
		_set_btn_hover(null)
		for g in grabbables:
			g.set_hover(_id, "")
		return

	var trigger := _controller.get_float("trigger") > 0.6 or _controller.is_button_pressed("trigger_click") \
		or _controller.is_button_pressed("select")
	var hand_point := global_position
	if touch:
		var pp = touch.pinch_point()
		if pp != null:
			hand_point = pp

	# What is the ray on?
	var hit := ray.is_colliding()
	var length := LENGTH
	var collider: Object = ray.get_collider() if hit else null
	var point := Vector3.ZERO
	if hit:
		point = ray.get_collision_point()
		length = global_position.distance_to(point)
	var ray_handle: Node = collider if collider and collider.has_meta("xr_handle") else null
	var near_handle: Node = panel.handle_near(hand_point, NEAR_M * panel.scale.x)
	var ray_t: Object = null
	var ray_w := ""
	if collider and collider.has_meta("xr_kb_handle"):
		ray_w = str(collider.get_meta("xr_kb_handle"))
		ray_t = collider.get_meta("xr_grab_target", kb)
	var near_t: Object = null
	var near_w := ""
	if not near_handle:
		for g in grabbables:
			var w: String = g.handle_near(hand_point, NEAR_M * 0.6)
			if w != "":
				near_t = g
				near_w = w
				break

	# --- grabbing in progress
	if _grabbing:
		var grab_point := hand_point
		if _grab_ray_dist >= 0.0:
			grab_point = global_position + (-global_basis.z) * _grab_ray_dist
		if _grab_target:
			_grab_target.update_handle(_id, grab_point)
		else:
			panel.update_grab(_id, grab_point)
		_draw_beam(_grab_ray_dist if _grab_ray_dist >= 0.0 else 0.0, _grab_ray_dist >= 0.0, grab_point)
		if not trigger:
			_end_grab()
		_pressed = trigger
		return

	_set_hover(near_handle if near_handle else ray_handle)
	for g in grabbables:
		var w := ""
		if near_t:
			w = near_w if g == near_t else ""
		elif not near_handle and g == ray_t:
			w = ray_w
		g.set_hover(_id, w)

	# --- start a grab?
	if trigger and not _pressed and (near_t or (ray_t and not near_handle)) and not panel.is_grabbed():
		_grabbing = true
		if near_t:
			_grab_target = near_t
			_grab_ray_dist = -1.0
			near_t.begin_handle(_id, near_w, hand_point)
		else:
			_grab_target = ray_t
			_grab_ray_dist = length
			ray_t.begin_handle(_id, ray_w, point)
		_pressed = trigger
		return
	if trigger and not _pressed and not panel.is_grabbed():
		if near_handle:
			_grabbing = true
			_grab_ray_dist = -1.0
			panel.begin_grab(_id, near_handle, hand_point)
		elif ray_handle:
			_grabbing = true
			_grab_ray_dist = length
			panel.begin_grab(_id, ray_handle, point)
		if _grabbing:
			_pressed = trigger
			return

	# --- floating 3D buttons ("Name it" answers): pinch / trigger to press
	var btn: XRChoiceButton = collider.get_meta("xr_button") if collider and collider.has_meta("xr_button") else null
	_set_btn_hover(btn)
	if btn:
		_draw_beam(length, hit, point)
		if trigger and not _pressed:
			btn.press()
		_pressed = trigger
		return

	# --- finger is touching/near the panel: let direct touch handle it
	if touch and touch.near_panel:
		_draw_beam(0.0, false, Vector3.ZERO)
		if _pressed and not trigger:
			panel.pointer_button(Vector2(-10, -10), false)
		_pressed = trigger
		return

	# --- normal UI pointing
	var px: Variant = null
	if collider and collider.has_meta("xr_panel"):
		px = (collider.get_meta("xr_panel") as XRPanel).world_to_pixels(point)
	_draw_beam(length, hit, point)
	if px != null:
		panel.pointer_move(px)
		if trigger != _pressed:
			panel.pointer_button(px, trigger)
	elif _pressed and not trigger:
		panel.pointer_button(Vector2(-10, -10), false)
	_pressed = trigger


func _draw_beam(length: float, show_dot: bool, dot_pos: Vector3) -> void:
	beam.visible = length > 0.0
	beam.scale = Vector3(1, maxf(length, 0.001), 1)
	beam.position = Vector3(0, 0, -length / 2.0)
	dot.visible = show_dot
	dot.global_position = dot_pos


func _end_grab() -> void:
	if _grab_target:
		_grab_target.end_handle(_id)
	else:
		panel.end_grab(_id)
	_grab_target = null
	_grabbing = false
	_grab_ray_dist = -1.0


func _set_btn_hover(b: XRChoiceButton) -> void:
	if b == _hover_btn:
		return
	if _hover_btn and is_instance_valid(_hover_btn):
		_hover_btn.set_hover(_id, false)
	_hover_btn = b
	if b:
		b.set_hover(_id, true)


func _set_hover(h: Node) -> void:
	if h == _hovered:
		return
	if _hovered:
		panel.set_handle_hover(_hovered, false)
	_hovered = h
	if _hovered:
		panel.set_handle_hover(_hovered, true)
