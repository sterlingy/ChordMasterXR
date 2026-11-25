extends Node
## Entry point (scenes/main.tscn). The practice screen is a child of this
## scene, so it shows up in the editor. When an OpenXR runtime is available
## (Android XR headsets) we switch to the XR scene instead.
##
## Dev helper: `godot --path . -- --screenshot=C:/tmp/shot.png [--script=name]`
## saves a screenshot after a moment and quits (used for automated checks).

const XR_SCENE := "res://scenes/xr_main.tscn"


func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR")
	var want_xr := xr != null and xr.is_initialized() and not OS.has_feature("web")
	if want_xr and ResourceLoader.exists(XR_SCENE):
		get_tree().change_scene_to_file.call_deferred(XR_SCENE)
		return
	# Web: an "Enter AR" button starts a WebXR session in headset browsers
	# (the session then switches to the XR scene).
	WebXRStereo.ensure(get_tree())
	if WebXRStereo.preview_requested() and ResourceLoader.exists(XR_SCENE):
		get_tree().change_scene_to_file.call_deferred(XR_SCENE)
		return
	var screen := get_node_or_null("PracticeScreen") as PracticeScreen
	if screen:
		_dev_args(screen)


func _dev_args(screen: PracticeScreen) -> void:
	var shot := ""
	var script_name := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screenshot="):
			shot = a.trim_prefix("--screenshot=")
		elif a.begins_with("--script="):
			script_name = a.trim_prefix("--script=")
	if shot == "":
		return
	await get_tree().create_timer(1.0).timeout
	if script_name != "":
		await DevScripts.run(script_name, screen)
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("SCREENSHOT ", shot)
	get_tree().quit()
