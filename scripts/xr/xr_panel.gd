class_name XRPanel
extends Node3D
## A flat 2D UI panel in 3D space: a SubViewport rendered onto a quad.
## Receives pointer events (from XRPointer) in panel-local 2D pixels.
##
## Handles (all grabbed by pinching — directly with your hand, or by pointing
## the ray at them and pinching):
##   - grab bar under the bottom edge: move the panel
##   - round handles at the bottom corners: resize (pull away = bigger)
## The panel keeps facing you while it moves; its size is saved.

const MIN_SCALE := 0.4
const MAX_SCALE := 4.0
const HANDLE_COLOR := Color(1, 1, 1, 0.55)
const HANDLE_HOVER := Color(0.36, 0.62, 1.0, 0.95)
const TILT_DEG := -12.0

var panel_size := Vector2(0.36, 0.2025)
var pixel_size := Vector2i(1600, 900)
var camera: XRCamera3D               # the panel turns to face this while moved

var viewport: SubViewport
var mesh: MeshInstance3D
var body: StaticBody3D
var handles: Array[StaticBody3D] = []

var _last_pos := Vector2.ZERO
var _grab := {}                      # active grab state (one at a time)
var _hover := {}                     # handle -> hover count


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = pixel_size
	viewport.transparent_bg = false
	viewport.gui_embed_subwindows = true   # popups stay inside the panel
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var quad := QuadMesh.new()
	quad.size = panel_size
	mesh = MeshInstance3D.new()
	mesh.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mesh.material_override = mat
	add_child(mesh)

	body = StaticBody3D.new()
	body.collision_layer = 1 << 4   # layer 5: UI panels
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(panel_size.x, panel_size.y, 0.01)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.set_meta("xr_panel", self)

	_build_handles()
	scale = Vector3.ONE * clampf(float(Settings.get_value("xr_panel_scale")), MIN_SCALE, MAX_SCALE)


func set_content(control: Control) -> void:
	viewport.add_child(control)


# --- handles -----------------------------------------------------------------

func _build_handles() -> void:
	var bar_w := panel_size.x * 0.45
	var bar_h := panel_size.y * 0.06
	var below := -panel_size.y / 2.0 - bar_h * 1.4
	_add_handle("move", BoxMesh.new(), Vector3(bar_w, bar_h, bar_h * 0.6), Vector3(0, below, 0))
	var r := panel_size.y * 0.06
	for side in [-1.0, 1.0]:
		var pos := Vector3(side * (panel_size.x / 2.0 + r * 0.6), -panel_size.y / 2.0 - r * 0.6, 0)
		_add_handle("resize", SphereMesh.new(), Vector3(r * 2, r * 2, r * 2), pos)


func _add_handle(kind: String, m: PrimitiveMesh, size: Vector3, pos: Vector3) -> void:
	var h := StaticBody3D.new()
	h.collision_layer = 1 << 4
	h.position = pos
	h.set_meta("xr_handle", kind)
	h.set_meta("xr_owner", self)
	var shape := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size * 1.6   # generous hit area
	shape.shape = b
	h.add_child(shape)
	if m is BoxMesh:
		m.size = size
	elif m is SphereMesh:
		m.radius = size.x / 2.0
		m.height = size.x
	var mi := MeshInstance3D.new()
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = HANDLE_COLOR
	mi.material_override = mat
	mi.name = "Mesh"
	h.add_child(mi)
	add_child(h)
	handles.append(h)


## Called by pointers every frame for the handle they're over / near.
func set_handle_hover(h: Node, on: bool) -> void:
	var n: int = _hover.get(h, 0) + (1 if on else -1)
	_hover[h] = maxi(0, n)
	var mi := h.get_node("Mesh") as MeshInstance3D
	(mi.material_override as StandardMaterial3D).albedo_color = HANDLE_HOVER if _hover[h] > 0 else HANDLE_COLOR


## Nearest handle within `radius` metres of a world point, or null.
func handle_near(world: Vector3, radius: float) -> StaticBody3D:
	var best: StaticBody3D = null
	var best_d := radius
	for h in handles:
		var d := h.global_position.distance_to(world)
		if d < best_d:
			best_d = d
			best = h
	return best


# --- grabbing ----------------------------------------------------------------

func is_grabbed() -> bool:
	return not _grab.is_empty()


func begin_grab(owner_id: int, handle: Node, point: Vector3) -> void:
	_grab = {
		"owner": owner_id, "kind": handle.get_meta("xr_handle"),
		"start_point": point, "start_pos": global_position, "start_scale": scale.x,
		"start_dist": maxf(0.01, point.distance_to(global_position)),
	}


func update_grab(owner_id: int, point: Vector3) -> void:
	if _grab.is_empty() or _grab["owner"] != owner_id:
		return
	if _grab["kind"] == "move":
		global_position = _grab["start_pos"] + (point - _grab["start_point"])
		face_camera()
	else:
		var s: float = _grab["start_scale"] * point.distance_to(global_position) / _grab["start_dist"]
		scale = Vector3.ONE * clampf(s, MIN_SCALE, MAX_SCALE)


func end_grab(owner_id: int) -> void:
	if _grab.is_empty() or _grab["owner"] != owner_id:
		return
	if _grab["kind"] == "resize":
		Settings.set_value("xr_panel_scale", scale.x)
	_grab = {}


## Turn (yaw only, plus a slight tilt) so the panel faces the viewer.
func face_camera() -> void:
	if camera == null:
		return
	var to_cam := camera.global_position - global_position
	to_cam.y = 0.0
	if to_cam.length() < 0.01:
		return
	var s := scale
	look_at(global_position - to_cam, Vector3.UP)
	rotate_object_local(Vector3.RIGHT, deg_to_rad(TILT_DEG))
	scale = s


# --- pointer → UI ------------------------------------------------------------

## World-space hit point -> panel pixel coordinates (or null if outside).
func world_to_pixels(world: Vector3) -> Variant:
	var local := to_local(world)
	var uv := Vector2(local.x / panel_size.x + 0.5, 0.5 - local.y / panel_size.y)
	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1:
		return null
	return uv * Vector2(pixel_size)


func pointer_move(px: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = px
	e.global_position = px
	e.relative = px - _last_pos
	e.button_mask = 0
	_last_pos = px
	viewport.push_input(e)


func pointer_button(px: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = px
	e.global_position = px
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	_last_pos = px
	viewport.push_input(e)
