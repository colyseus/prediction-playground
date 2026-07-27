/**
 * The playground's shared simulation, ported to Haxe.
 *
 * Bit-exact f64 transliteration of the src/shared TypeScript: same op order,
 * same constants. Haxe `Float` is an f64 on hl, so like the C and Lua ports this
 * one holds the server's precision all the way through.
 *
 * The RNG is the exception: it is uint32 integer math. `Int` is 32-bit on hl and
 * `>>>` is already JS's unsigned shift, so the transliteration is direct — but
 * that is a target-dependent claim, which is exactly why `selfcheck()` pins it
 * with reference vectors rather than trusting it. On a 31-bit target (neko) this
 * is the module that breaks, silently.
 */
class Sim {
	public static inline var TICK_HZ = 20;
	public static inline var ARENA_W = 100.0;
	public static inline var ARENA_H = 60.0;
	public static inline var PLAYER_HALF = 1.6;
	public static inline var PLAYER_ACCEL = 220.0;
	public static inline var PLAYER_MAX_SPEED = 34.0;
	public static inline var PLAYER_FRICTION_K = 0.72;
	public static inline var BOT_RADIUS = 1.8;
	public static inline var REMOTE_INTERP_MS = 100.0;
	public static inline var TELEPORT_SNAP_DIST = 8.0;
	public static inline var MAX_REWIND_MS = 500.0;

	/** Math.SQRT1_2 — the exact f64 the JS sim multiplies by. */
	public static inline var SQRT1_2 = 0.70710678118654752440;

	// ------------------------------------------------- shared/movement.ts

	/**
	 * The single deterministic movement step, run identically by the server (once
	 * per received input) and by the reconciler (predict + rollback replay).
	 * sqrt/mul/add only — no exp, no trig.
	 */
	public static function stepEntity(e: Entity, moveX: Float, moveY: Float, dt: Float): Void {
		var ax = moveX, ay = moveY;
		if (ax != 0 && ay != 0) {
			ax *= SQRT1_2;
			ay *= SQRT1_2;
		}

		if (ax != 0 || ay != 0) {
			e.vx += ax * PLAYER_ACCEL * dt;
			e.vy += ay * PLAYER_ACCEL * dt;
		} else {
			e.vx *= PLAYER_FRICTION_K;
			e.vy *= PLAYER_FRICTION_K;
			if (e.vx > -0.05 && e.vx < 0.05) e.vx = 0;
			if (e.vy > -0.05 && e.vy < 0.05) e.vy = 0;
		}

		var sq = e.vx * e.vx + e.vy * e.vy;
		if (sq > PLAYER_MAX_SPEED * PLAYER_MAX_SPEED) {
			var s = PLAYER_MAX_SPEED / Math.sqrt(sq);
			e.vx *= s;
			e.vy *= s;
		}

		e.x += e.vx * dt;
		e.y += e.vy * dt;

		var minX = PLAYER_HALF, maxX = ARENA_W - PLAYER_HALF;
		var minY = PLAYER_HALF, maxY = ARENA_H - PLAYER_HALF;
		if (e.x < minX) { e.x = minX; if (e.vx < 0) e.vx = 0; }
		else if (e.x > maxX) { e.x = maxX; if (e.vx > 0) e.vx = 0; }
		if (e.y < minY) { e.y = minY; if (e.vy < 0) e.vy = 0; }
		else if (e.y > maxY) { e.y = maxY; if (e.vy > 0) e.vy = 0; }
	}

	// ----------------------------------------------------- shared/goal.ts

	public static inline var GOAL_ZONE_X = ARENA_W - 8.0;
	public static inline var GOAL_ZONE_Y = ARENA_H / 2.0 - 9.0;
	public static inline var GOAL_ZONE_W = 8.0;
	public static inline var GOAL_ZONE_H = 18.0;
	/** Re-entry lockout, in fixed steps — reconciled tick state on both sides. */
	public static inline var SCORE_COOLDOWN_TICKS = 50;

	/**
	 * The scoring gate. A pure function of predicted state, so it is
	 * deterministic under rollback replay: `scored` is true on the entry EDGE,
	 * the step that crossed into the zone with the gate open. Whether the goal is
	 * AWARDED stays server-only — the gate itself never mispredicts.
	 */
	public static function stepScoreGate(x: Float, y: Float, scoreTicks: Int): ScoreGate {
		if (scoreTicks > 0) return { scored: false, ticks: scoreTicks - 1 };
		if (x >= GOAL_ZONE_X && y >= GOAL_ZONE_Y && y <= GOAL_ZONE_Y + GOAL_ZONE_H) {
			return { scored: true, ticks: SCORE_COOLDOWN_TICKS };
		}
		return { scored: false, ticks: scoreTicks };
	}

