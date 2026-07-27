import Gfx.Palette;
import h2d.Graphics;
import h2d.Text;

/**
 * The Heaps implementation of the `Gfx` contract (see Gfx.hx for the contract
 * and GfxNull for its headless twin).
 *
 * Everything is one `h2d.Graphics` cleared per frame plus a pool of `h2d.Text`,
 * so the whole client stays a vector playground with no assets.
 *
 * Two coordinate facts live here and nowhere else:
 *   * the arena is 100x60 world units, letterboxed into the window;
 *   * the arena's y points DOWN, which matches Heaps' screen space, so unlike
 *     the Defold backend there is no flip.
 * A lab never learns either.
 */
class GfxHeaps implements Gfx {
	final g: Graphics;
	final texts: Array<Text> = [];
	final font: h2d.Font;
	final root: h2d.Object;

	var scale = 1.0;
	var ox = 0.0;
	var oy = 0.0;
	var stageX = 0.0;
	var stageY = 0.0;
	var stageW = 0.0;
	var stageH = 0.0;
	var laneRect: { x: Float, y: Float, w: Float, h: Float } = null;
	var textCursor = 0;

	var hudX = 0.0;
	var hudY = 0.0;
	var hudCursor = 0.0;

	public function new(root: h2d.Object) {
		this.root = root;
		this.font = hxd.res.DefaultFont.get();
		this.g = new Graphics(root);
	}

	/** Split 0xAARRGGBB into what Heaps wants: an RGB int plus an alpha. */
	static inline function rgb(c: Int): Int return c & 0xFFFFFF;
	static inline function alpha(c: Int): Float return ((c >> 24) & 0xFF) / 255.0;

	inline function sx(x: Float): Float return ox + x * scale;
	inline function sy(y: Float): Float return oy + y * scale;
	inline function s(len: Float): Float return len * scale;

	function fit(x: Float, y: Float, w: Float, h: Float, margin: Float = 28): Void {
		var fx = (w - margin * 2) / Sim.ARENA_W;
		var fy = (h - margin * 2) / Sim.ARENA_H;
		scale = Math.min(fx, fy);
		ox = x + (w - Sim.ARENA_W * scale) / 2;
		oy = y + (h - Sim.ARENA_H * scale) / 2;
	}

	/** Call once per frame before drawing. */
	public function beginFrame(sx: Float, sy: Float, sw: Float, sh: Float,
			hx: Float, hy: Float): Void {
		g.clear();
		stageX = sx; stageY = sy; stageW = sw; stageH = sh;
		laneRect = null;
		fit(sx, sy, sw, sh);
		hudX = hx;
		hudY = hy;
		hudCursor = hy;
		textCursor = 0;
	}

	/** Hide whatever the previous frame left in the pool. */
	public function endFrame(): Void {
		for (i in textCursor...texts.length) texts[i].visible = false;
	}

	function put(x: Float, y: Float, str: String, color: Int, size: Int): Void {
		var t: Text;
		if (textCursor < texts.length) {
			t = texts[textCursor];
		} else {
			t = new Text(font, root);
			texts.push(t);
		}
		textCursor++;
		t.visible = true;
		t.text = str;
		t.textColor = rgb(color);
		t.alpha = alpha(color);
		t.x = x;
		t.y = y;
	}

	// --------------------------------------------------------------- shapes

	public function square(x: Float, y: Float, half: Float, color: Int): Void {
		var h = s(half);
		g.beginFill(rgb(color), alpha(color));
		g.drawRect(sx(x) - h, sy(y) - h, h * 2, h * 2);
		g.endFill();
	}

	public function squareOutline(x: Float, y: Float, half: Float, color: Int, width: Float = 1): Void {
		var h = s(half);
		g.lineStyle(width, rgb(color), alpha(color));
		g.drawRect(sx(x) - h, sy(y) - h, h * 2, h * 2);
		g.lineStyle();
	}

	public function ghostSquare(x: Float, y: Float, half: Float, color: Int): Void {
		var h = s(half);
		var l = sx(x) - h, t = sy(y) - h, r = l + h * 2, b = t + h * 2;
		dashedScreen(l, t, r, t, color);
		dashedScreen(r, t, r, b, color);
		dashedScreen(r, b, l, b, color);
		dashedScreen(l, b, l, t, color);
	}

	public function circle(x: Float, y: Float, r: Float, color: Int): Void {
		g.beginFill(rgb(color), alpha(color));
		g.drawCircle(sx(x), sy(y), s(r));
		g.endFill();
	}

	public function circleOutline(x: Float, y: Float, r: Float, color: Int, dashed: Bool = false): Void {
		var cx = sx(x), cy = sy(y), pr = s(r);
		var seg = 28;
		g.lineStyle(1.5, rgb(color), alpha(color));
		var i = 0;
		while (i < seg) {
			var a0 = i * 2 * Math.PI / seg;
			var a1 = (i + 1) * 2 * Math.PI / seg;
			g.moveTo(cx + Math.cos(a0) * pr, cy + Math.sin(a0) * pr);
			g.lineTo(cx + Math.cos(a1) * pr, cy + Math.sin(a1) * pr);
			i += dashed ? 2 : 1;
		}
		g.lineStyle();
	}

