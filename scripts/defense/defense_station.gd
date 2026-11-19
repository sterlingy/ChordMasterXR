class_name DefenseStation
extends Node3D
## An octave station: a domed base with three shield pips, its octave name
## ("C4") and a lane running away from the player. Lost stations go dark.

var octave := 4
var shields := DefenseRules.SHIELDS
var alive := true
var lane_length := 1.4
## Lane width: one octave of the (real) keyboard in AR, so the lanes line
## up edge to edge with the octaves.
var lane_width := 0.15
var _lane_mesh: PlaneMesh
var _edges: Array[MeshInstance3D] = []

var _dome_mat: StandardMaterial3D
var _base_mat: StandardMaterial3D
var _lane_mat: StandardMaterial3D
var _pips: Array[MeshInstance3D] = []
var _label: Label3D
var _alert := 0.0
var color := Color(0.4, 0.75, 1.0)


func setup(p_octave: int, p_color: Color, p_lane_length: float, p_lane_width := 0.15) -> void:
	octave = p_octave
	color = p_color
	lane_length = p_lane_length
	lane_width = p_lane_width
	_build()


func set_lane_width(w: float) -> void:
	lane_width = w
	if _lane_mesh:
		_lane_mesh.size = Vector2(w, lane_length)
	for i in _edges.size():
		_edges[i].position.x = (-1.0 if i == 0 else 1.0) * w * 0.5


func _build() -> void:
	_lane_mat = DefenseAttacker._flat(Color(color, 0.10))
	var lane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(lane_width, lane_length)
	_lane_mesh = pm
	lane.mesh = pm
	lane.position = Vector3(0, 0.001, -lane_length / 2.0)
	lane.material_override = _lane_mat
	add_child(lane)
	# Lane edge lines.
	for sx in [-1.0, 1.0]:
		var e := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.002, 0.001, lane_length)
		e.mesh = bm
		e.position = Vector3(sx * lane_width * 0.5, 0.0015, -lane_length / 2.0)
		e.material_override = DefenseAttacker._flat(Color(color, 0.35))
		add_child(e)
		_edges.append(e)

	_base_mat = DefenseAttacker._flat(color.darkened(0.55))
	var base := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 0.058
	cm.height = 0.012
	base.mesh = cm
	base.position.y = 0.006
	base.material_override = _base_mat
	add_child(base)

	_dome_mat = StandardMaterial3D.new()
	_dome_mat.albedo_color = color
	_dome_mat.emission_enabled = true
	_dome_mat.emission = color * 0.5
	_dome_mat.metallic = 0.3
	_dome_mat.roughness = 0.35
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.034
	sm.height = 0.034
	sm.is_hemisphere = true
	dome.mesh = sm
	dome.position.y = 0.012
	dome.material_override = _dome_mat
	add_child(dome)

	for i in DefenseRules.SHIELDS:
		var pip := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = 0.006
		ps.height = 0.012
		pip.mesh = ps
		pip.material_override = DefenseAttacker._flat(Color(0.4, 1.0, 0.6))
		pip.position = Vector3((i - 1) * 0.018, 0.058, 0.0)
		add_child(pip)
		_pips.append(pip)

	_label = Label3D.new()
	_label.font = UITheme.ui_font()
	_label.text = "C%d–B%d" % [octave, octave]
	_label.font_size = 40
	_label.outline_size = 10
	_label.outline_modulate = Color(0.02, 0.02, 0.05, 0.9)
	_label.modulate = color.lightened(0.4)
	# Fixed in the playfield (no billboard, real-world size): lies just in
	# front of the base, tipped back 60° so it reads from above — the player
	# looks down at the keyboard. ~2.2 cm tall (30% smaller than the old
	# screen-sized label at arm's length).
	_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label.fixed_size = false
	_label.pixel_size = 0.00055
	_label.no_depth_test = true
	_label.rotation_degrees = Vector3(-60, 0, 0)
	_label.position = Vector3(0, 0.004, 0.078)
	add_child(_label)


## Takes `amount` shields. Returns true if the station was destroyed.
func hit(amount := 1) -> bool:
	if not alive:
		return false
	_flash_shield()
	shields = maxi(0, shields - amount)
	_update_pips()
	_alert = 1.0
	if shields == 0:
		alive = false
		_dome_mat.albedo_color = Color(0.15, 0.15, 0.18)
		_dome_mat.emission = Color(0.05, 0.02, 0.02)
		_lane_mat.albedo_color = Color(0.3, 0.3, 0.35, 0.03)
		_label.modulate = Color(0.45, 0.45, 0.5)
		return true
	return false


## A red shield bubble that flashes over the station when it's hit.
func _flash_shield() -> void:
	var b := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	b.mesh = sm
	var m := DefenseAttacker._flat(Color(1, 0.3, 0.25, 0.45))
	b.material_override = m
	b.position.y = 0.02
	add_child(b)
	var tw := create_tween().set_parallel()
	tw.tween_property(b, "scale", Vector3.ONE * 1.35, 0.4)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.4)
	tw.chain().tween_callback(b.queue_free)


func repair() -> void:
	if alive and shields < DefenseRules.SHIELDS:
		shields += 1
		_update_pips()


func _update_pips() -> void:
	for i in _pips.size():
		_pips[i].visible = i < shields


## 0..1: how close the nearest attacker on this lane is; lights the lane.
func set_threat(level: float) -> void:
	if not alive:
		return
	_lane_mat.albedo_color = Color(color.lerp(Color(1, 0.35, 0.3), level), 0.10 + 0.22 * level)


func _process(delta: float) -> void:
	if _alert > 0.0:
		_alert = maxf(0.0, _alert - delta * 1.5)
		if alive:
			_dome_mat.emission = color * 0.5 + Color(1, 0.2, 0.1) * _alert * 2.0
