@tool
class_name BeatIndicator
extends Control
## Row of dots showing the beat within the bar. The current beat lights up;
## beat 1 is drawn larger. Count-in beats use the warning colour.

@export var beats := 4:
	set(v):
		beats = maxi(1, v)
		queue_redraw()
@export var current := 0:
	set(v):
		current = v
		queue_redraw()
var count_in := false

const OFF := Color(1, 1, 1, 0.15)
const ON := Color(0.36, 0.62, 1.0)
const COUNT := Color(1.0, 0.75, 0.3)


func _ready() -> void:
	custom_minimum_size = Vector2(160, 28)


func set_beat(b: int, total: int, is_count_in: bool) -> void:
	beats = total
	count_in = is_count_in
	current = b


func _draw() -> void:
	# The dots sit in a 200 px band centred on the window (like the chord),
	# or on this control when that doesn't fit.
	var band := minf(200.0, size.x)
	var mid := get_viewport_rect().size.x * 0.5 - get_global_rect().position.x
	if Engine.is_editor_hint() or mid - band * 0.5 < 0.0 or mid + band * 0.5 > size.x:
		mid = size.x * 0.5
	var gap := band / beats
	var r := minf(size.y * 0.35, gap * 0.3)
	for i in beats:
		var c := Vector2(mid - band * 0.5 + gap * (i + 0.5), size.y * 0.5)
		var rad := r * (1.25 if i == 0 else 1.0)
		var col := OFF
		if i == current:
			col = COUNT if count_in else ON
		draw_circle(c, rad, col)
