class_name Sim
## The playground's shared simulation, ported to GDScript.
##
## Bit-exact double transliteration of the src/shared TypeScript: same op
## order, same constants (GDScript floats are f64 throughout). The server runs
## the original; steady-state reconcile corrections must sit at wire precision.
##
## Every step function mutates its target IN PLACE through plain property
## access (`e.x`, `b.vx`), so the same code runs over a reconciler mirror view
## (C storage behind _get/_set), a reckon scratch view, or a plain Dictionary.

const TICK_HZ := 20
const ARENA_W := 100.0
const ARENA_H := 60.0
const PLAYER_HALF := 1.6
const PLAYER_ACCEL := 220.0
const PLAYER_MAX_SPEED := 34.0
const PLAYER_FRICTION_K := 0.72
const BOT_RADIUS := 1.8
const REMOTE_INTERP_MS := 100.0
const TELEPORT_SNAP_DIST := 8.0
## Server rewind cap — also what bounds render-time spoofing.
const MAX_REWIND_MS := 500.0

## Math.SQRT1_2 — the exact double the JS sim multiplies by.
const SQRT1_2 := 0.70710678118654752440

## Session id of the server-driven AI paddle in lab-hockey.
const BOT_ID := "bot"

## shared/movement.ts stepEntity — the single deterministic movement step,
## run identically by the server (once per received input) and by the
## reconciler (predict + rollback replay). sqrt/mul/add only.
static func step_entity(e, move_x: float, move_y: float, dt: float) -> void:
	var ax := move_x
	var ay := move_y
	if ax != 0.0 and ay != 0.0:
		ax *= SQRT1_2
		ay *= SQRT1_2

	if ax != 0.0 or ay != 0.0:
		e.vx += ax * PLAYER_ACCEL * dt
		e.vy += ay * PLAYER_ACCEL * dt
	else:
		e.vx *= PLAYER_FRICTION_K
		e.vy *= PLAYER_FRICTION_K
		if e.vx > -0.05 and e.vx < 0.05: e.vx = 0.0
		if e.vy > -0.05 and e.vy < 0.05: e.vy = 0.0

	var sq = e.vx * e.vx + e.vy * e.vy
	if sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED:
		var s = PLAYER_MAX_SPEED / sqrt(sq)
		e.vx *= s
		e.vy *= s

	e.x += e.vx * dt
	e.y += e.vy * dt

	if e.x < PLAYER_HALF:
		e.x = PLAYER_HALF
		if e.vx < 0.0: e.vx = 0.0
	elif e.x > ARENA_W - PLAYER_HALF:
		e.x = ARENA_W - PLAYER_HALF
		if e.vx > 0.0: e.vx = 0.0
	if e.y < PLAYER_HALF:
		e.y = PLAYER_HALF
		if e.vy < 0.0: e.vy = 0.0
	elif e.y > ARENA_H - PLAYER_HALF:
		e.y = ARENA_H - PLAYER_HALF
		if e.vy > 0.0: e.vy = 0.0

# ------------------------------------------------------ shared/goal.ts

## The goal zone: a strip on the right edge of the arena.
const GOAL_ZONE_X := ARENA_W - 8.0
const GOAL_ZONE_Y := ARENA_H / 2.0 - 9.0
const GOAL_ZONE_W := 8.0
const GOAL_ZONE_H := 18.0
## Re-entry lockout, in fixed steps — reconciled tick state.
const SCORE_COOLDOWN_TICKS := 50

## shared/goal.ts stepScoreGate. Deterministic under rollback replay: true on
## the entry EDGE. No ref params in GDScript — returns [scored, new_ticks].
static func step_score_gate(x: float, y: float, score_ticks: int) -> Array:
	if score_ticks > 0:
		return [false, score_ticks - 1]
	if x >= GOAL_ZONE_X and y >= GOAL_ZONE_Y and y <= GOAL_ZONE_Y + GOAL_ZONE_H:
		return [true, SCORE_COOLDOWN_TICKS]
	return [false, 0]

# ------------------------------------------------ shared/projectile.ts

