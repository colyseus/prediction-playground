class_name Palette
## The playground palette — same hex values as the web build's index.html and
## godot-app's View.cs, so a lab reads the same on every client.

const BG := Color("0a0f1a")
const PANEL := Color("0e1626")
const INSET := Color("121c30")
const BORDER := Color("24304a")
const TEXT := Color("d8e2f0")
const TEXT_DIM := Color("8aa0c0")
const TEXT_FAINT := Color("5e7196")
const ACCENT := Color("ffd36b")
const GOOD := Color("7be08a")
const WARN := Color("ffb454")
const BAD := Color("ff6688")
const BLUE := Color("6db3ff")

static func a(c: Color, alpha: float) -> Color:
	c.a = alpha
	return c

## Player colour from the server hue byte — hsl(hue/256*360, 72%, 62%).
static func hue(h8: int, alpha := 1.0) -> Color:
	var h := h8 / 256.0 * 360.0
	var s := 0.72
	var l := 0.62
	var cc := (1.0 - absf(2.0 * l - 1.0)) * s
	var hp := fmod(h, 360.0) / 60.0
	var x := cc * (1.0 - absf(fmod(hp, 2.0) - 1.0))
	var r := 0.0
	var g := 0.0
	var b := 0.0
	if hp < 1.0: r = cc; g = x
	elif hp < 2.0: r = x; g = cc
	elif hp < 3.0: g = cc; b = x
	elif hp < 4.0: g = x; b = cc
	elif hp < 5.0: r = x; b = cc
	else: r = cc; b = x
	var m := l - cc / 2.0
	return Color(r + m, g + m, b + m, alpha)