	// ----------------------------------------------- shared/projectile.ts

	public static inline var PROJECTILE_SPEED = 34.0;
	public static inline var PROJECTILE_RADIUS = 0.7;
	public static inline var PROJECTILE_TTL_MS = 2600.0;

	/** Constant-velocity flight with wall bounces. */
	public static function stepProjectile(p: Entity, dt: Float): Void {
		p.x += p.vx * dt;
		p.y += p.vy * dt;
		if (p.x < 0) { p.x = 0; p.vx = Math.abs(p.vx); }
		else if (p.x > ARENA_W) { p.x = ARENA_W; p.vx = -Math.abs(p.vx); }
		if (p.y < 0) { p.y = 0; p.vy = Math.abs(p.vy); }
		else if (p.y > ARENA_H) { p.y = ARENA_H; p.vy = -Math.abs(p.vy); }
	}

	// --------------------------------------------------- shared/movers.ts

	/** Teleporter warp period, on the shared server-clock timeline. */
	public static inline var TELEPORT_PERIOD_MS = 3000.0;
	/** How often wander bots pick a new (server-secret) heading. */
	public static inline var WANDER_TURN_MS = 900.0;

	/** Horizontal ping-pong between minX and maxX at |vx| = speed. */
	static function patrol(b: BotState, dt: Float): Void {
		b.x += b.vx * dt;
		b.y = b.baseY;
		if (b.x < b.minX) { b.x = b.minX; b.vx = Math.abs(b.vx); }
		else if (b.x > b.maxX) { b.x = b.maxX; b.vx = -Math.abs(b.vx); }
	}

	/**
	 * Run by the server each fixed tick AND by the client's reckon mode to
	 * forward-simulate from the latest snapshot to the present. `elapsedMs` is the
	 * shared server-clock timeline, which is what makes time-sampled motion (the
	 * circle's closed form, the teleport schedule) evaluable at ANY instant.
	 *
	 * "wander" is deliberately only PARTLY predictable: it integrates velocity,
	 * but the heading changes are a server-side secret, so reckon extrapolates
	 * straight through every turn and gets corrected. That error is the lesson.
	 */
	public static function stepBot(b: BotState, dt: Float, elapsedMs: Float): Void {
		switch (b.kind) {
			case "circle":
				var cx = (b.minX + b.maxX) / 2;
				var rx = (b.maxX - b.minX) / 2;
				var ry = Math.min(12.0, ARENA_H / 2 - BOT_RADIUS - 2);
				var w = b.speed / rx;                          // rad/s
				var t = (elapsedMs + b.phaseMs) / 1000.0;
				b.x = cx + rx * Math.cos(w * t);
				b.y = b.baseY + ry * Math.sin(w * t);
				b.vx = -rx * w * Math.sin(w * t);
				b.vy = ry * w * Math.cos(w * t);

			case "teleport":
				patrol(b, dt);
				// Predict the warp from the synced schedule: jump half the patrol
				// span (wrapping) every period — a constant, visible cut.
				while (b.lastTeleport > 0 && elapsedMs - b.lastTeleport >= TELEPORT_PERIOD_MS) {
					var span = b.maxX - b.minX;
					b.x = b.minX + ((b.x - b.minX) + span / 2) % span;
					b.lastTeleport += TELEPORT_PERIOD_MS;
				}

			case "wander":
				b.x += b.vx * dt;
				b.y += b.vy * dt;
				var lo = BOT_RADIUS, hiX = ARENA_W - BOT_RADIUS, hiY = ARENA_H - BOT_RADIUS;
				if (b.x < lo) { b.x = lo; b.vx = Math.abs(b.vx); }
				else if (b.x > hiX) { b.x = hiX; b.vx = -Math.abs(b.vx); }
				if (b.y < lo) { b.y = lo; b.vy = Math.abs(b.vy); }
				else if (b.y > hiY) { b.y = hiY; b.vy = -Math.abs(b.vy); }

			default:
				patrol(b, dt);
		}
	}

	// -------------------------------------------------- shared/hitscan.ts