const PROJECTILE_SPEED := 34.0
const PROJECTILE_RADIUS := 0.7
const PROJECTILE_TTL_MS := 2600.0

## Constant-velocity flight with wall bounces.
static func step_projectile(p, dt: float) -> void:
	p.x += p.vx * dt
	p.y += p.vy * dt
	if p.x < 0.0:
		p.x = 0.0
		p.vx = absf(p.vx)
	elif p.x > ARENA_W:
		p.x = ARENA_W
		p.vx = -absf(p.vx)
	if p.y < 0.0:
		p.y = 0.0
		p.vy = absf(p.vy)
	elif p.y > ARENA_H:
		p.y = ARENA_H
		p.vy = -absf(p.vy)

# ---------------------------------------------------- shared/movers.ts

## Teleporter warp period, on the shared server-clock timeline.
const TELEPORT_PERIOD_MS := 3000.0
## How often wander bots pick a new (server-secret) heading.
const WANDER_TURN_MS := 900.0

## Horizontal ping-pong between minX and maxX at |vx| = speed.
static func _patrol(b, dt: float) -> void:
	b.x += b.vx * dt
	b.y = b.baseY
	if b.x < b.minX:
		b.x = b.minX
		b.vx = absf(b.vx)
	elif b.x > b.maxX:
		b.x = b.maxX
		b.vx = -absf(b.vx)

## shared/movers.ts stepBot — run by the server each fixed tick AND by the
## client's reckon mode. `elapsed_ms` is the shared server-clock timeline.
## Mutates x/y/vx/vy (+ lastTeleport); reads kind/minX/maxX/baseY/phaseMs/speed.
## `kind_override`: the reckon SCRATCH carries scalar fields only — string
## fields never reach it — so a reckon step passes the kind it read off fresh
## decoded state instead of the scratch's empty one.
static func step_bot(b, dt: float, elapsed_ms: float, kind_override := "") -> void:
	var kind = kind_override if kind_override != "" else str(b.kind)
	match kind:
		"circle":
			var cx = (b.minX + b.maxX) / 2.0
			var rx = (b.maxX - b.minX) / 2.0
			var ry = minf(12.0, ARENA_H / 2.0 - BOT_RADIUS - 2.0)
			var w = b.speed / rx                          # rad/s
			var t = (elapsed_ms + b.phaseMs) / 1000.0
			b.x = cx + rx * cos(w * t)
			b.y = b.baseY + ry * sin(w * t)
			b.vx = -rx * w * sin(w * t)
			b.vy = ry * w * cos(w * t)
		"teleport":
			_patrol(b, dt)
			# Predict the warp from the synced schedule: jump half the patrol
			# span (wrapping) every period — a constant, visible cut.
			while b.lastTeleport > 0.0 and elapsed_ms - b.lastTeleport >= TELEPORT_PERIOD_MS:
				var span = b.maxX - b.minX
				b.x = b.minX + fmod((b.x - b.minX) + span / 2.0, span)
				b.lastTeleport += TELEPORT_PERIOD_MS
		"wander":
			b.x += b.vx * dt
			b.y += b.vy * dt
			var mn := BOT_RADIUS
			var mx := ARENA_W - BOT_RADIUS
			var my := ARENA_H - BOT_RADIUS
			if b.x < mn:
				b.x = mn
				b.vx = absf(b.vx)
			elif b.x > mx:
				b.x = mx
				b.vx = -absf(b.vx)
			if b.y < mn:
				b.y = mn
				b.vy = absf(b.vy)
			elif b.y > my:
				b.y = my
				b.vy = -absf(b.vy)
		_:
			_patrol(b, dt)

# --------------------------------------------------- shared/hitscan.ts

## 2D hitscan: ray vs circle. Returns the ray parameter t of the nearest
## intersection, or -1 on a miss.
static func ray_circle(ox: float, oy: float, dx: float, dy: float,
		cx: float, cy: float, r: float, max_dist: float) -> float:
	var mx = ox - cx
	var my = oy - cy
	var b = mx * dx + my * dy
	var c = mx * mx + my * my - r * r
	if c > 0.0 and b > 0.0: return -1.0            # outside, pointing away
	var disc = b * b - c
	if disc < 0.0: return -1.0
	var t = -b - sqrt(disc)
	var hit = 0.0 if t < 0.0 else t                # inside the circle = t 0
	return hit if hit <= max_dist else -1.0

