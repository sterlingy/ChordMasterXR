class_name XRFieldHandle
extends Node3D
## Grab handle for the Chord Defense playfield when it sits on the real
## keyboard (AR). A ball floats just left of the lowest station; pinch it
## (with your hand right at it, or with the ray) and drag to slide the whole
## playfield. The move is stored relative to the keyboard
## (Settings "xr_field_offset", in the game frame), so it survives
## recalibration and restarts.
##
## Speaks the same grab API as XRKeyboardOverlay's adjust handles
## (handle_near / set_hover / begin_handle / update_handle / end_handle),
## so XRPointer drives both the same way.
##
## Hidden while a game is running, so hands on the keys can't grab it by
## accident.

const HANDLE_R := 0.014           # visual radius
const HANDLE_HIT_R := 0.026       # ray hit radius
const SIDE_M := 0.11              # left of the lowest station's centre
const RAISE_M := 0.03             # above the station row
const MAX_OFFSET := 1.0           # metres in any direction
const HANDLE_LAYER := 1 << 4      # the layer XRPointer's ray looks at
const WHICH := "field"

var game: DefenseGame
## Game frame from DefenseGame.ar_frame (before the user's offset).
var base := Transform3D.IDENTITY

var _mesh: MeshInstance3D
var _body: StaticBody3D
var _mat: StandardMaterial3D
var _hot_mat: StandardMaterial3D
var _hover := {}                  # grabber id -> true
var _grab := {}                   # {id, start, offset}


func _ready() -> void:
	_mat = _flat(Color(0.35, 0.8, 1.0, 0.85))
	_hot_mat = _flat(Color(0.4, 1.0, 0.55, 0.95))
	_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = HANDLE_R
	sm.height = HANDLE_R * 2.0
	_mesh.mesh = sm
	_mesh.material_override = _mat
	add_child(_mesh)
	# A flat ring around the ball hints "slide me along the table".
	var ring := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = HANDLE_R * 1.5
	t.outer_radius = HANDLE_R * 1.9
	ring.mesh = t
	ring.material_override = _mat
	_mesh.add_child(ring)
	_body = StaticBody3D.new()
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.set_meta("xr_kb_handle", WHICH)
	_body.set_meta("xr_grab_target", self)
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = HANDLE_HIT_R
	cs.shape = sph
	_body.add_child(cs)
	add_child(_body)
	_refresh()


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 2
	return m


## The saved offset (game-frame metres).
static func saved_offset() -> Vector3:
	var v = Settings.get_value("xr_field_offset")
	if v is Array and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


## Where the playfield goes: the keyboard frame moved by the user's offset.
func placed(offset := saved_offset()) -> Transform3D:
	return base.translated_local(offset)


func active() -> bool:
	return game != null and game.in_ar and (not game.is_running() or not _grab.is_empty())


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var on := active()
	_mesh.visible = on
	_body.collision_layer = HANDLE_LAYER if on else 0
	if not on:
		return
	var x := game.station_x(0) - SIDE_M if not game.octaves.is_empty() else -SIDE_M
	var p := game.global_transform * Vector3(x, RAISE_M, 0.0)
	_mesh.global_transform = Transform3D(game.global_basis.orthonormalized(), p)
	_body.global_position = p
	_mesh.material_override = _hot_mat if (not _hover.is_empty() or not _grab.is_empty()) else _mat


# --- grab API (same as XRKeyboardOverlay) -----------------------------------

func handle_near(point: Vector3, radius: float) -> String:
	if not active():
		return ""
	return WHICH if _mesh.global_position.distance_to(point) < maxf(radius, HANDLE_HIT_R) else ""


func set_hover(id: int, which: String) -> void:
	if which == "":
		_hover.erase(id)
	else:
		_hover[id] = true


func begin_handle(id: int, _which: String, point: Vector3) -> void:
	if not _grab.is_empty():
		return
	_grab = {"id": id, "start": point, "offset": saved_offset()}


func update_handle(id: int, point: Vector3) -> void:
	if _grab.is_empty() or _grab["id"] != id:
		return
	# World drag -> game-frame offset (the frame basis is orthonormal).
	var d: Vector3 = base.basis.orthonormalized().inverse() * (point - _grab["start"])
	var off: Vector3 = (_grab["offset"] + d).clamp(Vector3.ONE * -MAX_OFFSET, Vector3.ONE * MAX_OFFSET)
	_grab["current"] = off
	game.global_transform = placed(off)


func end_handle(id: int) -> void:
	if _grab.is_empty() or _grab["id"] != id:
		return
	var off: Vector3 = _grab.get("current", _grab["offset"])
	_grab = {}
	Settings.set_value("xr_field_offset", [off.x, off.y, off.z])


func is_grabbed() -> bool:
	return not _grab.is_empty()
