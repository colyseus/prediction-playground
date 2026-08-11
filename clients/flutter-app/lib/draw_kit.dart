import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'palette.dart';
import 'sim/constants.dart';
import 'world_view.dart';

/// The whole drawing vocabulary a lab is allowed to use, over one [Canvas] and
/// one [WorldView].
///
/// Port of `godot-gd-app/scripts/draw_kit.gd` (itself a port of the web build's
/// `framework/draw.ts`) — labs never touch the canvas directly, so every client
/// renders the same shapes with the same weights.
///
/// Coordinates are **world units** unless a method says otherwise; the
/// `*Screen` variants and [rect]/[text] take screen pixels, for HUD chrome.
///
/// Cheap to construct: make one per `paint()` call and let the reused [Paint]
/// objects pay off across the hundreds of draws inside a frame.
class DrawKit {
  DrawKit(this.canvas, this.view);

  /// The canvas being painted this frame.
  final Canvas canvas;

  /// World↔screen transform for this frame.
  final WorldView view;

  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  // TextPainter layout is the expensive part of a HUD frame and the strings
  // barely change; keyed by everything that affects the laid-out result.
  static final Map<String, TextPainter> _textCache = {};
  static const int _textCacheMax = 600;

  // ---------------------------------------------------------------- screen

  /// Filled screen-space rectangle.
  void rect(Rect r, Color color) {
    canvas.drawRect(r, _fill..color = color);
  }

  /// Screen-space segment. Skips degenerate ones (Godot's `Draw.line` guard).
  void lineScreen(Offset a, Offset b, Color color, {double width = 1.0}) {
    if ((b - a).distanceSquared < 0.0001) return;
    canvas.drawLine(a, b, _stroke..color = color..strokeWidth = width);
  }

  /// Screen-space dashed segment. Defaults match `draw.ts`'s `dash: [4, 3]`.
  void dashedScreen(
    Offset a,
    Offset b,
    Color color, {
    double width = 1.0,
    double dash = 4,
    double gap = 3,
  }) {
    final d = b - a;
    final len = d.distance;
    if (len < 0.5) return;
    final u = d / len;
    var t = 0.0;
    while (t < len) {
      lineScreen(a + u * t, a + u * math.min(t + dash, len), color, width: width);
      t += dash + gap;
    }
  }

  // ----------------------------------------------------------------- world

  /// Straight line between two world points.
  void line(
    double x0,
    double y0,
    double x1,
    double y1,
    Color color, {
    double width = 1.5,
  }) {
    lineScreen(
      Offset(view.sx(x0), view.sy(y0)),
      Offset(view.sx(x1), view.sy(y1)),
      color,
      width: width,
    );
  }

  /// Dashed line between two world points.
  void dashedLine(
    double x0,
    double y0,
    double x1,
    double y1,
    Color color, {
    double width = 1.0,
    double dash = 4,
    double gap = 3,
  }) {
    dashedScreen(
      Offset(view.sx(x0), view.sy(y0)),
      Offset(view.sx(x1), view.sy(y1)),
      color,
      width: width,
      dash: dash,
      gap: gap,
    );
  }

  /// Filled square centred on the world point, [half] world units to a side
  /// from the centre — the player shape.
  void square(double x, double y, double half, Color fill) {
    final s = view.s(half);
    rect(Rect.fromLTWH(view.sx(x) - s, view.sy(y) - s, s * 2.0, s * 2.0), fill);
  }

  /// Stroked square outline.
  void squareOutline(
    double x,
    double y,
    double half,
    Color color, {
    double width = 1.5,
  }) {
    final s = view.s(half);
    canvas.drawRect(
      Rect.fromLTWH(view.sx(x) - s, view.sy(y) - s, s * 2.0, s * 2.0),
      _stroke
        ..color = color
        ..strokeWidth = width,
    );
  }

  /// Dashed outline "ghost" — the standard marker for a raw server pose.
  void ghostSquare(double x, double y, double half, Color color) {
    final s = view.s(half);
    final l = view.sx(x) - s;
    final t = view.sy(y) - s;
    final r = l + s * 2.0;
    final b = t + s * 2.0;
    // dash [4,3] / lineWidth 1.5 — draw.ts drawGhostSquare.
    dashedScreen(Offset(l, t), Offset(r, t), color, width: 1.5);
    dashedScreen(Offset(r, t), Offset(r, b), color, width: 1.5);
    dashedScreen(Offset(r, b), Offset(l, b), color, width: 1.5);
    dashedScreen(Offset(l, b), Offset(l, t), color, width: 1.5);
  }

  /// Filled disc — bots, pucks, projectiles, pellets.
  void circle(double x, double y, double r, Color color) {
    canvas.drawCircle(
      Offset(view.sx(x), view.sy(y)),
      view.s(r),
      _fill..color = color,
    );
  }

