import io.colyseus.Client;

/**
 * Shell contract + the services every lab shares.
 *
 * Port of src/client/framework/lab.ts + input.ts + pacer.ts. The shell owns the
 * room and hands it to the lab; labs never join and never leave.
 *
 * A lab touches NO Heaps API. It draws through the `Gfx` it is handed, which is
 * what lets the same lab module run under the window and under the headless
 * acceptance harness.
 */
class App {
	public var client: Client;
	public var private_: Bool = false;
	/** Wall-clock milliseconds; the shell sets this so the injector and the
	    pacers share one monotonic timeline. */
	public static var nowMs: Void -> Float = () -> haxe.Timer.stamp() * 1000;

	public function new(client: Client, private_: Bool = false) {
		this.client = client;
		this.private_ = private_;
	}

	/** Ask the shell for a latency preset on mount — labs 00/06/07 need one. */
	public function setLatencyPreset(index: Int): Void {
		NetDelay.usePreset(index);
	}
}

/**
 * WASD / arrows -> tri-state axes, exactly like framework/input.ts.
 * The acceptance harness feeds the SAME accessors, so a lab never learns whether
 * a human or a script is playing.
 */
class Kb {
	public static var autopilot: Bool = false;
	public static var autoX: Int = 0;
	public static var autoY: Int = 0;
	/** Held keys and one-frame edges; the shell fills both. */
	public static var down: Map<String, Bool> = new Map();
	public static var pressed: Map<String, Bool> = new Map();

	/** One-shot key edge. Labs use this, never a raw poll. */
	public static function key(name: String): Bool {
		return pressed.exists(name);
	}

	public static function moveX(): Int {
		if (autopilot) return autoX;
		var l = down.exists("a") || down.exists("left");
		var r = down.exists("d") || down.exists("right");
		return (r == l) ? 0 : (r ? 1 : -1);
	}

	public static function moveY(): Int {
		if (autopilot) return autoY;
		var u = down.exists("w") || down.exists("up");
		var dn = down.exists("s") || down.exists("down");
		return (dn == u) ? 0 : (dn ? 1 : -1);
	}

	public static function anyMove(): Bool {
		return moveX() != 0 || moveY() != 0;
	}
}

/**
 * Fixed-step accumulator for labs WITHOUT a reconciler: predict.tick() only
 * paces once a reconciler adopts the fixed step, but a prediction-free client
 * still has to send one input per server tick.
 */
class Pacer {
	var acc: Float = 0;
	var last: Float = 0;
	var started: Bool = false;
	final stepMs: Float;

	public function new(stepMs: Float) {
		this.stepMs = stepMs;
	}

	public function reset(): Void {
		acc = 0;
		started = false;
	}

	public function steps(now: Float): Int {
		if (!started) { started = true; last = now; return 0; }
		acc += now - last;
		last = now;
		var n = Std.int(acc / stepMs);
		if (n > 5) { n = 5; acc = 0; }        // hitch: drop the backlog
		else acc -= n * stepMs;
		return n;
	}
}
