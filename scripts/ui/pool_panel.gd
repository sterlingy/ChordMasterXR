class_name PoolPanel
extends PopupPanel
## Choose which chords can come up: one-tap presets, or build a pool from
## qualities x roots, a key's diatonic chords, or a custom list.

signal pool_applied

## Layout: scenes/ui/pool_panel.tscn. The preset buttons and the chord
## type / root checkboxes are generated from the theory data at runtime so
## they always match what the engine supports.

const KEY_TONICS := ["C", "G", "D", "A", "E", "B", "F#", "C#", "F", "Bb", "Eb", "Ab", "Db", "Gb", "Cb"]
const KEY_SCALES := [["major", "major"], ["natural minor", "natural_minor"], ["harmonic minor", "harmonic_minor"]]
const EXTRA_ROOTS := ["C#", "D#", "Gb", "G#", "A#", "Cb", "Fb", "E#", "B#"]

var _pool: ChordPool
var _quality_checks := {}
var _root_checks := {}

@onready var _source_tabs: TabContainer = %SourceTabs
@onready var _key_tonic: OptionButton = %KeyTonic
@onready var _key_scale: OptionButton = %KeyScale
@onready var _key_triads: CheckBox = %KeyTriads
@onready var _key_sevenths: CheckBox = %KeySevenths
@onready var _custom: TextEdit = %CustomText
@onready var _summary: Label = %Summary


func _ready() -> void:
	for preset_name in ChordPool.PRESETS:
		var n: String = preset_name
		%PresetFlow.add_child(UITheme.button(n, func(): _load(ChordPool.from_preset(n))))
	for id in Theory.QUALITY_ORDER:
		var c := CheckBox.new()
		var sym: String = Theory.QUALITIES[id]["symbol"]
		c.text = "maj" if sym == "" else sym
		c.tooltip_text = Theory.QUALITIES[id]["spoken"]
		c.toggled.connect(func(_on): _update_summary())
		%QualityFlow.add_child(c)
		_quality_checks[id] = c
	var roots := Theory.DEFAULT_ROOTS.duplicate()
	roots.append_array(EXTRA_ROOTS)
	for root_name in roots:
		var c := CheckBox.new()
		c.text = Theory.parse_note(root_name).pretty()
		c.toggled.connect(func(_on): _update_summary())
		%RootFlow.add_child(c)
		_root_checks[root_name] = c
	%AllRoots.pressed.connect(func(): _set_roots(Theory.DEFAULT_ROOTS))
	%NaturalRoots.pressed.connect(func(): _set_roots(["C", "D", "E", "F", "G", "A", "B"]))
	%ClearRoots.pressed.connect(func(): _set_roots([]))

	_key_tonic.clear()
	for k in KEY_TONICS:
		_key_tonic.add_item(Theory.parse_note(k).pretty())
		_key_tonic.set_item_metadata(_key_tonic.item_count - 1, k)
	_key_scale.clear()
	for sc in KEY_SCALES:
		_key_scale.add_item(sc[0])
		_key_scale.set_item_metadata(_key_scale.item_count - 1, sc[1])
	_key_tonic.item_selected.connect(func(_i): _update_summary())
	_key_scale.item_selected.connect(func(_i): _update_summary())
	_key_triads.toggled.connect(func(_on): _update_summary())
	_key_sevenths.toggled.connect(func(_on): _update_summary())
	_custom.text_changed.connect(_update_summary)
	_source_tabs.tab_changed.connect(func(_i): _update_summary())
	%CancelButton.pressed.connect(hide)
	%ApplyButton.pressed.connect(_apply)


func open() -> void:
	_load(Settings.pool())
	popup_centered()


func _set_roots(names: Array) -> void:
	for n in _root_checks:
		_root_checks[n].set_pressed_no_signal(names.has(n))
	_update_summary()


func _load(p: ChordPool) -> void:
	_pool = p
	for id in _quality_checks:
		_quality_checks[id].set_pressed_no_signal(p.qualities.has(id))
	for n in _root_checks:
		_root_checks[n].set_pressed_no_signal(p.roots.has(n))
	for i in _key_tonic.item_count:
		if _key_tonic.get_item_metadata(i) == p.key_tonic:
			_key_tonic.select(i)
	for i in _key_scale.item_count:
		if _key_scale.get_item_metadata(i) == p.key_scale:
			_key_scale.select(i)
	_key_triads.set_pressed_no_signal(p.key_triads)
	_key_sevenths.set_pressed_no_signal(p.key_sevenths)
	_custom.text = " ".join(p.custom)
	_source_tabs.current_tab = ["filter", "key", "custom"].find(p.source)
	_update_summary()


func _collect() -> ChordPool:
	var p := ChordPool.new()
	p.source = ["filter", "key", "custom"][_source_tabs.current_tab]
	p.qualities = []
	for id in Theory.QUALITY_ORDER:
		if _quality_checks[id].button_pressed:
			p.qualities.append(id)
	p.roots = []
	for n in _root_checks:
		if _root_checks[n].button_pressed:
			p.roots.append(n)
	p.key_tonic = _key_tonic.get_item_metadata(_key_tonic.selected)
	p.key_scale = _key_scale.get_item_metadata(_key_scale.selected)
	p.key_triads = _key_triads.button_pressed
	p.key_sevenths = _key_sevenths.button_pressed
	var words := _custom.text.replace(",", " ").split(" ", false)
	p.custom = Array(words)
	return p


func _update_summary() -> void:
	if _summary == null:
		return
	var p := _collect()
	var n := p.size()
	var bad := 0
	if p.source == "custom":
		for w in p.custom:
			if Theory.parse_chord(w) == null:
				bad += 1
	_summary.text = "%d chords  ·  %s%s" % [n, p.describe(), ("   (%d not recognised)" % bad) if bad > 0 else ""]


func _apply() -> void:
	var p := _collect()
	if p.size() == 0:
		_summary.text = "Pick at least one chord."
		return
	Settings.set_pool(p)
	hide()
	pool_applied.emit()
