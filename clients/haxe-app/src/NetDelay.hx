import io.colyseus.Room;

/**
 * Latency injector (APPS_PLAN §3). The web playground gets delay/jitter from the
 * JS SDK's debug panel; on localhost every other SDK needs its own, or labs
 * 00/01/03 demonstrate nothing.
 *
 * Like the Lua client, this wraps a joined room's `Connection` in place rather
 * than subclassing it: a subscriber to the connection's message event would run
 * ALONGSIDE the room's own handler and so could not delay anything. Here the
 * seam is the function references the connection dispatches through — capture
 * them, queue, and call them when the packet comes due.
 *
 * EVERY inbound callback goes through the queue, not just `onMessage`. This
 * connection has four (`onOpen`/`onMessage`/`onClose`/`onError`) where the Lua
 * client has one `emit` and the C# client one `Dispatch`, so it is the one port
 * where "wrap the seam" does not automatically cover close — and a close that
 * overtakes its own trailing patches tears the room down mid-stream.
 *
 * Two properties are load-bearing:
 *
 *  - No reordering: each packet's deliver-at is clamped to >= the previous
 *    one's, because the wire is a stream and TCP never reorders (the JS debug
 *    panel does the same).
 *  - The wrap happens AFTER the join, so the handshake is never delayed — only
 *    gameplay traffic is. That is what a real link looks like from the room's
 *    point of view, and it keeps a join from blocking on a queue nobody is
 *    draining yet.
 */
class NetDelay {
	public static var delayMs: Float = 0;
	public static var jitterMs: Float = 0;

	static var live: Array<NetDelay> = [];
	static var seed: Int = 0x5EED;

	var conn: Dynamic;
	var room: Dynamic;
	var innerSend: Dynamic;
	var inbound: Array<Packet> = [];
	var outbound: Array<Packet> = [];
	var inLast: Float = 0;
	var outLast: Float = 0;

	function new(conn: Dynamic) {
		this.conn = conn;
	}

	/** A named delay/jitter pair — what the `L` key cycles through. */
	public static var PRESETS: Array<Preset> = [
		{ delay: 0, jitter: 0, label: "off" },
		{ delay: 80, jitter: 10, label: "80 ms + 10 jitter" },
		{ delay: 200, jitter: 0, label: "200 ms" },
		{ delay: 200, jitter: 80, label: "200 ms + 80 jitter" },
		{ delay: 400, jitter: 60, label: "400 ms + 60 jitter" },
	];

	public static var presetIndex: Int = 0;

	public static function presetLabel(): String {
		return PRESETS[presetIndex].label;
	}

	public static function setLatency(delay: Float, jitter: Float): Void {
		delayMs = delay > 0 ? delay : 0;
		jitterMs = jitter > 0 ? jitter : 0;
	}

	public static function usePreset(index: Int): Void {
		presetIndex = ((index % PRESETS.length) + PRESETS.length) % PRESETS.length;
		setLatency(PRESETS[presetIndex].delay, PRESETS[presetIndex].jitter);
	}

	public static function nextPreset(): Void {
		usePreset(presetIndex + 1);
	}

	/** Forget every socket and zero the latency — between acceptance cases. */
	public static function reset(): Void {
		live = [];
		delayMs = 0;
		jitterMs = 0;
		presetIndex = 0;
	}

	/** Kill every live socket uncleanly (close 4010, MAY_TRY_RECONNECT) — the
	 * SDK sees a drop, not a leave, and its auto-reconnect takes over. K key. */
	public static function drop(): Void {
		for (w in live) try w.conn.close(4010) catch (_: Dynamic) {}
	}

	public static function inFlight(): Int {
		var n = 0;
		for (w in live) n += w.inbound.length + w.outbound.length;
		return n;
	}

