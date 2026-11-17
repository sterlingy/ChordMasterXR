@tool
extends EditorPlugin
## Adds the ChordMasterMidi Android library to Android exports.
## Source: res://android_plugin (rebuild with `gradlew copyToGodot`).

var _export_plugin: AndroidMidiExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidMidiExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class AndroidMidiExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "ChordMasterMidi"

	func _get_name() -> String:
		return PLUGIN_NAME

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		if debug:
			return PackedStringArray(["chordmaster_midi/bin/ChordMasterMidi-debug.aar"])
		return PackedStringArray(["chordmaster_midi/bin/ChordMasterMidi-release.aar"])
