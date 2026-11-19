class_name XRChoiceButton
extends Node3D
## One floating answer button for "Name it" in XR: a rounded glass card with
## the chord name, a soft accent rim and glow. Pressed by the XR pointer ray
## (XRPointer looks for the "xr_button" meta on its hit body) or by poking
## it with an index fingertip (XRChoiceButtons does the finger test).
##
## Faces +z (towards the player); size is in metres.

signal activated(button: XRChoiceButton)

## Overall size factor (1.15 = 15% bigger than the first design).
const SCALE := 1.15
const SIZE := Vector2(0.11, 0.06) * SCALE
const RADIUS := 0.016 * SCALE
const MARGIN := 0.018 * SCALE       # quad border for the outer glow
const DEPTH := 0.008                # visual thickness (back plate offset)
const HIT_DEPTH := 0.05             # ray hit box depth

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec2 quad_size;
uniform vec2 btn_size;
uniform float radius;
uniform vec4 fill_top : source_color;
uniform vec4 fill_bottom : source_color;
uniform vec4 rim : source_color;
uniform float rim_width = 0.0012;
uniform float glow = 0.35;
uniform float sheen = 0.18;
uniform float alpha = 1.0;

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * quad_size;
	p.y = -p.y;
	float d = sd_round_box(p, btn_size * 0.5, radius);
	float aa = max(fwidth(d), 1e-5);
	float inside = 1.0 - smoothstep(-aa, aa, d);
	float t = clamp(p.y / btn_size.y + 0.5, 0.0, 1.0);
	vec4 fill = mix(fill_bottom, fill_top, t);
	// Glassy highlight across the upper half.
	float hi = smoothstep(0.45, 0.95, t) * sheen;
	vec3 col = fill.rgb + vec3(hi);
	float a = fill.a * inside;
	// Thin rim just inside the edge.
	float r = 1.0 - smoothstep(rim_width - aa, rim_width + aa, abs(d + rim_width));
	col = mix(col, rim.rgb, r * rim.a);
	a = max(a, r * rim.a);
	// Soft outer glow in the rim colour.
	float g = (1.0 - inside) * exp(-max(d, 0.0) / 0.006) * glow;
	col = mix(col, rim.rgb, clamp(g * 2.0, 0.0, 1.0) * (1.0 - inside));
	a = max(a, g);
	ALBEDO = col;
	ALPHA = a * alpha;
}
"""

const ACCENT := Color(0.36, 0.62, 1.0)
const GOOD := Color(0.35, 0.85, 0.5)
const BAD := Color(0.95, 0.38, 0.38)

static var _shader: Shader

var chord: Theory.Chord
var state := "idle"                 # idle | correct | wrong
var enabled := true
var hovered := false:
	set(v):
		if hovered != v:
			hovered = v
			_restyle()
			_animate_hover()

var _card: MeshInstance3D
var _back: MeshInstance3D
var _mat: ShaderMaterial
var _back_mat: ShaderMaterial
var _label: Label3D
var _body: StaticBody3D
var _lift: Node3D                   # hover: floats towards the player
var _visual: Node3D                 # moves when pressed / pulses
var _hover_tw: Tween
var _hover_ids := {}
var _press_tw: Tween
var _fade := 1.0


func setup(c: Theory.Chord) -> void:
	chord = c


func _ready() -> void:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	_lift = Node3D.new()
	add_child(_lift)
	_visual = Node3D.new()
	_lift.add_child(_visual)
	var qs := SIZE + Vector2.ONE * MARGIN * 2.0
	_back = _quad(qs)
	_back_mat = _make_mat(qs)
	_back.material_override = _back_mat
	_back.position.z = -DEPTH
	_visual.add_child(_back)
	_card = _quad(qs)
	_mat = _make_mat(qs)
	_mat.render_priority = 1
	_card.material_override = _mat
	_visual.add_child(_card)

	_label = Label3D.new()
	_label.font = UITheme.ui_font()
	_label.text = chord.pretty() if chord else "?"
	_label.font_size = 96
	_label.pixel_size = 0.00028 * SCALE
	_label.outline_size = 12
	_label.outline_modulate = Color(0.02, 0.03, 0.08, 0.6)
	_label.position.z = 0.001
	_label.render_priority = 3
	_label.outline_render_priority = 2
	# Long names (e.g. E♭m7♭5) shrink to fit the card.
	var w := _label.font.get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.font_size).x * _label.pixel_size
	if w > SIZE.x * 0.84:
		_label.pixel_size *= SIZE.x * 0.84 / w
	_visual.add_child(_label)

	_body = StaticBody3D.new()
	_body.collision_layer = 1 << 4      # the layer XRPointer's ray looks at
	_body.collision_mask = 0
	_body.set_meta("xr_button", self)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE.x, SIZE.y, HIT_DEPTH)
	cs.shape = box
	_body.add_child(cs)
	add_child(_body)
	_restyle()


func _quad(s: Vector2) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = s
	mi.mesh = q
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_mat(qs: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("quad_size", qs)
	m.set_shader_parameter("btn_size", SIZE)
	m.set_shader_parameter("radius", RADIUS)
	return m


## Pointer/finger hover tracking (several pointers may hover at once).
func set_hover(id: int, on: bool) -> void:
	if on:
		_hover_ids[id] = true
	else:
		_hover_ids.erase(id)
	hovered = not _hover_ids.is_empty()


func _animate_hover() -> void:
	if _lift == null:
		return
	var on := hovered and can_press()
	if _hover_tw:
		_hover_tw.kill()
	_hover_tw = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tw.tween_property(_lift, "position:z", 0.008 if on else 0.0, 0.12)
	_hover_tw.tween_property(_lift, "scale", Vector3.ONE * (1.07 if on else 1.0), 0.12)


func can_press() -> bool:
	return enabled and state == "idle" and _fade > 0.5


## Press from the ray or a fingertip.
func press() -> void:
	if not can_press():
		return
	if _press_tw:
		_press_tw.kill()
	_press_tw = create_tween()
	_press_tw.tween_property(_visual, "position:z", -0.006, 0.05)
	_press_tw.tween_property(_visual, "position:z", 0.0, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	activated.emit(self)


func set_enabled(on: bool) -> void:
	if enabled != on:
		enabled = on
		_restyle()
		_animate_hover()


## Result of this answer: "correct" glows green and pulses, "wrong" turns
## red, shakes and dims.
func show_result(ok: bool) -> void:
	state = "correct" if ok else "wrong"
	_restyle()
	_animate_hover()
	var tw := create_tween()
	if ok:
		tw.tween_property(_visual, "scale", Vector3.ONE * 1.14, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(_visual, "scale", Vector3.ONE * 1.06, 0.2)
	else:
		for k in 4:
			tw.tween_property(_visual, "position:x", 0.006 * (1 if k % 2 == 0 else -1), 0.04)
		tw.tween_property(_visual, "position:x", 0.0, 0.04)


## Fades the button (others step back once the right answer is found).
func fade_to(a: float, secs := 0.25) -> void:
	create_tween().tween_method(_set_fade, _fade, a, secs)


func appear(delay: float) -> void:
	_set_fade(0.0)
	_visual.scale = Vector3.ONE * 0.7
	var tw := create_tween().set_parallel()
	tw.tween_method(_set_fade, 0.0, 1.0, 0.22).set_delay(delay)
	tw.tween_property(_visual, "scale", Vector3.ONE, 0.3).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _set_fade(a: float) -> void:
	_fade = a
	_restyle()


func _restyle() -> void:
	if _mat == null:
		return
	var rim := ACCENT
	var top := Color(0.16, 0.19, 0.30, 0.86)
	var bottom := Color(0.07, 0.08, 0.14, 0.9)
	var glow := 0.3
	var text := Color(0.95, 0.96, 1.0)
	match state:
		"correct":
			rim = GOOD
			top = Color(0.14, 0.42, 0.26, 0.92)
			bottom = Color(0.06, 0.2, 0.12, 0.94)
			glow = 0.9
		"wrong":
			rim = BAD
			top = Color(0.32, 0.12, 0.13, 0.75)
			bottom = Color(0.16, 0.06, 0.07, 0.8)
			glow = 0.15
			text = Color(1.0, 0.75, 0.75, 0.7)
	if state == "idle" and hovered and enabled:
		rim = rim.lightened(0.35)
		top = top.lightened(0.12)
		glow = 0.85
	if not enabled and state == "idle":
		rim = Color(0.5, 0.52, 0.6)
		glow = 0.0
		text.a = 0.45
	_mat.set_shader_parameter("rim", Color(rim, 0.95))
	_mat.set_shader_parameter("fill_top", top)
	_mat.set_shader_parameter("fill_bottom", bottom)
	_mat.set_shader_parameter("glow", glow)
	_mat.set_shader_parameter("alpha", _fade)
	# Back plate: a darker copy just behind, for a little depth.
	_back_mat.set_shader_parameter("rim", Color(rim.darkened(0.6), 0.6))
	_back_mat.set_shader_parameter("fill_top", Color(0.02, 0.02, 0.05, 0.6))
	_back_mat.set_shader_parameter("fill_bottom", Color(0.02, 0.02, 0.05, 0.6))
	_back_mat.set_shader_parameter("glow", 0.0)
	_back_mat.set_shader_parameter("sheen", 0.0)
	_back_mat.set_shader_parameter("alpha", _fade)
	_label.modulate = Color(text, text.a * _fade)
	_label.outline_modulate = Color(0.02, 0.03, 0.08, 0.6 * _fade)
	_body.collision_layer = (1 << 4) if _fade > 0.5 else 0
