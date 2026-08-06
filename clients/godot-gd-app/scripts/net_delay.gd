class_name NetDelay
## Latency presets over the SDK's own injector (APPS_PLAN §3). The GDExtension
## carries the transport-seam queueing in C (`room.set_latency` — delay +
## jitter both directions, never reorders, handshake exempt because the wrap
## happens after join); this class only owns the preset list and the per-frame
## pump every wrapped room needs or nothing delivers.
##
## `D` drops every wrapped room's socket uncleanly (room.drop, close 4010):
## the SDK auto-reconnects, labs' on_reconnect rebinds, and the wrap()
## reconnect hook re-applies the preset — the fresh transport is unwrapped.

const PRESETS := [
	{ "delay": 0.0, "jitter": 0.0, "label": "off" },
	{ "delay": 80.0, "jitter": 10.0, "label": "80 ms + 10 jitter" },
	{ "delay": 200.0, "jitter": 0.0, "label": "200 ms" },
	{ "delay": 200.0, "jitter": 80.0, "label": "200 ms + 80 jitter" },
	{ "delay": 400.0, "jitter": 60.0, "label": "400 ms + 60 jitter" },
]

static var preset_index := 0
static var delay_ms := 0.0
static var jitter_ms := 0.0

static var _rooms: Array = []

static func preset_label() -> String:
	return PRESETS[preset_index]["label"]

## Put the current preset in front of a joined room's socket. Idempotent.
static func wrap(room) -> void:
	if room == null: return
	if not _rooms.has(room):
		_rooms.append(room)
		# reconnection builds a NEW transport — re-apply the preset onto it
		# (and re-adopt the room: a slow reconnect window can get it evicted
		# from pump_all, and an unpumped wrap never delivers anything)
		room.reconnected.connect(func():
			if not _rooms.has(room): _rooms.append(room)
			room.set_latency(delay_ms, jitter_ms))
	room.set_latency(delay_ms, jitter_ms)

## Kill every wrapped socket uncleanly — the SDK sees a drop, not a leave.
static func drop_all() -> void:
	for room in _rooms:
		room.drop()

static func set_latency(delay: float, jitter: float) -> void:
	delay_ms = maxf(0.0, delay)
	jitter_ms = maxf(0.0, jitter)
	for room in _rooms:
		room.set_latency(delay_ms, jitter_ms)

static func use_preset(index: int) -> void:
	preset_index = ((index % PRESETS.size()) + PRESETS.size()) % PRESETS.size()
	var p: Dictionary = PRESETS[preset_index]
	set_latency(p["delay"], p["jitter"])

static func next_preset() -> void:
	use_preset(preset_index + 1)

## Forget every room and zero the latency — between acceptance cases.
static func reset() -> void:
	_rooms.clear()
	delay_ms = 0.0
	jitter_ms = 0.0
	preset_index = 0

static func in_flight() -> int:
	var n := 0
	for room in _rooms:
		n += room.net_in_flight
	return n

## Drain everything due. Call once per frame, right after Colyseus.poll() —
## a left room keeps getting pumped until its queues empty (leave() itself
## rides the delayed link).
static func pump_all() -> void:
	for i in range(_rooms.size() - 1, -1, -1):
		var room = _rooms[i]
		room.net_pump()
		# a reconnecting room is between transports — that's not "left"
		if not room.connected and not room.reconnecting and room.net_in_flight == 0:
			_rooms.remove_at(i)