# ------------------------------------------------------ shared/bump.ts

## Post-bump immunity, in fixed steps — a RECONCILED tick gate.
const BUMP_COOLDOWN_TICKS := 12
const BUMP_SPEED := 48.0

## Cooldown countdown — run BEFORE the movement step on both sides.
static func step_bump_gate(bump_ticks: int) -> int:
	return bump_ticks - 1 if bump_ticks > 0 else 0

## Player-vs-bot bump test at an agreed bot position. Returns
## [hit: bool, vx: float, vy: float]; the CALLER applies it and re-arms
## bumpTicks inside the reconciler step.
static func collide_bot(px: float, py: float, bump_ticks: int,
		bot_x: float, bot_y: float) -> Array:
	if bump_ticks > 0: return [false, 0.0, 0.0]
	var dx = px - bot_x
	var dy = py - bot_y
	var r := PLAYER_HALF + BOT_RADIUS
	var d2 = dx * dx + dy * dy
	if d2 >= r * r: return [false, 0.0, 0.0]
	var d = sqrt(d2)
	if d == 0.0: d = 1e-6
	return [true, dx / d * BUMP_SPEED, dy / d * BUMP_SPEED]

# ---------------------------------------------------- shared/random.ts

## Math.imul over u32 operands. GDScript ints are 64-bit but a*b can reach
## 2^64 and overflow, so split one operand: the low product stays < 2^49 and
## the high half only contributes its low 16 bits after the shift.
static func imul32(a: int, b: int) -> int:
	a = a & 0xFFFFFFFF
	b = b & 0xFFFFFFFF
	var alo := a & 0xFFFF
	var ahi := a >> 16
	return (alo * b + (((ahi * b) & 0xFFFF) << 16)) & 0xFFFFFFFF

## splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word.
static func splitmix32(a: int) -> int:
	a = (a + 0x9E3779B9) & 0xFFFFFFFF
	var t := a ^ (a >> 16)
	t = imul32(t, 0x21F0AAAD)
	t = t ^ (t >> 15)
	t = imul32(t, 0x735A2D97)
	return t ^ (t >> 15)

## mulberry32 — the tiny seeded PRNG both sides roll.
class Rng:
	var _state: int

	func _init(seed_value: int) -> void:
		_state = seed_value & 0xFFFFFFFF

	## Advance the stream and return the next value in [0,1).
	func next() -> float:
		_state = (_state + 0x6D2B79F5) & 0xFFFFFFFF
		var a := _state
		var t := Sim.imul32(a ^ (a >> 15), 1 | a)
		t = ((t + Sim.imul32(t ^ (t >> 7), 61 | t)) ^ t) & 0xFFFFFFFF
		return float(t ^ (t >> 14)) / 4294967296.0

## Per-shot seed from the input sequence + a synced per-round salt.
static func shot_seed(seq: int, salt: int) -> int:
	return splitmix32((seq ^ imul32(salt, 0x85EBCA6B)) & 0xFFFFFFFF)

# ---------------------------------------------------- shared/spread.ts

const PELLETS := 6
const SPREAD_RAD := 0.38

## The shotgun fan — the SAME derivation on both sides, nothing on the wire.
static func spread_angles(base_angle: float, seq: int, salt: int) -> Array:
	var rng := Rng.new(shot_seed(seq, salt))
	var out := []
	for i in PELLETS:
		out.append(base_angle + (rng.next() - 0.5) * SPREAD_RAD)
	return out

# ---------------------------------------------------- shared/hockey.ts

const PADDLE_RADIUS := 2.2
const PUCK_RADIUS := 1.4
## Per-tick puck damping — dt is fixed, so this is a literal.
const PUCK_FRICTION_K := 0.985
const PUCK_RESTITUTION := 0.92
const PUCK_PUSH_MIN := 14.0

