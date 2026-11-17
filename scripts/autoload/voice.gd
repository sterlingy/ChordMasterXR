extends Node
## Text-to-speech chord callouts. Autoloaded as `Voice`.
## Uses the operating system's TTS through DisplayServer; requires the
## project setting audio/general/text_to_speech = true.


func available() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH) and not voices().is_empty()


func voices() -> Array:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return []
	return DisplayServer.tts_get_voices()


func say(text: String) -> void:
	if not available():
		return
	var id: String = Settings.get_value("voice_id")
	if id == "":
		var list := DisplayServer.tts_get_voices_for_language(OS.get_locale_language())
		if list.is_empty():
			list = DisplayServer.tts_get_voices_for_language("en")
		if not list.is_empty():
			id = list[0]
		else:
			id = voices()[0]["id"]
	DisplayServer.tts_stop()
	DisplayServer.tts_speak(text, id, 100, 1.0, float(Settings.get_value("voice_rate")))


## "C sharp minor seven flat five", "G seven, 1st inversion".
func say_prompt(p: ChordPrompt) -> void:
	say(p.spoken())