	/**
	 * 2D hitscan: ray vs circle. Returns the ray parameter t (distance along the
	 * unit direction) of the nearest intersection, or -1 on a miss. Pure math,
	 * shared so the client's shot preview and the server's resolution cannot drift.
	 */
	public static function rayCircle(ox: Float, oy: Float, dx: Float, dy: Float,
			cx: Float, cy: Float, r: Float, maxDist: Float): Float {
		var mx = ox - cx, my = oy - cy;
		var b = mx * dx + my * dy;
		var c = mx * mx + my * my - r * r;
		if (c > 0 && b > 0) return -1;              // outside, pointing away
		var disc = b * b - c;
		if (disc < 0) return -1;
		var t = -b - Math.sqrt(disc);
		var hit = t < 0 ? 0 : t;                    // inside the circle = t 0
		return hit <= maxDist ? hit : -1;
	}

	// ----------------------------------------------------- shared/bump.ts

	/**
	 * Post-bump immunity, in fixed steps — a RECONCILED tick gate: both sides run
	 * the identical countdown, so "can I be bumped?" is never a misprediction.
	 */
	public static inline var BUMP_COOLDOWN_TICKS = 12;
	public static inline var BUMP_SPEED = 48.0;

	/** Cooldown countdown — run BEFORE the movement step on both sides. */
	public static inline function stepBumpGate(bumpTicks: Int): Int {
		return bumpTicks > 0 ? bumpTicks - 1 : bumpTicks;
	}

	/**
	 * Player-vs-bot bump test at an agreed bot position. Returns the knockback
	 * velocity, or null. The CALLER applies it and re-arms bumpTicks — on the
	 * client that happens inside the reconciler step, so the whole outcome
	 * (velocity + immunity window) rides adopt+replay.
	 */
	public static function collideBot(px: Float, py: Float, bumpTicks: Int,
			botX: Float, botY: Float): Null<Knock> {
		if (bumpTicks > 0) return null;
		var dx = px - botX, dy = py - botY;
		var r = PLAYER_HALF + BOT_RADIUS;
		var d2 = dx * dx + dy * dy;
		if (d2 >= r * r) return null;
		var d = Math.sqrt(d2);
		if (d == 0) d = 1e-6;
		return { vx: dx / d * BUMP_SPEED, vy: dy / d * BUMP_SPEED };
	}

	// --------------------------------------------------- shared/random.ts

	/** The unsigned value of a 32-bit pattern, as an f64 — JS's `>>> 0`. */
	static inline function u32(v: Int): Float {
		return v < 0 ? v + 4294967296.0 : v;
	}

	/** splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word. */
	public static function splitmix32(a: Int): Float {
		a = a + 0x9e3779b9;
		var t = a ^ (a >>> 16);
		t = t * 0x21f0aaad;
		t = t ^ (t >>> 15);
		t = t * 0x735a2d97;
		return u32(t ^ (t >>> 15));
	}

	/** Per-shot seed from the input sequence + a synced per-round salt. */
	public static function shotSeed(seq: Int, salt: Int): Float {
		return splitmix32(seq ^ (salt * 0x85ebca6b));
	}

	// ----------------------------------------------------- shared/spread.ts

	public static inline var PELLETS = 6;
	public static inline var SPREAD_RAD = 0.38;

	/**
	 * The shotgun fan — the SAME derivation on both sides, with nothing random on
	 * the wire: the seed is (input seq, synced per-room salt), so client and
	 * server roll identical pellets for the same shot.
	 */
	public static function spreadAngles(baseAngle: Float, seq: Int, salt: Int): Array<Float> {
		var rng = new Rng(Std.int(shotSeed(seq, salt)));
		var out = [];
		for (i in 0...PELLETS) out.push(baseAngle + (rng.next() - 0.5) * SPREAD_RAD);
		return out;
	}

	// ----------------------------------------------------- shared/hockey.ts

	public static inline var PADDLE_RADIUS = 2.2;
	public static inline var PUCK_RADIUS = 1.4;
	/** Per-tick puck damping — dt is fixed, so this is a literal. */
	public static inline var PUCK_FRICTION_K = 0.985;
	public static inline var PUCK_RESTITUTION = 0.92;
	public static inline var PUCK_PUSH_MIN = 14.0;

