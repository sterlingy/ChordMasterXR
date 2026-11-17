extends Node
## Global user settings, saved to user://settings.cfg.
## Autoloaded as `Settings`. Emits `changed(key)` whenever a value is set.

signal changed(key: String)

var PATH := "user://settings.cfg"

const DEFAULTS := {
	# Input
	"input_mode": "midi",          # "midi" | "select" (virtual keyboard select+submit)
	"midi_channel": -1,
	"qwerty_input": false,         # play notes on the computer keyboard            # -1 = Omni, else 0..15
	# Wi-Fi MIDI relay
	"net_send": false,             # forward this device's MIDI over Wi-Fi
	"net_receive": null,           # null = auto (on for Android/XR only)
	"net_target": "",              # receiver IP, "" = auto-discover
	"range_low": 48,               # C3
	"range_high": 84,              # C6 (≈ a 37-key board)
	# Prompt display
	"show_chord_name": true,       # chord name above the notation
	"show_notes": false,           # note names under the notation
	"show_keyboard_hint": false,   # highlight the chord on the on-screen keyboard
	"show_staff": true,
	"clef_mode": "auto",           # "auto" | "treble" | "bass" | "grand"
	"accidental_mode": "accidentals",  # "accidentals" | "key_signature"
	# Sound
	"play_on_prompt": false,       # play the chord when it appears
	"play_on_correct": true,       # play the chord after a correct answer
	"echo_input": true,            # sound the notes you press (mute if your keyboard has its own sound)
	"sound_output": "internal",    # "internal" | "midi_out" (later)
	"volume_db": -6.0,
	"voice_callout": false,        # speak the chord name via text-to-speech
	"voice_id": "",
	"voice_rate": 1.0,
	# Rules
	"strict_inversion": false,
	"random_inversions": true,     # in strict mode, ask for varied inversions
	"octave_mode": false,
	"target_octave": 4,            # -1 = random octave
	"advance_delay": 0.6,          # seconds after a correct answer
	# Exercise
	"exercise_type": "smart",
	"practice_mode": "play",       # "play" | "name" | "song"
	# Song mode
	"song_id": "let_it_be",
	"song_bpm": {},                # song id -> chosen BPM (absent = song's own tempo)
	"song_transpose": {},          # song id -> semitones             # tempo multiplier (0.5–1.25)
	"metronome_on": true,
	"song_count_in": true,
	"song_backing": false,         # play each chord as it comes up
	# Chord Defense (game)
	"player_name": "Player",       # shown on the leaderboards
	"defense_use_pool": false,     # attack with my chord pool instead of the sectors' chords
	"leaderboard_url": "",         # global leaderboard endpoint ("" = local only)
	"name_choices": 4,             # 3..5
	"pool": {},                    # ChordPool.to_dict()
	"xr_keyboard_cal": null,       # real-keyboard calibration (XR overlay)
	"xr_kb_show": true,            # show the virtual keyboard over the real one
	"xr_kb_opacity": 0.5,          # overlay key opacity (highlights stay strong)
	"xr_kb_lift_mm": 0.0,          # nudge the overlay up/down
	"xr_kb_adjust": false,         # show the overlay's drag handles
	"xr_kb_step": "normal",        # nudge step: "fine" | "normal" | "coarse"
	"xr_keyboard_cal_base": null,  # calibration before any adjustments
	"xr_panel_scale": 1.0,         # XR panel size multiplier (1.0 = 36 cm wide)
}

var _values := {}


## True when launched by automated checks (`-- --screenshot=...`); those
## runs use separate settings/stats files so they never touch real ones.
static func is_dev_run() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screenshot="):
			return true
	return false


func _ready() -> void:
	if is_dev_run():
		PATH = "user://dev_settings.cfg"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	load_settings()


func get_value(key: String):
	return _values.get(key, DEFAULTS.get(key))


func set_value(key: String, value) -> void:
	if _values.get(key) == value:
		return
	_values[key] = value
	save_settings()
	changed.emit(key)


func pool() -> ChordPool:
	var d: Dictionary = get_value("pool")
	if d.is_empty():
		return ChordPool.from_preset("Major & minor")
	return ChordPool.from_dict(d)


func set_pool(p: ChordPool) -> void:
	set_value("pool", p.to_dict())


func load_settings() -> void:
	_values = DEFAULTS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for key in DEFAULTS:
		if cfg.has_section_key("settings", key):
			_values[key] = cfg.get_value("settings", key)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in _values:
		cfg.set_value("settings", key, _values[key])
	cfg.save(PATH)


func reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate(true)
	save_settings()
	for key in _values:
		changed.emit(key)


## Copies the rule settings onto an engine.
func apply_to_engine(e: ExerciseEngine) -> void:
	e.range_low = get_value("range_low")
	e.range_high = get_value("range_high")
	e.strict_inversion = get_value("strict_inversion")
	e.random_inversions = get_value("random_inversions")
	e.octave_mode = get_value("octave_mode")
	e.target_octave = get_value("target_octave")
