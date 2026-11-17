class_name XRHandTouch
extends Node3D
## Lets a tracked hand press buttons on an XRPanel by touching it with the
## index fingertip, like a touch screen.
##
##   finger within HOVER_M in front of the panel -> hover (cursor follows)
##   finger reaches the surface (PRESS_M)         -> press
##   finger pulls back past RELEASE_M or leaves    -> release
##
## Also reports the thumb/index pinch point so grabs are precise.

const HOVER_M := 0.04
const PRESS_M := 0.008
const RELEASE_M := 0.02

var hand := "right"                  # "left" | "right"
var panel: XRPanel
var origin: XROrigin3D
var near_panel := false              # finger close to the panel (pointer hides its ray)

var _pressed := false
var _last_px := Vector2.ZERO
var _ring: MeshInstance3D


func _ready() -> void:
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.004
	torus.outer_radius = 0.006
	_ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.36, 0.62, 1.0, 0.85)
	_ring.material_override = mat
	_ring.top_level = true
	_ring.visible = false
	add_child(_ring)


func _tracker() -> XRHandTracker:
	return XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker


func _joint(t: XRHandTracker, j: XRHandTracker.HandJoint) -> Vector3:
	var tf := t.get_hand_joint_transform(j)
	return (origin.global_transform * tf).origin if origin else tf.origin


## Midpoint between thumb tip and index tip, or null without hand tracking.
func pinch_point() -> Variant:
	var t := _tracker()
	if t == null or not t.has_tracking_data:
		return null
	return (_joint(t, XRHandTracker.HAND_JOINT_THUMB_TIP) + _joint(t, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)) * 0.5


func _physics_process(_delta: float) -> void:
	var t := _tracker()
	if t == null or not t.has_tracking_data or panel == null:
		_leave()
		return
	var tip := _joint(t, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	var local := panel.to_local(tip)
	var dist_m := local.z * panel.scale.z        # + in front of the panel
	var px: Variant = panel.world_to_pixels(tip)
	near_panel = px != null and dist_m > -0.03 and dist_m < 0.10
	if px == null or dist_m > HOVER_M or dist_m < -0.05:
		_leave()
		return
	_last_px = px
	panel.pointer_move(px)
	_ring.visible = true
	_ring.global_position = panel.to_global(Vector3(local.x, local.y, 0.002 / maxf(panel.scale.z, 0.01)))
	_ring.global_basis = panel.global_basis.orthonormalized() * Basis(Vector3.RIGHT, PI / 2.0)
	var col: Color = Color(0.35, 0.85, 0.5, 0.95) if _pressed else Color(0.36, 0.62, 1.0, 0.85)
	(_ring.material_override as StandardMaterial3D).albedo_color = col
	if not _pressed and dist_m <= PRESS_M:
		_pressed = true
		panel.pointer_button(px, true)
	elif _pressed and dist_m >= RELEASE_M:
		_pressed = false
		panel.pointer_button(px, false)


func _leave() -> void:
	if _pressed:
		_pressed = false
		panel.pointer_button(_last_px, false)
	_ring.visible = false
	near_panel = false