  /// Circle outline; [dashed] drops every other segment of the 28-segment ring
  /// (draw_kit.gd's `SEG`), which reads as a "not authoritative" hull.
  void circleOutline(
    double x,
    double y,
    double r,
    Color color, {
    double width = 1.5,
    bool dashed = false,
  }) {
    final cx = view.sx(x);
    final cy = view.sy(y);
    final pr = view.s(r);
    if (!dashed) {
      canvas.drawCircle(
        Offset(cx, cy),
        pr,
        _stroke
          ..color = color
          ..strokeWidth = width,
      );
      return;
    }
    const seg = 28;
    for (var i = 0; i < seg; i += 2) {
      final a0 = i * 2 * math.pi / seg;
      final a1 = (i + 1) * 2 * math.pi / seg;
      lineScreen(
        Offset(cx + math.cos(a0) * pr, cy + math.sin(a0) * pr),
        Offset(cx + math.cos(a1) * pr, cy + math.sin(a1) * pr),
        color,
        width: width,
      );
    }
  }

  /// Correction vector: a shaft plus a filled head, in world coords. Ported
  /// from `draw.ts` `drawArrow`, head size and all.
  void arrow(
    double x0,
    double y0,
    double x1,
    double y1,
    Color color, {
    double width = 2,
  }) {
    final ax = view.sx(x0), ay = view.sy(y0);
    final bx = view.sx(x1), by = view.sy(y1);
    final dx = bx - ax, dy = by - ay;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 2) return;
    lineScreen(Offset(ax, ay), Offset(bx, by), color, width: width);
    final hs = math.min(8.0, len * 0.4);
    final ux = dx / len, uy = dy / len;
    final head = Path()
      ..moveTo(bx, by)
      ..lineTo(bx - ux * hs - uy * hs * 0.5, by - uy * hs + ux * hs * 0.5)
      ..lineTo(bx - ux * hs + uy * hs * 0.5, by - uy * hs - ux * hs * 0.5)
      ..close();
    canvas.drawPath(head, _fill..color = color);
  }

  /// Crosshair marker (shot-impact style) — ring plus 1.5×r arms.
  void marker(double x, double y, double r, Color color) {
    final px = view.sx(x), py = view.sy(y), pr = view.s(r);
    canvas.drawCircle(
      Offset(px, py),
      pr,
      _stroke
        ..color = color
        ..strokeWidth = 1.5,
    );
    lineScreen(Offset(px - pr * 1.5, py), Offset(px + pr * 1.5, py), color,
        width: 1.5);
    lineScreen(Offset(px, py - pr * 1.5), Offset(px, py + pr * 1.5), color,
        width: 1.5);
  }

  /// The arena: a grid every 10 world units plus the border. Colours are
  /// `draw.ts`'s literal `rgba(138,160,192, 0.07 / 0.35)` — [Palette.textDim]
  /// is that same rgb.
  void arena({bool grid = true}) {
    if (grid) {
      final path = Path();
      for (var x = 10.0; x < arenaW; x += 10) {
        path.moveTo(view.sx(x), view.sy(0));
        path.lineTo(view.sx(x), view.sy(arenaH));
      }
      for (var y = 10.0; y < arenaH; y += 10) {
        path.moveTo(view.sx(0), view.sy(y));
        path.lineTo(view.sx(arenaW), view.sy(y));
      }
      canvas.drawPath(
        path,
        _stroke
          ..color = Palette.textDim.fade(0.07)
          ..strokeWidth = 1.0,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(view.sx(0), view.sy(0), view.sx(arenaW), view.sy(arenaH)),
      _stroke
        ..color = Palette.textDim.fade(0.35)
        ..strokeWidth = 1.5,
    );
  }

  // ------------------------------------------------------------------ text

  /// Screen-space text laid out in a [w]-wide box at ([x], [y]) — [y] is the
  /// TOP of the line, matching the Godot port's baseline arithmetic.
  void text(
    double x,
    double y,
    double w,
    String s,
    Color color, {
    double size = 11,
    TextAlign align = TextAlign.left,
  }) {
    _layout(s, color, size, align, w, wrap: false).paint(canvas, Offset(x, y));
  }

  /// Word-wrapped screen-space text; returns the height it consumed.
  double textWrapped(
    double x,
    double y,
    double w,
    String s,
    Color color, {
    double size = 11,
  }) {
    final tp = _layout(s, color, size, TextAlign.left, w, wrap: true);
    tp.paint(canvas, Offset(x, y));
    return tp.height;
  }

  /// Caption centred on a WORLD point, offset [dy] screen px — lane titles and
  /// entity tags (draw_kit.gd's `label`: a 180px box centred on the point).
  void label(
    double x,
    double y,
    String s,
    Color color, {
    double size = 11,
    double dy = 0,
  }) {
    text(view.sx(x) - 90, view.sy(y) + dy, 180, s, color,
        size: size, align: TextAlign.center);
  }

  TextPainter _layout(
    String s,
    Color color,
    double size,
    TextAlign align,
    double w, {
    required bool wrap,
  }) {
    final key = '$s ${color.toARGB32()} $size '
        '${align.index} $w $wrap';
    final hit = _textCache[key];
    if (hit != null) return hit;
    if (_textCache.length >= _textCacheMax) _textCache.clear();
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          height: 1.25,
          // Telemetry columns only line up with fixed-width digits.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: wrap ? null : 1,
      ellipsis: wrap ? null : '…',
    )..layout(minWidth: w, maxWidth: w);
    _textCache[key] = tp;
    return tp;
  }
}
