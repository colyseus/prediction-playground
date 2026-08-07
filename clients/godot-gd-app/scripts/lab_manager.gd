extends Node2D
## The shell: one scene, one Node2D. _process() drives the active lab's
## netcode, _draw() paints the arena and the panel. GDScript twin of
## godot-app's LabManager.cs on the GDExtension SDK.

var _app := App.new()
var _labs: Array = []
var _lab_index := 0
var _active: LabBase = null
var _switching := false
var _error := ""
var _last_now := 0.0

# --smoke: headless boot check — mount every lab in turn, count patches (via
# the clock stamp), exit 0/1. The acceptance harness grows out of this.
var _smoke := false
var _smoke_deadline := 0.0
var _smoke_stamp := 0.0
var _smoke_target := 0
var _smoke_patches := 0

func _endpoint() -> String:
	var env := OS.get_environment("PLAYGROUND_ENDPOINT")
	return env if env != "" else "ws://127.0.0.1:5173"

static func now_ms() -> float:
	return float(Time.get_ticks_usec()) / 1000.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--selfcheck" in args:
		var failed := Sim.selfcheck(func(line): print(line))
		print("SELFCHECK %s (%d failed)" % ["OK" if failed == 0 else "FAIL", failed])
		get_tree().quit(0 if failed == 0 else 1)
		return
	if Sim.selfcheck() != 0:
		push_error("shared-sim port mismatch")

	if "--probe" in args:
		_probe()
		return

	_smoke = "--smoke" in args
	if _smoke: _smoke_deadline = now_ms() + 15000

	_app.client = Colyseus.Client.new(_endpoint())
	_labs = [Lab00.new(), Lab01.new(), Lab02.new(), Lab03.new(), Lab04.new(),
		Lab05.new(), Lab06.new(), Lab07.new(), Lab08.new(), Lab09.new(),
		Lab10.new(), Lab11.new()]
	_labs.sort_custom(func(a, b): return a.num < b.num)
	_switch_to(0)

func _switch_to(index: int) -> void:
	if _switching: return
	_switching = true
	_error = ""
	if _active != null:
		_active.unmount()
		if _active.room != null: _active.room.leave()
		_active = null
	_lab_index = index
	var lab: LabBase = _labs[index]
	var ok: bool = await lab.mount(_app)
	if ok:
		lab.bind_reconnect()
		_active = lab
	else:
		_error = "state never arrived for %s" % lab.id
	_switching = false

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey: Kb.feed(e)
	elif e is InputEventMouseButton: Kb.feed_mouse(e)

func _process(_delta: float) -> void:
	if _labs.is_empty(): return   # selfcheck/probe modes never build the list
	# Deliver due packets first: the injector queues both directions and only
	# drains here, on the main thread (leave() rides it too).
	Colyseus.poll()
	NetDelay.pump_all()

	Kb.mouse_pos = get_viewport().get_mouse_position()

	var now := now_ms()
	var dt := now - _last_now if _last_now > 0 else 0.0
	_last_now = now

	# Guard on the lab NUMBER, not the index: digits map 0-9 to labs 00-09.
	for i in _labs.size():
		var n: int = _labs[i].num
		if n < 10 and Kb.key(KEY_0 + n): _switch_to(i)
	# The digits only reach labs 0-9; [ ] are the only way to a 2-digit lab.
	if Kb.key(KEY_BRACKETLEFT): _switch_to((_lab_index + _labs.size() - 1) % _labs.size())
	if Kb.key(KEY_BRACKETRIGHT): _switch_to((_lab_index + 1) % _labs.size())
	if Kb.key(KEY_L): NetDelay.next_preset()
	if Kb.key(KEY_K): NetDelay.drop_all()
	if Kb.key(KEY_P):
		_app.private_room = not _app.private_room
		_switch_to(_lab_index)

	if _active != null and not _switching:
		_active.frame(_app, now, dt)

	if _smoke: _smoke_step(now)

	Kb.end_frame()
	queue_redraw()