	public function line(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void {
		g.lineStyle(width, rgb(color), alpha(color));
		g.moveTo(sx(x0), sy(y0));
		g.lineTo(sx(x1), sy(y1));
		g.lineStyle();
	}

	function dashedScreen(x0: Float, y0: Float, x1: Float, y1: Float, color: Int): Void {
		g.lineStyle(1.5, rgb(color), alpha(color));
		var n = 8;
		var i = 0;
		while (i < n) {
			var a0 = i / n, a1 = (i + 1) / n;
			g.moveTo(x0 + (x1 - x0) * a0, y0 + (y1 - y0) * a0);
			g.lineTo(x0 + (x1 - x0) * a1, y0 + (y1 - y0) * a1);
			i += 2;
		}
		g.lineStyle();
	}

	public function dashed(x0: Float, y0: Float, x1: Float, y1: Float, color: Int, width: Float = 1): Void {
		dashedScreen(sx(x0), sy(y0), sx(x1), sy(y1), color);
	}

	public function label(x: Float, y: Float, text: String, color: Int, size: Int = 11, dy: Float = 0): Void {
		put(sx(x) - text.length * 3, sy(y) + dy, text, color, size);
	}

	public function zone(x: Float, y: Float, w: Float, h: Float, fill: Int, stroke: Int): Void {
		g.beginFill(rgb(fill), alpha(fill));
		g.drawRect(sx(x), sy(y), s(w), s(h));
		g.endFill();
		g.lineStyle(1.5, rgb(stroke), alpha(stroke));
		g.drawRect(sx(x), sy(y), s(w), s(h));
		g.lineStyle();
	}

	public function arena(): Void {
		var grid = Palette.a(Palette.TEXT_DIM, 0.10);
		g.lineStyle(1, rgb(grid), alpha(grid));
		var x = 10;
		while (x < Sim.ARENA_W) {
			g.moveTo(sx(x), sy(0));
			g.lineTo(sx(x), sy(Sim.ARENA_H));
			x += 10;
		}
		var y = 10;
		while (y < Sim.ARENA_H) {
			g.moveTo(sx(0), sy(y));
			g.lineTo(sx(Sim.ARENA_W), sy(y));
			y += 10;
		}
		var border = Palette.a(Palette.TEXT_DIM, 0.38);
		g.lineStyle(1.5, rgb(border), alpha(border));
		g.drawRect(sx(0), sy(0), s(Sim.ARENA_W), s(Sim.ARENA_H));
		g.lineStyle();
	}

	// ----------------------------------------------------------- split view

	public function lane(index: Int): Void {
		if (index == 0) {
			fit(stageX, stageY, stageW, stageH);
			laneRect = null;
			return;
		}
		var laneH = stageH / 2;
		var y = stageY + (index - 1) * laneH;
		laneRect = { x: stageX, y: y, w: stageW, h: laneH };
		fit(stageX, y, stageW, laneH, 24);
	}

	public function laneTitle(main: String, sub: String, color: Int): Void {
		var r = laneRect;
		var x = (r == null) ? stageX : r.x;
		var y = (r == null) ? stageY : r.y;
		put(x + 16, y + 6, main, color, 12);
		put(x + 16 + main.length * 8 + 14, y + 7, sub, Palette.a(Palette.TEXT_DIM, 0.75), 11);
	}

	public function caption(text: String, color: Int, size: Int = 12): Void {
		put(stageX + stageW / 2 - text.length * 3, stageY + stageH - 22, text, color, size);
	}

	// ------------------------------------------------------------------ hud

	function hudLine(str: String, color: Int): Void {
		put(hudX, hudCursor, str, color, 11);
		hudCursor += 15;
	}

	public function hudSection(title: String): Void {
		hudCursor += 6;
		hudLine(title, Palette.ACCENT);
	}

	public function hudRow(label: String, value: String, color: Int): Void {
		hudLine(StringTools.rpad(label, " ", 28) + value, color);
	}

	public function hudKey(key: String, what: String): Void {
		hudLine('[$key] $what', Palette.TEXT_DIM);
	}

	public function hudNote(text: String): Void {
		// Wrap by hand: h2d.Text has no column layout of its own here.
		var width = 46, line = "";
		for (word in text.split(" ")) {
			if (line.length + word.length + 1 > width) {
				hudLine(line, Palette.TEXT_FAINT);
				line = word;
			} else {
				line = (line.length == 0) ? word : line + " " + word;
			}
		}
		if (line.length > 0) hudLine(line, Palette.TEXT_FAINT);
	}

	public function hudChips(label: String, n: Int, max: Int = 48): Void {
		var capped = n < max ? n : max;
		hudLine(StringTools.rpad(label, " ", 28) + StringTools.lpad("", "|", capped) + ' $n',
			Palette.TEXT);
	}
}
