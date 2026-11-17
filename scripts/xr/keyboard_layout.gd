class_name KeyboardLayout
extends RefCounted
## Where each key of a real keyboard is, from two calibration touches.
##
## Pure geometry (no nodes), so it can be unit-tested on the desktop.
##
## Calibration points are fingertip touches on the MIDDLE of the lowest and
## highest keys, near the front edge. Key spacing comes from the distance
## between them and the number of white keys in the range; lengths use real
## piano proportions relative to a white key's width.

const WHITE_PCS := [0, 2, 4, 5, 7, 9, 11]

## Proportions relative to the white-key width (≈ 23.5 mm on most boards).
const WHITE_LEN := 6.2          # white key ≈ 145 mm long
const BLACK_WIDTH := 0.55
## Lit overlays are drawn narrower than the real keys so the gap between two
## lit neighbours (and the real key below) stays visible.
const WHITE_FILL := 0.80
const BLACK_FILL := 0.80
const BLACK_LEN := 4.0          # black key ≈ 95 mm long
const BLACK_FRONT := 2.3        # black keys start ≈ 55 mm behind the white front edge
const BLACK_RAISE := 0.011      # black key tops sit ≈ 11 mm above white tops
const TOUCH_INSET := 0.02       # the touch is ≈ 2 cm behind the front edge
const PAD := 0.006              # a fingertip joint sits ≈ 6 mm above what it touches

var p_low := Vector3.ZERO
var p_high := Vector3.ZERO
var low := 48
var high := 84
var viewer := Vector3(0, 1.6, 1.0)  # where the player is (decides front vs back)
var lift := 0.0                     # user nudge, metres
var tilt := 0.0                     # radians; + raises the back edge of the keys


static func is_white(midi: int) -> bool:
	return WHITE_PCS.has(posmod(midi, 12))


static func white_index(midi: int) -> int:
	var octave := floori(midi / 12.0)
	var n := octave * 7
	for pc in WHITE_PCS:
		if pc < posmod(midi, 12):
			n += 1
	return n


## Position along the keyboard in white-key units; black keys sit halfway
## between the white keys either side (C# = halfway between C and D).
static func key_index(midi: int) -> float:
	return float(white_index(midi)) - (0.0 if is_white(midi) else 0.5)


func valid() -> bool:
	return p_low.distance_to(p_high) > 0.15 and key_index(high) > key_index(low)


func white_width() -> float:
	return p_low.distance_to(p_high) / (key_index(high) - key_index(low))


## Unit vectors: along the keyboard (low -> high), up from the key tops,
## and back (away from the player).
func axes() -> Array[Vector3]:
	var along := (p_high - p_low).normalized()
	var up := (Vector3.UP - along * along.dot(Vector3.UP)).normalized()
	var back := along.cross(up).normalized()
	if back.dot(viewer - p_low) > 0.0:
		back = -back
	if tilt != 0.0:
		var b2 := back * cos(tilt) + up * sin(tilt)
		up = up * cos(tilt) - back * sin(tilt)
		back = b2
	return [along, up, back]


# --- adjustments (all keep the two points as the source of truth) -----------

func mid() -> Vector3:
	return (p_low + p_high) * 0.5


func translate(v: Vector3) -> void:
	p_low += v
	p_high += v


## Turns the keyboard about a vertical axis through its middle.
## + = counter-clockwise seen from above.
func turn(angle: float) -> void:
	var m := mid()
	var r := Basis(Vector3.UP, angle)
	p_low = m + r * (p_low - m)
	p_high = m + r * (p_high - m)


## Raises the LOW end by `dy` metres (and lowers the high end as much),
## keeping the length — fixes a keyboard that isn't level.
func level(dy: float) -> void:
	var m := mid()
	var half := (p_high - p_low) * 0.5
	var up: Vector3 = axes()[1]
	var n := (half - up * dy).normalized() * half.length()
	p_low = m - n
	p_high = m + n


## Stretches or shrinks the keyboard about its middle by `dm` metres total.
func widen(dm: float) -> void:
	var length := p_low.distance_to(p_high)
	if length + dm < 0.16:
		return
	var f := (length + dm) / length
	var m := mid()
	p_low = m + (p_low - m) * f
	p_high = m + (p_high - m) * f


## {midi, white, center: Vector3, basis: Basis, size: Vector3} per key,
## box X along the keyboard, Y up, Z front-to-back.
func keys() -> Array:
	var out := []
	if not valid():
		return out
	var ax := axes()
	var along: Vector3 = ax[0]
	var up: Vector3 = ax[1]
	var back: Vector3 = ax[2]
	var w := white_width()
	var basis := Basis(along, up, back).orthonormalized()
	var i_low := key_index(low)
	for m in range(low, high + 1):
		var on_line := p_low + along * w * (key_index(m) - i_low)
		var top := on_line + up * (lift - PAD)
		var front := top - back * TOUCH_INSET
		var c: Vector3
		var size: Vector3
		if is_white(m):
			size = Vector3(w * WHITE_FILL, 0.003, w * WHITE_LEN)
			c = front + back * (size.z / 2.0)
		else:
			size = Vector3(w * BLACK_WIDTH * BLACK_FILL, 0.003, w * BLACK_LEN)
			c = front + back * (w * BLACK_FRONT + size.z / 2.0) + up * BLACK_RAISE
		out.append({"midi": m, "white": is_white(m), "center": c, "basis": basis, "size": size})
	return out