## Puck free flight: bleed speed, integrate, bounce off the walls.
static func step_puck(p, dt: float) -> void:
	p.vx *= PUCK_FRICTION_K
	p.vy *= PUCK_FRICTION_K
	p.x += p.vx * dt
	p.y += p.vy * dt
	var mn := PUCK_RADIUS
	var mx := ARENA_W - PUCK_RADIUS
	var my := ARENA_H - PUCK_RADIUS
	if p.x < mn:
		p.x = mn
		p.vx = absf(p.vx) * PUCK_RESTITUTION
	elif p.x > mx:
		p.x = mx
		p.vx = -absf(p.vx) * PUCK_RESTITUTION
	if p.y < mn:
		p.y = mn
		p.vy = absf(p.vy) * PUCK_RESTITUTION
	elif p.y > my:
		p.y = my
		p.vy = -absf(p.vy) * PUCK_RESTITUTION

## Paddle-puck contact: push the puck out along the contact normal, give it
## the paddle's velocity plus a minimum separation speed, then resolve the
## push-out against the arena walls (a squeezed puck stays inside). Mutates
## `puck`; returns true on contact. ORDER-DEPENDENT — resolve paddles in the
## players-map iteration order, same as the server.
static func collide_paddle_puck(paddle_x: float, paddle_y: float,
		paddle_vx: float, paddle_vy: float, puck) -> bool:
	var dx = puck.x - paddle_x
	var dy = puck.y - paddle_y
	var r := PADDLE_RADIUS + PUCK_RADIUS
	var d2 = dx * dx + dy * dy
	if d2 >= r * r: return false
	var d = sqrt(d2)
	if d == 0.0: d = 1e-6
	var nx = dx / d
	var ny = dy / d
	puck.x = paddle_x + nx * r
	puck.y = paddle_y + ny * r
	var paddle_along = paddle_vx * nx + paddle_vy * ny
	var speed = paddle_along if paddle_along > PUCK_PUSH_MIN else PUCK_PUSH_MIN
	puck.vx = nx * speed + paddle_vx * 0.35
	puck.vy = ny * speed + paddle_vy * 0.35
	var mn := PUCK_RADIUS
	var mx := ARENA_W - PUCK_RADIUS
	var my := ARENA_H - PUCK_RADIUS
	if puck.x < mn:
		puck.x = mn
		puck.vx = absf(puck.vx) * PUCK_RESTITUTION
	elif puck.x > mx:
		puck.x = mx
		puck.vx = -absf(puck.vx) * PUCK_RESTITUTION
	if puck.y < mn:
		puck.y = mn
		puck.vy = absf(puck.vy) * PUCK_RESTITUTION
	elif puck.y > my:
		puck.y = my
		puck.vy = -absf(puck.vy) * PUCK_RESTITUTION
	return true

## The AI paddle's steering, quantized to the same -1/0/1 move input a human
## sends. A pure function of synced state — port of shared/hockey.ts botInput.
## Returns [move_x, move_y].
static func bot_input(bot_x: float, bot_y: float,
		puck_x: float, puck_y: float, enabled: bool) -> Array:
	var chase = enabled and puck_y < ARENA_H / 2.0
	var tx = puck_x if chase else ARENA_W / 2.0
	var ty = puck_y if chase else ARENA_H * 0.2
	var mx = 1 if tx - bot_x > 1.0 else (-1 if tx - bot_x < -1.0 else 0)
	var my = 1 if ty - bot_y > 1.0 else (-1 if ty - bot_y < -1.0 else 0)
	return [mx, my]

# ---------------------------------------------------------- selfcheck