	/** Puck free flight: bleed speed, integrate, bounce off the walls. */
	public static function stepPuck(p: Entity, dt: Float): Void {
		p.vx *= PUCK_FRICTION_K;
		p.vy *= PUCK_FRICTION_K;
		p.x += p.vx * dt;
		p.y += p.vy * dt;
		var lo = PUCK_RADIUS, hiX = ARENA_W - PUCK_RADIUS, hiY = ARENA_H - PUCK_RADIUS;
		if (p.x < lo) { p.x = lo; p.vx = Math.abs(p.vx) * PUCK_RESTITUTION; }
		else if (p.x > hiX) { p.x = hiX; p.vx = -Math.abs(p.vx) * PUCK_RESTITUTION; }
		if (p.y < lo) { p.y = lo; p.vy = Math.abs(p.vy) * PUCK_RESTITUTION; }
		else if (p.y > hiY) { p.y = hiY; p.vy = -Math.abs(p.vy) * PUCK_RESTITUTION; }
	}

	/**
	 * Paddle-puck contact: push the puck out of penetration along the contact
	 * normal and give it the paddle's velocity plus a minimum separation speed.
	 * Deterministic (sqrt/mul/add only) and ORDER-DEPENDENT — both sides must
	 * resolve paddles in the same order, which is the players-map iteration order.
	 */
	public static function collidePaddlePuck(paddleX: Float, paddleY: Float,
			paddleVx: Float, paddleVy: Float, puck: Entity): Bool {
		var dx = puck.x - paddleX, dy = puck.y - paddleY;
		var r = PADDLE_RADIUS + PUCK_RADIUS;
		var d2 = dx * dx + dy * dy;
		if (d2 >= r * r) return false;
		var d = Math.sqrt(d2);
		if (d == 0) d = 1e-6;
		var nx = dx / d, ny = dy / d;
		puck.x = paddleX + nx * r;
		puck.y = paddleY + ny * r;
		var along = paddleVx * nx + paddleVy * ny;
		var speed = along > PUCK_PUSH_MIN ? along : PUCK_PUSH_MIN;
		puck.vx = nx * speed + paddleVx * 0.35;
		puck.vy = ny * speed + paddleVy * 0.35;
		return true;
	}

	// ------------------------------------------------------ startup canary