	/**
	 * Put an injector in front of a joined room's socket. Idempotent: a room that
	 * is already wrapped keeps its existing queue.
	 */
	public static function wrap(room: Dynamic, nowMs: Void -> Float): Void {
		var conn: Dynamic = room.connection;
		if (conn == null) return;
		for (w in live) if (w.conn == conn) return;
		// reconnect built this room a NEW connection — retire wraps still
		// pointing at the old one so their queues can't replay into the room
		live = live.filter(w -> w.room != room);

		var nd = new NetDelay(conn);
		nd.room = room;
		// Reflect.field + callMethod, not a plain capture: `send` is a dynamic
		// function on the Connection, and reading one as a value drops its `this`
		// on some targets — the original body then finds a null socket.
		nd.innerSend = Reflect.field(conn, "send");
		var innerOnMessage: Dynamic = Reflect.field(conn, "onMessage");
		var innerOnClose: Dynamic = Reflect.field(conn, "onClose");
		var innerOnError: Dynamic = Reflect.field(conn, "onError");

		conn.send = function(bytes: haxe.io.Bytes) {
			nd.enqueue(nd.outbound, nowMs(), Send(bytes));
		};
		conn.onMessage = function(bytes: haxe.io.Bytes) {
			nd.enqueue(nd.inbound, nowMs(), Deliver(conn, innerOnMessage, [bytes]));
		};
		// CLOSE AND ERROR RIDE THE SAME QUEUE. This connection exposes four
		// separate callbacks rather than the one dispatch seam the Lua and C#
		// clients wrap, so intercepting only `onMessage` let a close overtake the
		// patches it followed: the room tore down (Room.onLeave -> teardown ->
		// decoder.refs.clear()) while ~200ms of gameplay was still queued here,
		// and every one of those patches then decoded against an empty ref table
		// — four "@colyseus/schema refId not found" per room leave, and a
		// silently skipped structure behind each. The wire never reorders; nor
		// may this.
		conn.onClose = function(data: Dynamic) {
			nd.enqueue(nd.inbound, nowMs(), Deliver(conn, innerOnClose, [data]));
		};
		conn.onError = function(message: String) {
			nd.enqueue(nd.inbound, nowMs(), Deliver(conn, innerOnError, [message]));
		};

		live.push(nd);
	}

	// A tiny LCG rather than Math.random: the injector must not perturb (or be
	// perturbed by) whatever else in the process is drawing random numbers.
	static function oneWay(): Float {
		seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF;
		return delayMs + (seed / 0x40000000) * jitterMs;
	}

	function enqueue(q: Array<Packet>, now: Float, what: Payload): Void {
		var at = now + oneWay();
		var last = (q == inbound) ? inLast : outLast;
		if (at < last) at = last;          // the wire never reorders
		if (q == inbound) inLast = at else outLast = at;
		q.push({ at: at, what: what });
	}

	/** Drain everything due. Call once per frame, on the main loop. */
	public static function pump(now: Float): Void {
		for (w in live) {
			w.drain(w.outbound, now);
			w.drain(w.inbound, now);
		}
	}

	function drain(q: Array<Packet>, now: Float): Void {
		while (q.length > 0 && q[0].at <= now) {
			var p = q.shift();
			switch (p.what) {
				// a drop can close the socket with sends still queued — they
				// belong to the dead link, not the reconnected one. The catch,
				// not an _isOpen guard: conn is Dynamic and property getters
				// don't resolve dynamically (the read yields null = "closed").
				case Send(bytes): try Reflect.callMethod(conn, innerSend, [bytes]) catch (_: Dynamic) {}
				case Deliver(target, handler, args): Reflect.callMethod(target, handler, args);
			}
		}
	}
}

typedef Preset = { delay: Float, jitter: Float, label: String };
typedef Packet = { at: Float, what: Payload };

enum Payload {
	Send(bytes: haxe.io.Bytes);
	/** `args` rather than a lone payload: one case covers onMessage(bytes),
	    onClose(data) and onError(message). */
	Deliver(target: Dynamic, handler: Dynamic, args: Array<Dynamic>);
}
