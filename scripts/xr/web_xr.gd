class_name WebXRStereo
extends Node
## WebXR AR in the browser (Chrome on Galaxy XR / Android XR, Quest Browser).
##
## Ported from the Shivoo XR plugin's webxr_stereo.gd (without its XR Tools
## dependency); web/webxr_stereo.js is the plugin's page script, unchanged.
## Chrome on Android XR has no OVR_multiview2, so Godot's own WebXR interface
## can't run there. The page script runs the session instead, and this node
## renders each eye into its own SubViewport, side by side on the canvas, for
## the script to copy into the headset.
##
## It also feeds the same trackers the OpenXR rig reads: "head",
## "left_hand"/"right_hand" (aim/grip poses, pinch as trigger) and
## "/user/hand_tracker/<side>" finger joints. So scenes/xr_main.tscn works
## unchanged once a session runs.
##
## Lives under the tree root (it outlives scene changes): main.gd adds it
## on web and shows an "Enter AR" button; a session start switches to the
## XR scene and its end switches back to the flat app.

signal session_started
signal session_ended

const STEREO_JS := "res://web/webxr_stereo.js"
const XR_SCENE := "res://scenes/xr_main.tscn"
const FLAT_SCENE := "res://scenes/main.tscn"
const BUTTON_NAMES: Array[StringName] = [
	&"trigger_click", &"grip_click", &"touchpad_click", &"thumbstick_click", &"ax_button", &"by_button",
]
const PRESSURE_NAMES: Array[StringName] = [
	&"trigger", &"grip", &"touchpad_click_pressure", &"thumbstick_click_pressure",
	&"ax_button_pressure", &"by_button_pressure",
]
const AXIS_NAMES: Array[StringName] = [&"touchpad_x", &"touchpad_y", &"thumbstick_x", &"thumbstick_y"]
## Godot's WebXR interface turns each joint by this to match its humanoid hand skeleton.
const HUMANOID_JOINT := Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, -1.0, 0.0))

## Shown next to the Enter AR button, so a headset shows which build it runs.
const BUILD := "web AR 4"

static var instance: WebXRStereo

## Set by the XR scene once it has built its rig; eyes render from it.
var origin: XROrigin3D
## True while a headset session runs.
var active := false
## True while the session shows the room behind the scene.
var passthrough_active := false

var _stereo: JavaScriptObject
var _callbacks: Array[JavaScriptObject] = []
var _head: XRPositionalTracker
var _hands := {}
var _hand_trackers := {}
var _layer: CanvasLayer
var _eyes: Array[SubViewport] = []
var _eye_cameras: Array[Camera3D] = []
var _eye_scale := 1.0
var _msaa := Viewport.MSAA_4X
var _button_layer: CanvasLayer
var _button: Button
var _build_label: Label
## ?xrdebug=1: a status readout floating in front of you during the session.
var _debug := false
var _debug_label: Label3D
var _frames := 0
var _head_pose := Transform3D()


## Adds the node under the root once (web only). Safe to call every time the
## flat scene loads.
static func ensure(tree: SceneTree) -> WebXRStereo:
	if not OS.has_feature("web"):
		return null
	if instance == null or not is_instance_valid(instance):
		instance = WebXRStereo.new()
		instance.name = "WebXRStereo"
		tree.root.add_child.call_deferred(instance)
	return instance


## Dev: ?xrpreview=1 opens the XR scene flat in any browser (no session), to
## check it builds and renders without a headset.
## Also `-- --xrpreview` on desktop.
static func preview_requested() -> bool:
	if not OS.has_feature("web"):
		return "--xrpreview" in OS.get_cmdline_user_args()
	return str(JavaScriptBridge.eval("location.search", true)).contains("xrpreview")


func _ready() -> void:
	set_process(false)
	# Before other scripts read the controllers, so hands match this frame's pose.
	process_priority = -100
	JavaScriptBridge.eval(FileAccess.get_file_as_string(STEREO_JS), true)
	_stereo = JavaScriptBridge.get_interface("ShivooStereo")
	if _stereo == null or not _stereo.needsFallback():
		return
	_stereo.install()
	_read_test_switches()
	_debug = not str(_stereo.param("xrdebug")).is_empty()
	print("WebXR: ", BUILD)
	_build_button()
	_show_button_when_known()