	/**
	 * Cheap check that the port still reproduces the reference numbers (pinned
	 * from running the TypeScript original). Returns the number of FAILED checks.
	 */
	public static function selfcheck(?log: String -> Void): Int {
		var failed = 0;
		var dt = 1.0 / TICK_HZ;
		inline function check(ok: Bool, line: String) {
			if (log != null) log(line);
			if (!ok) failed++;
		}

		var e: Entity = { x: 50, y: 30, vx: 0, vy: 0 };
		for (_ in 0...5) stepEntity(e, 1, 0, dt);
		check(Math.abs(e.x - 56.7) < 1e-12 && e.vx == PLAYER_MAX_SPEED,
			'  sim: 5x right  -> x=${e.x} vx=${e.vx} (want 56.7 / 34)');

		var d: Entity = { x: 50, y: 30, vx: 0, vy: 0 };
		stepEntity(d, 1, 1, dt);
		check(d.vx == d.vy && Math.abs(d.vx - 7.77817459305202341113) < 1e-15,
			'  sim: diagonal  -> vx=${d.vx} vy=${d.vy}');

		var w: Entity = { x: PLAYER_HALF + 0.1, y: 30, vx: -30, vy: 0 };
		stepEntity(w, 0, 0, dt);
		check(Math.abs(w.x - PLAYER_HALF) < 1e-12 && w.vx == 0,
			'  sim: wall      -> x=${w.x} vx=${w.vx}');

		var f: Entity = { x: 50, y: 30, vx: 0.06, vy: 0 };
		stepEntity(f, 0, 0, dt);
		check(f.vx == 0, '  sim: friction  -> vx=${f.vx} (want exactly 0)');

		var c: BotState = { x: 50, y: 18, vx: 18, vy: 0, kind: "circle",
			minX: 22, maxX: 78, baseY: 18, phaseMs: 0, speed: 18, lastTeleport: 0 };
		stepBot(c, dt, 1234);
		check(Math.abs(c.x - 69.6422100736938887167) < 1e-12
			&& Math.abs(c.y - 26.5519448209259039118) < 1e-12,
			'  sim: circle    -> x=${c.x} y=${c.y}');

		var tp: BotState = { x: 70, y: 18, vx: 18, vy: 0, kind: "teleport",
			minX: 22, maxX: 78, baseY: 18, phaseMs: 0, speed: 18, lastTeleport: 1000 };
		stepBot(tp, dt, 7100);
		check(Math.abs(tp.x - 70.9) < 1e-12 && tp.lastTeleport == 7000,
			'  sim: teleport  -> x=${tp.x} lastTeleport=${tp.lastTeleport}');

		var pj: Entity = { x: 99, y: 30, vx: 34, vy: 0 };
		stepProjectile(pj, dt);
		check(pj.x == ARENA_W && pj.vx == -34.0, '  sim: bounce    -> x=${pj.x} vx=${pj.vx}');

		var rng = new Rng(0xB07B07);
		var r0 = rng.next(), r1 = rng.next(), r2 = rng.next();
		check(Math.abs(r0 - 0.00975770130753517150879) < 1e-18
			&& Math.abs(r1 - 0.220020313980057835579) < 1e-15
			&& Math.abs(r2 - 0.457878412213176488876) < 1e-15
			&& splitmix32(1) == 1580013426.0
			&& shotSeed(7, 12345) == 1994071465.0,
			'  sim: mulberry  -> $r0 $r1 $r2 / splitmix32(1)=${splitmix32(1)} shotSeed=${shotSeed(7, 12345)}');

		var fan = spreadAngles(0.5, 7, 12345);
		check(Math.abs(fan[0] - 0.599485442587174510720) < 1e-15
			&& Math.abs(fan[1] - 0.672593814930878552971) < 1e-15,
			'  sim: spread    -> ${fan[0]} ${fan[1]}');

		var tHit = rayCircle(0, 0, 1, 0, 10, 0, 2, 100);
		var tMiss = rayCircle(0, 0, 1, 0, 10, 5, 2, 100);
		check(tHit == 8.0 && tMiss == -1, '  sim: hitscan   -> hit t=$tHit miss t=$tMiss');

		var pk: Entity = { x: 50, y: 30, vx: 20, vy: 0 };
		stepPuck(pk, dt);
		check(Math.abs(pk.x - 50.985) < 1e-12 && Math.abs(pk.vx - 19.7) < 1e-12,
			'  sim: puck      -> x=${pk.x} vx=${pk.vx}');

		var contact: Entity = { x: 52, y: 30, vx: 0, vy: 0 };
		var touched = collidePaddlePuck(50, 30, 10, 0, contact);
		check(touched && Math.abs(contact.x - 53.6) < 1e-12 && contact.vx == 17.5,
			'  sim: contact   -> hit=$touched x=${contact.x} vx=${contact.vx}');

		var g1 = stepScoreGate(GOAL_ZONE_X + 1, ARENA_H / 2, 0);
		var g2 = stepScoreGate(GOAL_ZONE_X + 1, ARENA_H / 2, g1.ticks);
		check(g1.scored && !g2.scored && g2.ticks == SCORE_COOLDOWN_TICKS - 1,
			'  sim: goal gate -> edge=${g1.scored} repeat=${g2.scored} ticks=${g2.ticks}');

		var bump = collideBot(50, 30, 0, 51, 30);
		var immune = collideBot(50, 30, 1, 51, 30);
		check(bump != null && bump.vx == -BUMP_SPEED && bump.vy == 0 && immune == null,
			'  sim: bump      -> vx=${bump != null ? bump.vx : 0} immune=${immune == null}');

		return failed;
	}
}

/** x/y/vx/vy — players, projectiles and the puck all step through this shape. */
typedef Entity = { x: Float, y: Float, vx: Float, vy: Float };

/**
 * Structural bot state. The reckon scratch is a full copy of the entity, so
 * fields the client never attached (kind, minX, ...) are readable here.
 */
typedef BotState = {
	x: Float, y: Float, vx: Float, vy: Float,
	kind: String,
	minX: Float, maxX: Float, baseY: Float,
	phaseMs: Float, speed: Float, lastTeleport: Float,
};

typedef Knock = { vx: Float, vy: Float };
typedef ScoreGate = { scored: Bool, ticks: Int };

/**
 * mulberry32 — the tiny seeded PRNG both sides roll. A class so a stream is a
 * value you can hold and advance, without a closure per shot.
 */
class Rng {
	var state: Int;

	public function new(seed: Int) {
		this.state = seed;
	}

	/** Advance the stream and return the next value in [0,1). */
	public function next(): Float {
		state = state + 0x6d2b79f5;
		var a = state;
		var t = (a ^ (a >>> 15)) * (1 | a);
		t = (t + ((t ^ (t >>> 7)) * (61 | t))) ^ t;
		var u = t ^ (t >>> 14);
		return (u < 0 ? u + 4294967296.0 : u) / 4294967296.0;
	}
}
