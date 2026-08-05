extends Node2D
## The shell: one scene, one Node2D. _process() drives the active lab's
## netcode, _draw() paints the arena and the panel. GDScript twin of
## godot-app's LabManager.cs on the GDExtension SDK.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--selfcheck" in args:
		var failed := Sim.selfcheck(func(line): print(line))
		print("SELFCHECK %s (%d failed)" % ["OK" if failed == 0 else "FAIL", failed])
		get_tree().quit(0 if failed == 0 else 1)
		return
	if Sim.selfcheck() != 0:
		push_error("shared-sim port mismatch")
