/**
 * The drawing contract labs are written against — and nothing else.
 *
 * That is what lets the acceptance harness run the REAL lab modules headless:
 * swap `GfxNull` in for the Heaps backend and every call becomes a no-op, while
 * the netcode under test runs untouched.
 *
 * World coordinates are the shared 100x60 arena; the backend letterboxes.
 * Colours are 0xAARRGGBB.
 */
interface Gfx {
	/** Filled square centred on (x, y), `half` world units to a side. */
	function square(x: Float, y: Float, half: Float, color: Int): Void;
	function squareOutline(x: Float, y: Float, half: Float, color: Int, width: Float = 1): Void;
	/** Dashed outline — the standard raw-server-pose ghost. */
	function ghostSquare(x: Float, y: Float, half: Float, color: Int): Void;

	function circle(x: Float, y: Float, r: Float, color: Int): Void;
	function circleOutline(x: Float, y: Float, r: Float, color: Int, dashed: Bool = false): Void;

	/** Segment between two WORLD points. */
	function line(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void;
	function dashed(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void;

	/** Text anchored at a world point, offset `dy` pixels (canvas y-down). */
	function label(x: Float, y: Float, text: String, color: Int, size: Int = 11, dy: Float = 0): Void;

	/** Filled + outlined world rectangle: the goal zone, and anything like it. */
	function zone(x: Float, y: Float, w: Float, h: Float, fill: Int, stroke: Int): Void;

	/** The arena grid and border. The shell draws this unless the lab owns it. */
	function arena(): Void;

	/**
	 * Split-screen: subsequent world draws land in lane 1 (top) or 2 (bottom);
	 * 0 restores the full stage. Only the hero lab uses this, and it exists so
	 * that lab never has to learn the backend's pixel geometry.
	 */
	function lane(index: Int): Void;
	function laneTitle(main: String, sub: String, color: Int): Void;
	/** A centred line under the stage — the hero's readout and caption. */
	function caption(text: String, color: Int, size: Int = 12): Void;

	function hudSection(title: String): Void;
	function hudRow(label: String, value: String, color: Int): Void;
	function hudKey(key: String, what: String): Void;
	function hudNote(text: String): Void;
	function hudChips(label: String, n: Int, max: Int = 48): Void;
}

/** The palette, shared by every backend: a lab picking colours per backend is a bug. */
class Palette {
	public static inline var BG = 0xFF0A0F1A;
	public static inline var PANEL = 0xFF0E1626;
	public static inline var TEXT = 0xFFD8E2F0;
	public static inline var TEXT_DIM = 0xFF8AA0C0;
	public static inline var TEXT_FAINT = 0xFF5E7196;
	public static inline var ACCENT = 0xFFFFD36B;
	public static inline var GOOD = 0xFF7BE08A;
	public static inline var WARN = 0xFFFFB454;
	public static inline var BAD = 0xFFFF6688;
	public static inline var BLUE = 0xFF6DB3FF;

	/** Same colour, different alpha (0..1). */
	public static function a(color: Int, alpha: Float): Int {
		var byte = Std.int(Math.max(0, Math.min(1, alpha)) * 255);
		return (byte << 24) | (color & 0x00FFFFFF);
	}

	/** Player colour from the server hue byte — hsl(hue/256*360, 72%, 62%). */
	public static function hue(h8: Int, alpha: Float = 1): Int {
		var h = (h8 / 256 * 360) % 360, s = 0.72, l = 0.62;
		var c = (1 - Math.abs(2 * l - 1)) * s;
		var hp = h / 60;
		var x = c * (1 - Math.abs(hp % 2 - 1));
		var r = 0.0, g = 0.0, b = 0.0;
		if (hp < 1) { r = c; g = x; }
		else if (hp < 2) { r = x; g = c; }
		else if (hp < 3) { g = c; b = x; }
		else if (hp < 4) { g = x; b = c; }
		else if (hp < 5) { r = x; b = c; }
		else { r = c; b = x; }
		var m = l - c / 2;
		return a((Std.int((r + m) * 255) << 16) | (Std.int((g + m) * 255) << 8)
			| Std.int((b + m) * 255), alpha);
	}
}

/** Every call a no-op — the headless half of the contract. */
class GfxNull implements Gfx {
	public function new() {}
	public function square(x: Float, y: Float, half: Float, color: Int): Void {}
	public function squareOutline(x: Float, y: Float, half: Float, color: Int, width: Float = 1): Void {}
	public function ghostSquare(x: Float, y: Float, half: Float, color: Int): Void {}
	public function circle(x: Float, y: Float, r: Float, color: Int): Void {}
	public function circleOutline(x: Float, y: Float, r: Float, color: Int, dashed: Bool = false): Void {}
	public function line(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void {}
	public function dashed(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void {}
	public function label(x: Float, y: Float, text: String, color: Int, size: Int = 11, dy: Float = 0): Void {}
	public function zone(x: Float, y: Float, w: Float, h: Float, fill: Int, stroke: Int): Void {}
	public function arena(): Void {}
	public function lane(index: Int): Void {}
	public function laneTitle(main: String, sub: String, color: Int): Void {}
	public function caption(text: String, color: Int, size: Int = 12): Void {}
	public function hudSection(title: String): Void {}
	public function hudRow(label: String, value: String, color: Int): Void {}
	public function hudKey(key: String, what: String): Void {}
	public function hudNote(text: String): Void {}
	public function hudChips(label: String, n: Int, max: Int = 48): Void {}
}