func _draw() -> void:
	if _labs.is_empty(): return   # selfcheck quit still renders a frame
	Draw.c = self
	var size := get_viewport_rect().size
	var w := size.x
	var h := size.y
	const PANEL_W := 300.0
	const PAD := 18.0
	Draw.rect(Rect2(0, 0, w, h), Palette.BG)
	Draw.rect(Rect2(w - PANEL_W - PAD * 2, 44, PANEL_W + PAD * 2, h - 44 - 46), Palette.PANEL)

	_app.stage = Rect2(0, 44, w - PANEL_W - PAD * 2, h - 44 - 46)
	_app.view.fit(_app.stage)
	_app.hud.begin(w - PANEL_W - PAD, 60, PANEL_W)
	if _active == null or not _active.own_arena: Draw.arena(_app.view)

	if _active != null:
		_active.render(_app)
	else:
		Draw.text(_app.stage.position.x, _app.stage.position.y + _app.stage.size.y / 2,
			_app.stage.size.x, _error if _error != "" else "connecting...",
			Palette.BAD if _error != "" else Palette.TEXT_DIM, 12, HORIZONTAL_ALIGNMENT_CENTER)

	_top_bar(w)
	_bottom_bar(w, h)

func _top_bar(w: float) -> void:
	Draw.rect(Rect2(0, 0, w, 44), Palette.PANEL)
	Draw.text(16, 6, 300, "PREDICTION PLAYGROUND", Palette.ACCENT, 12)
	Draw.text(16, 22, 300, "godot  (GDScript)", Palette.TEXT_FAINT, 10)

	var lab: LabBase = _labs[_lab_index]
	Draw.text(210, 6, 700, "%02d  %s" % [lab.num, lab.title], Palette.TEXT, 13)
	Draw.text(210, 22, 700, lab.blurb, Palette.TEXT_DIM, 10)

func _bottom_bar(w: float, h: float) -> void:
	var y := h - 46
	Draw.rect(Rect2(0, y, w, 46), Palette.PANEL)
	var clock = _active.clock() if _active != null else null
	var line := "INJECTED %s    connecting..." % NetDelay.preset_label()
	if clock != null:
		line = "RTT %.0f ms    JITTER %.0f ms    INJECTED %s    IN FLIGHT %d pkt    ROOM %s" % [
			clock.smoothed_rtt(), clock.jitter(), NetDelay.preset_label(),
			NetDelay.in_flight(), "private" if _app.private_room else "shared"]
	Draw.text(16, y + 14, w - 32, line, Palette.TEXT, 11)
	Draw.text(w - 460, y + 14, 444, "0-9 lab   [ ] prev/next   L latency   K drop   P private",
		Palette.TEXT_FAINT, 10, HORIZONTAL_ALIGNMENT_RIGHT)

# ------------------------------------------------------------------ probe

## --probe: is the decoded bot Dictionary live? do pattern messages land?
func _probe() -> void:
	var app := App.new()
	app.client = Colyseus.Client.new(_endpoint())
	app.private_room = true
	var probe_room = await Shell.join_lab(app, "lab-bots", func(r):
		var st = r.get_state()
		return st is Dictionary and st.get("bots") is Dictionary \
			and st.get("bots").has("bot1"))
	if probe_room == null:
		print("PROBE join failed")
		get_tree().quit(1)
		return
	var cached = probe_room.get_state().get("bots").get("bot1")
	probe_room.send_message("pattern", { "kind": "circle" })
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4000:
		for i in 30:
			await get_tree().process_frame
		var fresh = probe_room.get_state().get("bots").get("bot1")
		print("cached kind=%s x=%.2f y=%.2f | fresh kind=%s x=%.2f y=%.2f | same_ref=%s" % [
			cached.get("kind"), cached.get("x", 0.0), cached.get("y", 0.0),
			fresh.get("kind"), fresh.get("x", 0.0), fresh.get("y", 0.0),
			str(cached == fresh)])
	probe_room.leave()
	get_tree().quit(0)

# ------------------------------------------------------------------ smoke

func _smoke_step(now: float) -> void:
	if now > _smoke_deadline:
		print("SMOKE FAIL timeout at lab %d: error=%s patches=%d" % [
			_smoke_target, _error if _error != "" else "none", _smoke_patches])
		get_tree().quit(1)
		_smoke = false
		return
	if _active == null or _lab_index != _smoke_target or _switching: return

	var stamp: float = _active.clock().last_server_time() if _active.clock() != null else 0.0
	if stamp > 0 and stamp != _smoke_stamp:
		if _smoke_stamp > 0: _smoke_patches += 1   # first read is history, not an arrival
		_smoke_stamp = stamp
	if _smoke_patches < 3: return

	print("SMOKE lab %s OK (%d patches)" % [_active.id, _smoke_patches])
	_smoke_target += 1
	_smoke_patches = 0
	_smoke_stamp = 0
	if _smoke_target >= _labs.size():
		print("SMOKE OK all %d labs" % _labs.size())
		get_tree().quit(0)
		_smoke = false
		return
	_smoke_deadline = now + 15000
	_switch_to(_smoke_target)