func _build_button() -> void:
	_button_layer = CanvasLayer.new()
	_button_layer.layer = 100
	add_child(_button_layer)
	_button = Button.new()
	_button.text = "Enter AR"
	_button.tooltip_text = "Put the app in your room (needs an XR headset's browser)"
	_button.add_theme_font_size_override("font_size", 22)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.25, 0.55, 1.0)
	box.set_corner_radius_all(10)
	box.content_margin_left = 18
	box.content_margin_right = 18
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	_button.add_theme_stylebox_override("normal", box)
	var hover := box.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.35, 0.65, 1.0)
	_button.add_theme_stylebox_override("hover", hover)
	_button.add_theme_stylebox_override("pressed", hover)
	_button.add_theme_color_override("font_color", Color.WHITE)
	_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_button.visible = false
	_button.pressed.connect(enter)
	_button_layer.add_child(_button)
	_build_label = Label.new()
	_build_label.text = BUILD
	_build_label.add_theme_font_size_override("font_size", 12)
	_build_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	_build_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 4)
	_build_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_build_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_build_label.visible = false
	_button_layer.add_child(_build_label)
	_button.visibility_changed.connect(func(): _build_label.visible = _button.visible)


## The support probe answers a moment after load. Show the button only where
## an immersive session is possible (AR preferred; VR still works, on black).
func _show_button_when_known() -> void:
	for attempt in 40:
		var ar := str(_stereo.arSupported)
		var vr := str(_stereo.vrSupported)
		if ar == "yes":
			_button.text = "Enter AR"
			_button.visible = true
			return
		if ar != "pending" and vr == "yes":
			_button.text = "Enter VR"
			_button.visible = true
			return
		if ar != "pending" and vr != "pending":
			print("WebXR: no immersive session here (ar %s, vr %s)" % [ar, vr])
			return
		await get_tree().create_timer(0.25).timeout


func set_button_visible(shown: bool) -> void:
	if _button and (str(_stereo.arSupported) == "yes" or str(_stereo.vrSupported) == "yes"):
		_button.visible = shown and not active


## Starts the headset session. Call from a click (browsers need the user gesture).
func enter() -> void:
	if active or _stereo == null:
		return
	var ar := str(_stereo.arSupported) != "no"
	_callbacks = [
		JavaScriptBridge.create_callback(_on_session_started),
		JavaScriptBridge.create_callback(_on_session_ended),
		JavaScriptBridge.create_callback(_on_session_failed),
	]
	_stereo.start(_callbacks[0], _callbacks[1], _callbacks[2], "immersive-ar" if ar else "immersive-vr")


func exit() -> void:
	if _stereo:
		_stereo.end()


