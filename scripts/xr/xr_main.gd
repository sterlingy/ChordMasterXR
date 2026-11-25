extends Node3D
## XR entry scene (Android XR: Galaxy XR, Xreal Aura).
##
## - Passthrough: the camera feed shows your real hands and keyboard.
## - The same PracticeScreen used on desktop renders into a SubViewport,
##   shown on a floating panel in front of you.
## - Point at the panel with a hand or controller ray and pinch / pull the
##   trigger to click.
## - Touch buttons directly with your index fingertip.
## - Pinch the bar under the panel to move it; pinch a corner ball to
##   resize it (directly with your hand or with the ray).
## - "Name it": the answers float as 3D buttons within reach (point and
##   pinch, or press one with a fingertip).
## - Chord Defense on the real keyboard: pinch the blue ball left of the
##   stations to slide the playfield (between games).

const PANEL_SIZE := Vector2(0.36, 0.2025)      # metres (16:9) at scale 1
const PANEL_PIXELS := Vector2i(1600, 900)
const PANEL_DISTANCE := 0.85                    # metres in front of the eyes
const PANEL_DROP := 0.12                        # below eye level

var xr: XRInterface             # OpenXR (the type is missing in web builds)
var origin: XROrigin3D
var camera: XRCamera3D
var pointers: Array[XRPointer] = []
var panel: XRPanel
var keyboard_overlay: XRKeyboardOverlay
var _defense: DefenseView
var _field_handle: XRFieldHandle
var _defense_cal := []          # calibration the game was placed with


func _ready() -> void:
	# Web: a WebXR session (WebXRStereo) drives the trackers and renders the
	# eyes itself; no OpenXR interface.
	var web := WebXRStereo.instance
	var on_web := OS.has_feature("web") and web != null and is_instance_valid(web) and web.active
	var preview := not on_web and WebXRStereo.preview_requested()
	if on_web or preview:
		_add_environment()
	else:
		xr = XRServer.find_interface("OpenXR")
		if xr == null or not xr.is_initialized():
			push_warning("OpenXR not initialised; falling back to 2D.")
			get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
			return
		get_viewport().use_xr = true
		# Android XR: hand tracking (fingertip touch, pinch) needs the
		# HAND_TRACKING runtime permission; this asks for all dangerous
		# permissions declared in the manifest that aren't granted yet.
		if OS.has_feature("android"):
			OS.request_permissions()
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_enable_passthrough()

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	origin.add_child(camera)
	if on_web:
		web.origin = origin
	elif preview:
		camera.position.y = 1.5      # a standing head, looking ahead
		# Draw through a plain camera, like the WebXR eyes do.
		var view := Camera3D.new()
		camera.add_child(view)
		view.current = true
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--screenshot="):
				_preview_shot.call_deferred(a.trim_prefix("--screenshot="))

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

	panel = XRPanel.new()
	panel.panel_size = PANEL_SIZE
	panel.pixel_size = PANEL_PIXELS
	add_child(panel)
	panel.camera = camera
	var screen: Control = load("res://scenes/ui/practice_screen.tscn").instantiate()
	panel.set_content(screen)

	# Highlights on the real keyboard (after "Calibrate real keyboard").
	keyboard_overlay = XRKeyboardOverlay.new()
	keyboard_overlay.origin = origin
	keyboard_overlay.source = screen.get_node("%Keyboard")
	keyboard_overlay.calibration_status.connect(func(t: String): screen._show_feedback(t, UITheme.WARN))
	add_child(keyboard_overlay)

	_field_handle = XRFieldHandle.new()
	add_child(_field_handle)

	for hand in ["left_hand", "right_hand"]:
		var c := XRController3D.new()
		c.tracker = hand
		c.pose = "aim"
		origin.add_child(c)
		var touch := XRHandTouch.new()
		touch.hand = "left" if hand == "left_hand" else "right"
		touch.panel = panel
		touch.origin = origin
		add_child(touch)
		var p := XRPointer.new()
		p.panel = panel
		p.touch = touch
		p.kb = keyboard_overlay
		p.grabbables = [keyboard_overlay, _field_handle]
		c.add_child(p)
		pointers.append(p)

	# "Name it" answers float in front of you instead of sitting on the panel.
	screen.external_choices = true
	screen._apply_display_settings()
	var choice_buttons := XRChoiceButtons.new()
	choice_buttons.session = screen.session
	choice_buttons.camera = camera
	choice_buttons.panel = panel
	choice_buttons.origin = origin
	add_child(choice_buttons)
	for p in pointers:
		p.grabbables.append(choice_buttons)    # its move knob

	# Chord Defense: in the headset the game leaves the panel and sits on
	# the real keyboard (once it is calibrated).
	_defense = screen.get_node("%GameArea")
	_field_handle.game = _defense.game
	var t := Timer.new()
	t.wait_time = 0.5
	t.autostart = true
	t.timeout.connect(_update_defense_ar)
	add_child(t)

	if xr:
		if xr.has_signal("pose_recentered"):
			xr.connect("pose_recentered", _place_panel)
	# Wait for head tracking to settle before placing the panel.
	await get_tree().create_timer(0.6).timeout
	_place_panel()


func _enable_passthrough() -> void:
	var modes := xr.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		get_viewport().transparent_bg = true
	elif XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in modes:
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
	_add_environment()


## Dev: `-- --xrpreview --screenshot=<png>` saves the XR scene seen flat.
func _preview_shot(path: String) -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("SCREENSHOT ", path)
	get_tree().quit()


## Clear background (the room shows through) and flat ambient light.
func _add_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.8)
	env.environment = e
	add_child(env)


## Moves the Chord Defense game between the panel and the real keyboard.
func _update_defense_ar() -> void:
	if _defense == null:
		return
	var game := _defense.game
	var cal = Settings.get_value("xr_keyboard_cal")
	var want: bool = Settings.get_value("practice_mode") == "defense" and keyboard_overlay.is_calibrated()
	var key := [cal, Settings.get_value("xr_field_offset")]
	if _field_handle.is_grabbed():
		return
	if want and (not game.in_ar or _defense_cal != key):
		if game.get_parent() != self:
			game.reparent(self, false)
		var frame := DefenseGame.ar_frame(keyboard_overlay.layout,
				int(Settings.get_value("range_low")), int(Settings.get_value("range_high")))
		_field_handle.base = frame[0]
		game.enter_ar(_field_handle.placed(), frame[1], frame[2])
		_defense.set_ar(true)
		_defense_cal = key
	elif not want and game.in_ar:
		game.reparent(_defense.viewport(), false)
		game.exit_ar()
		_defense.set_ar(false)
		_defense_cal = []


## Puts the panel in front of where the user is looking, level with the floor.
func _place_panel() -> void:
	var head := camera.global_transform
	var fwd := -head.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	panel.global_position = head.origin + fwd * PANEL_DISTANCE + Vector3.DOWN * PANEL_DROP
	panel.face_camera()


func _unhandled_input(event: InputEvent) -> void:
	# Keyboard shortcut for desktop XR testing: R recentres the panel.
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_place_panel()