## Cheap check that the port still reproduces the reference numbers (values
## pinned from running the TypeScript original). Returns FAILED check count.
static func selfcheck(log := Callable()) -> int:
	var failed := 0
	var dt := 1.0 / TICK_HZ

	var e := {"x": 50.0, "y": 30.0, "vx": 0.0, "vy": 0.0}
	for i in 5: step_entity(e, 1.0, 0.0, dt)
	var ok: bool = absf(e.x - 56.7) < 1e-12 and e.vx == PLAYER_MAX_SPEED
	if log.is_valid(): log.call("  sim: 5x right  -> x=%s vx=%s (want 56.7 / 34)" % [e.x, e.vx])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	var d := {"x": 50.0, "y": 30.0, "vx": 0.0, "vy": 0.0}
	step_entity(d, 1.0, 1.0, dt)
	ok = d.vx == d.vy and absf(d.vx - 7.77817459305202341113) < 1e-15
	if log.is_valid(): log.call("  sim: diagonal  -> vx=%s vy=%s" % [d.vx, d.vy])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	var w := {"x": PLAYER_HALF + 0.1, "y": 30.0, "vx": -30.0, "vy": 0.0}
	step_entity(w, 0.0, 0.0, dt)
	ok = absf(w.x - PLAYER_HALF) < 1e-12 and w.vx == 0.0
	if log.is_valid(): log.call("  sim: wall      -> x=%s vx=%s" % [w.x, w.vx])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	var f := {"x": 50.0, "y": 30.0, "vx": 0.06, "vy": 0.0}
	step_entity(f, 0.0, 0.0, dt)
	ok = f.vx == 0.0
	if log.is_valid(): log.call("  sim: friction  -> vx=%s (want exactly 0)" % f.vx)
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# The circle's closed form must be evaluable at an arbitrary instant.
	var c := {"x": 50.0, "y": 18.0, "vx": 18.0, "vy": 0.0, "kind": "circle",
		"minX": 22.0, "maxX": 78.0, "baseY": 18.0, "phaseMs": 0.0, "speed": 18.0,
		"lastTeleport": 0.0}
	step_bot(c, dt, 1234.0)
	ok = absf(c.x - 69.6422100736938887167) < 1e-12 \
		and absf(c.y - 26.5519448209259039118) < 1e-12
	if log.is_valid(): log.call("  sim: circle    -> x=%s y=%s" % [c.x, c.y])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# The warp schedule chains within one forward pass.
	var tp := {"x": 70.0, "y": 18.0, "vx": 18.0, "vy": 0.0, "kind": "teleport",
		"minX": 22.0, "maxX": 78.0, "baseY": 18.0, "phaseMs": 0.0, "speed": 18.0,
		"lastTeleport": 1000.0}
	step_bot(tp, dt, 7100.0)
	ok = absf(tp.x - 70.9) < 1e-12 and tp.lastTeleport == 7000.0
	if log.is_valid(): log.call("  sim: teleport  -> x=%s lastTeleport=%s" % [tp.x, tp.lastTeleport])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# A projectile wall bounce flips the sign, not the magnitude.
	var pj := {"x": 99.0, "y": 30.0, "vx": 34.0, "vy": 0.0}
	step_projectile(pj, dt)
	ok = pj.x == ARENA_W and pj.vx == -34.0
	if log.is_valid(): log.call("  sim: bounce    -> x=%s vx=%s" % [pj.x, pj.vx])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# The RNG is uint32 integer math — the module that breaks silently if the
	# port gets a shift or a wrap wrong.
	# Compare the INTEGER stream (r * 2^32 is exact): Godot's float-literal
	# tokenizer parses 21-digit literals one ulp off, so a float compare at
	# 1e-18 would fail on the literal, not the math.
	var rng := Rng.new(0xB07B07)
	var r0 := rng.next()
	var r1 := rng.next()
	var r2 := rng.next()
	ok = int(r0 * 4294967296.0) == 41909008 \
		and int(r1 * 4294967296.0) == 944980053 \
		and int(r2 * 4294967296.0) == 1966572806 \
		and splitmix32(1) == 1580013426 \
		and shot_seed(7, 12345) == 1994071465
	if log.is_valid():
		log.call("  sim: mulberry  -> %s %s %s" % [r0, r1, r2])
		log.call("  sim: seeds     -> splitmix32(1)=%d shotSeed(7,12345)=%d" % [splitmix32(1), shot_seed(7, 12345)])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# The shotgun fan rides entirely on that stream.
	var fan := spread_angles(0.5, 7, 12345)
	ok = absf(fan[0] - 0.599485442587174510720) < 1e-15 \
		and absf(fan[1] - 0.672593814930878552971) < 1e-15
	if log.is_valid(): log.call("  sim: spread    -> %s %s" % [fan[0], fan[1]])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# A seed that EXCEEDS 2^31 — half of all real shots land in this range,
	# and a signed-32 collapse passes the vectors above while failing here.
	var wide := spread_angles(0.5, 50, 3004265928)
	ok = shot_seed(50, 3004265928) == 2712337003 \
		and absf(wide[0] - 0.558667531493119873254) < 1e-15 \
		and absf(wide[5] - 0.613833207678981085387) < 1e-15
	if log.is_valid(): log.call("  sim: wide seed -> shotSeed=%d %s %s" % [shot_seed(50, 3004265928), wide[0], wide[5]])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# Hitscan: a tangent-free hit at t=8, and a clean miss past the radius.
	var t_hit := ray_circle(0, 0, 1, 0, 10, 0, 2, 100)
	var t_miss := ray_circle(0, 0, 1, 0, 10, 5, 2, 100)
	ok = t_hit == 8.0 and t_miss == -1.0
	if log.is_valid(): log.call("  sim: hitscan   -> hit t=%s miss t=%s" % [t_hit, t_miss])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# Puck damping applies BEFORE integration.
	var pk := {"x": 50.0, "y": 30.0, "vx": 20.0, "vy": 0.0}
	step_puck(pk, dt)
	ok = absf(pk.x - 50.985) < 1e-12 and absf(pk.vx - 19.7) < 1e-12
	if log.is_valid(): log.call("  sim: puck      -> x=%s vx=%s" % [pk.x, pk.vx])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# A contact snaps the puck out to the contact circle.
	var contact := {"x": 52.0, "y": 30.0, "vx": 0.0, "vy": 0.0}
	var touched := collide_paddle_puck(50, 30, 10, 0, contact)
	ok = touched and absf(contact.x - 53.6) < 1e-12 and contact.vx == 17.5
	if log.is_valid(): log.call("  sim: contact   -> hit=%s x=%s vx=%s" % [touched, contact.x, contact.vx])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# A paddle squeezing the puck against a wall keeps it INSIDE the arena.
	var pinch := {"x": 50.0, "y": 59.0, "vx": 0.0, "vy": 0.0}
	var pinched := collide_paddle_puck(50, 58, 0, 20, pinch)
	ok = pinched and absf(pinch.y - (ARENA_H - PUCK_RADIUS)) < 1e-12 \
		and absf(pinch.vy + 24.84) < 1e-12
	if log.is_valid(): log.call("  sim: wall pinch-> y=%s vy=%s" % [pinch.y, pinch.vy])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# The score gate is edge-triggered, then locked out for the cooldown.
	var g1 := step_score_gate(GOAL_ZONE_X + 1, ARENA_H / 2.0, 0)
	var g2 := step_score_gate(GOAL_ZONE_X + 1, ARENA_H / 2.0, g1[1])
	ok = g1[0] and not g2[0] and g2[1] == SCORE_COOLDOWN_TICKS - 1
	if log.is_valid(): log.call("  sim: goal gate -> edge=%s repeat=%s ticks=%s" % [g1[0], g2[0], g2[1]])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	# Bump: a contact inside the radius knocks back along the normal, and an
	# armed cooldown suppresses it entirely.
	var bump := collide_bot(50, 30, 0, 51, 30)
	var immune := collide_bot(50, 30, 1, 51, 30)
	ok = bump[0] and not immune[0] and bump[1] == -BUMP_SPEED and bump[2] == 0.0
	if log.is_valid(): log.call("  sim: bump      -> hit=%s immune=%s vx=%s vy=%s" % [bump[0], immune[0], bump[1], bump[2]])
	if not ok:
		failed += 1
		if log.is_valid(): log.call("    ^ FAIL")

	return failed
