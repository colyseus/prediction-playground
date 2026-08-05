class_name LabBase
extends RefCounted
## Shell contract. Port of framework/lab.ts (via godot-app's Lab.cs): the
## shell owns the room and hands it to the lab; labs never join and never
## leave. Subclasses set the identity vars in _init and assign `room` in
## mount().

var id := ""
var num := 0
var title := ""
var blurb := ""
## The lab paints its own background, so the shell skips the shared arena.
var own_arena := false

## The joined room (Colyseus.Room). Subclasses assign this in mount().
var room = null

## Join and wire up. The shell awaits this on lab switch. Returns bool.
func mount(_app: App) -> bool:
	return false

## Called from _process() — send inputs, advance prediction.
func frame(_app: App, _now: float, _dt_ms: float) -> void:
	pass

## Called from _draw() — draw the arena overlay and the HUD.
func render(_app: App) -> void:
	pass

## Drop predicts/reconcilers. Do NOT leave the room (the shell does).
func unmount() -> void:
	pass

## After the SDK auto-reconnects a dropped transport. The reconnected room
## counts inputs from ZERO — reconcilers MUST reset here.
func on_reconnect() -> void:
	pass

## The shell calls this once after a successful mount.
func bind_reconnect() -> void:
	if room == null: return
	if not room.reconnected.is_connected(on_reconnect):
		room.reconnected.connect(on_reconnect)

func clock():
	return room.clock if room != null else null

## Convenience: the decoded state Dictionary, or null.
func state():
	if room == null: return null
	var st = room.get_state()
	return st if st is Dictionary else null
