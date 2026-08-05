class_name App
## Everything the shell hands a lab.

var client: Colyseus.Client
var view := WorldView.new()
var hud := Hud.new()
var stage := Rect2()
var private_room := false

## Ask the shell for a latency preset on mount. Labs 00/01/03 make no point
## at all on a 1 ms localhost link, so they set one themselves.
func set_latency_preset(index: int) -> void:
	NetDelay.use_preset(index)