func _process(_delta: float) -> void:
	var json := str(_stereo.frameJson)
	if json.is_empty():
		return
	var frame = JSON.parse_string(json)
	if not frame is Dictionary:
		return
	_frames += 1
	if frame["head"] != null:
		_head_pose = _to_transform(frame["head"], false)
		_head.set_pose(&"default", _head_pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_update_hands(frame["inputs"])
	var has_origin := origin != null and is_instance_valid(origin)
	# Without an XR scene (yet), render from the reference space after a
	# moment, so the debug readout still shows.
	if has_origin or _frames > 30:
		_update_eyes(origin.global_transform if has_origin else Transform3D.IDENTITY, frame["views"])
	if _debug:
		_update_debug(frame)


## The readout floats 0.6 m ahead of the head, so it shows even when the XR
## scene failed to build.
func _update_debug(frame: Dictionary) -> void:
	if _debug_label == null:
		_debug_label = Label3D.new()
		_debug_label.pixel_size = 0.0006
		_debug_label.font_size = 32
		_debug_label.outline_size = 8
		_debug_label.no_depth_test = true
		_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(_debug_label)
	var base := origin.global_transform if origin != null and is_instance_valid(origin) else Transform3D.IDENTITY
	var head := base * _head_pose
	_debug_label.global_position = head.origin - head.basis.z * 0.6 + Vector3.DOWN * 0.1
	if _frames % 15 != 0:
		return
	var scene := get_tree().current_scene
	var camera := _find_xr_camera()
	var inputs := ""
	for input: Dictionary in frame["inputs"]:
		inputs += "\n%s %s hand %s pinch %.2f select %s squeeze %s pad %d" % [
			input["hand"], input["profile"], input.get("isHand", false), input.get("pinch", 0.0),
			input.get("select", false), input.get("squeeze", false), (input["buttons"] as Array).size()]
	_debug_label.text = "%s  %s  %s\nscene %s  origin %s\nviews %d  eyes %s\nhead %s\ncamera %s\nhands %s  joints %s  frames %d" % [
		BUILD, str(_stereo.sessionMode), str(_stereo.referenceSpaceType),
		scene.name if scene else "none", "yes" if origin != null and is_instance_valid(origin) else "no",
		(frame["views"] as Array).size(), str(_eyes.map(func(e): return e.size)),
		_head_pose.origin.snapped(Vector3.ONE * 0.01),
		camera.global_position.snapped(Vector3.ONE * 0.01) if camera else "none",
		str(_hands.keys()), str(_hand_trackers.keys()), _frames,
	] + inputs


## ?eyescale=0.5 renders each eye at half size, ?msaa=0|2|4|8 sets antialiasing.
func _read_test_switches() -> void:
	var scale := str(_stereo.param("eyescale"))
	if not scale.is_empty():
		_eye_scale = clampf(scale.to_float(), 0.1, 1.0)
	match str(_stereo.param("msaa")):
		"0":
			_msaa = Viewport.MSAA_DISABLED
		"2":
			_msaa = Viewport.MSAA_2X
		"8":
			_msaa = Viewport.MSAA_8X


func _on_session_started(_args: Array) -> void:
	_begin.call_deferred()


func _on_session_ended(_args: Array) -> void:
	_end.call_deferred()


func _on_session_failed(args: Array) -> void:
	OS.alert("Unable to enter AR: " + str(args[0] if args.size() > 0 else "unknown error"))


func _begin() -> void:
	active = true
	_button.visible = false
	_head = XRPositionalTracker.new()
	_head.type = XRServer.TRACKER_HEAD
	_head.name = &"head"
	XRServer.add_tracker(_head)
	_layer = CanvasLayer.new()
	_layer.layer = 128
	add_child(_layer)
	# The eyes and the page canvas keep alpha so the headset shows the room behind them.
	passthrough_active = str(_stereo.sessionMode) == "immersive-ar"
	get_viewport().transparent_bg = passthrough_active
	get_viewport().disable_3d = true
	set_process(true)
	print("WebXR: session started (%s)" % str(_stereo.sessionMode))
	get_tree().change_scene_to_file(XR_SCENE)
	session_started.emit()


func _end() -> void:
	if not active:
		return
	active = false
	set_process(false)
	for tracker in _hands.values():
		XRServer.remove_tracker(tracker)
	_hands.clear()
	for tracker in _hand_trackers.values():
		XRServer.remove_tracker(tracker)
	_hand_trackers.clear()
	XRServer.remove_tracker(_head)
	_head = null
	_clear_eyes()
	if _debug_label:
		_debug_label.queue_free()
		_debug_label = null
	_frames = 0
	_layer.queue_free()
	_layer = null
	origin = null
	get_viewport().disable_3d = false
	passthrough_active = false
	get_viewport().transparent_bg = false
	print("WebXR: session ended")
	get_tree().change_scene_to_file(FLAT_SCENE)
	_button.visible = true
	session_ended.emit()


func _update_hands(inputs: Array) -> void:
	var seen := {}
	for input: Dictionary in inputs:
		var hand: String = input["hand"]
		if hand != "left" and hand != "right":
			continue
		seen[hand] = true
		var tracker: XRControllerTracker = _hands.get(hand)
		if tracker == null:
			tracker = XRControllerTracker.new()
			tracker.type = XRServer.TRACKER_CONTROLLER
			tracker.name = StringName(hand + "_hand")
			tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
			tracker.profile = input["profile"]
			XRServer.add_tracker(tracker)
			_hands[hand] = tracker
		_set_pose(tracker, &"default", input["aim"])
		_set_pose(tracker, &"aim", input["aim"])
		_set_pose(tracker, &"grip", input["grip"])
		_update_inputs(tracker, input)
		_update_hand_joints(hand, input.get("joints"))
	for hand in _hands.keys():
		if not seen.has(hand):
			XRServer.remove_tracker(_hands[hand])
			_hands.erase(hand)
	for hand in _hand_trackers.keys():
		if not seen.has(hand):
			_update_hand_joints(hand, null)


## Same /user/hand_tracker/<side> trackers Godot's WebXR and OpenXR interfaces make.
func _update_hand_joints(hand: String, joints) -> void:
	var tracker: XRHandTracker = _hand_trackers.get(hand)
	if not joints is Array or (joints as Array).size() < 25 * 16:
		if tracker:
			tracker.has_tracking_data = false
			tracker.invalidate_pose(&"default")
		return
	if tracker == null:
		tracker = XRHandTracker.new()
		tracker.name = StringName("/user/hand_tracker/" + hand)
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
		var flags := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID \
				| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
		for joint in XRHandTracker.HAND_JOINT_MAX:
			tracker.set_hand_joint_flags(joint, flags)
		XRServer.add_tracker(tracker)
		_hand_trackers[hand] = tracker
	tracker.has_tracking_data = true
	# WebXR has no palm joint; Godot's index 0 is the palm, so WebXR joint i is Godot joint i + 1.
	for i in 25:
		var joint := _to_transform(joints, false, i * 16)
		joint.basis *= HUMANOID_JOINT
		tracker.set_hand_joint_transform(i + 1, joint)
	var palm := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL)
	palm.origin = (palm.origin + tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL).origin) * 0.5
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, palm)
	tracker.set_pose(&"default", palm, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _set_pose(tracker: XRControllerTracker, pose: StringName, matrix) -> void:
	if matrix == null:
		tracker.invalidate_pose(pose)
	else:
		tracker.set_pose(pose, _to_transform(matrix, false), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Same input names as Godot's WebXR interface.
func _update_inputs(tracker: XRControllerTracker, input: Dictionary) -> void:
	var standard: bool = input["standard"]
	var buttons: Array = input["buttons"]
	for i in buttons.size():
		var value: float = buttons[i]
		var named := standard and i < BUTTON_NAMES.size()
		tracker.set_input(BUTTON_NAMES[i] if named else StringName("button_%d" % i), value > 0.0)
		tracker.set_input(PRESSURE_NAMES[i] if named else StringName("button_pressure_%d" % i), value)
	var axes: Array = input["axes"]
	for i in axes.size():
		var value: float = axes[i]
		if standard and i < AXIS_NAMES.size():
			tracker.set_input(AXIS_NAMES[i], -value if i == 1 or i == 3 else value)
		else:
			tracker.set_input(StringName("axis_%d" % i), value)
	# Hands have no gamepad: the page script's pinch stands in for the trigger
	# (what XRPointer clicks with), as in OpenXR's hand interaction profile.
	var select: bool = input.get("select", false)
	var squeeze: bool = input.get("squeeze", false)
	if input.get("isHand", false):
		var grasp: float = input.get("grasp", 0.0)
		var pinch: float = input.get("pinch", 0.0)
		tracker.set_input(&"grip", maxf(grasp, 1.0 if squeeze else 0.0))
		tracker.set_input(&"grip_click", grasp > 0.5 or squeeze)
		tracker.set_input(&"trigger", maxf(pinch, 1.0 if select else 0.0))
		tracker.set_input(&"trigger_click", pinch > 0.5 or select)
	elif select or squeeze:
		# The browser's select/squeeze also covers sources with no gamepad
		# (gaze-and-pinch, transient pointers).
		if select:
			tracker.set_input(&"trigger", 1.0)
			tracker.set_input(&"trigger_click", true)
		if squeeze:
			tracker.set_input(&"grip", 1.0)
			tracker.set_input(&"grip_click", true)
	tracker.set_input(&"select", select)


func _update_eyes(base: Transform3D, views: Array) -> void:
	if views.size() != _eyes.size():
		_build_eyes(views.size())
	for i in views.size():
		var view: Dictionary = views[i]
		var box: Array = view["viewport"]
		var size := _eye_size(box, view["projection"])
		# A one-pixel change recreates the eye target and the picture flashes.
		if _eyes[i].size != Vector2i.ZERO and absi(_eyes[i].size.x - size.x) < 16 and absi(_eyes[i].size.y - size.y) < 16:
			size = _eyes[i].size
		if _eyes[i].size != size:
			_eyes[i].size = size
		var camera := _eye_cameras[i]
		camera.global_transform = base * _to_transform(view["transform"])
		_apply_projection(camera, view["projection"])


## The eye must have the projection's shape or the picture is squashed; the
## copy stretches it back into the headset viewport. Same pixel count.
func _eye_size(box: Array, p: Array) -> Vector2i:
	var pixels := float(box[2]) * float(box[3]) * _eye_scale * _eye_scale
	var aspect: float = p[5] / p[0]
	return Vector2i(maxi(1, roundi(sqrt(pixels * aspect))), maxi(1, roundi(sqrt(pixels / aspect))))


func _build_eyes(count: int) -> void:
	_clear_eyes()
	var world := get_viewport().find_world_3d()
	var xr_camera := _find_xr_camera()
	for i in count:
		var viewport := SubViewport.new()
		viewport.world_3d = world
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.transparent_bg = passthrough_active
		viewport.msaa_3d = _msaa
		viewport.audio_listener_enable_3d = i == 0
		add_child(viewport)
		var camera := Camera3D.new()
		if xr_camera:
			camera.near = xr_camera.near
			camera.far = xr_camera.far
			camera.cull_mask = xr_camera.cull_mask
		viewport.add_child(camera)
		camera.current = true
		var rect := TextureRect.new()
		rect.texture = viewport.get_texture()
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.anchor_left = float(i) / count
		rect.anchor_right = float(i + 1) / count
		rect.anchor_bottom = 1.0
		_layer.add_child(rect)
		_eyes.append(viewport)
		_eye_cameras.append(camera)


func _clear_eyes() -> void:
	for viewport in _eyes:
		viewport.queue_free()
	_eyes.clear()
	_eye_cameras.clear()
	if _layer:
		for child in _layer.get_children():
			child.queue_free()


## Converts the WebXR projection matrix into an off-center frustum at the near plane.
func _apply_projection(camera: Camera3D, p: Array) -> void:
	var near := camera.near
	var left: float = (p[8] - 1.0) / p[0]
	var right: float = (p[8] + 1.0) / p[0]
	var bottom: float = (p[9] - 1.0) / p[5]
	var top: float = (p[9] + 1.0) / p[5]
	var offset := Vector2(left + right, bottom + top) * 0.5 * near
	camera.set_frustum((top - bottom) * near, offset, near, camera.far)


func _find_xr_camera() -> XRCamera3D:
	if origin == null or not is_instance_valid(origin):
		return null
	for child in origin.get_children():
		if child is XRCamera3D:
			return child
	return null


## WebXR matrices are column-major, in meters, relative to the reference space.
## XRPose applies world scale itself, so tracker poses pass scaled = false.
func _to_transform(m: Array, scaled := true, offset := 0) -> Transform3D:
	var basis := Basis(Vector3(m[offset], m[offset + 1], m[offset + 2]), Vector3(m[offset + 4], m[offset + 5], m[offset + 6]),
			Vector3(m[offset + 8], m[offset + 9], m[offset + 10]))
	var position := Vector3(m[offset + 12], m[offset + 13], m[offset + 14])
	return Transform3D(basis, position * XRServer.world_scale if scaled else position)
