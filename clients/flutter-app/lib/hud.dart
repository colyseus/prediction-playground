import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'draw_kit.dart';
import 'palette.dart';
import 'spark.dart';

/// Colour bands for a telemetry value — "is this number healthy?".
enum HudTone {
  /// Neutral readout.
  plain(Palette.text),

  /// Within budget.
  good(Palette.good),

  /// Drifting.
  warn(Palette.warn),

  /// Broken.
  bad(Palette.bad);

  const HudTone(this.color);

  /// The value colour this tone paints with.
  final Color color;
}

/// Immediate-mode painted side panel: telemetry rows, sparklines,
/// pending-input chips and the keyboard-controls list.
///
/// Port of `godot-gd-app/scripts/hud.gd` — same cursor arithmetic, same sizes.
/// Call [begin] once per frame, then emit rows top-down; [cursor] is where the
/// next element would land.
class Hud {
  Hud(this.kit);

  /// The kit the HUD paints into. Reassign per frame when the Hud outlives the
  /// canvas (a [DrawKit] is per-`paint()`).
  DrawKit kit;

  double _x = 0.0;
  double _y = 0.0;
  double _w = 0.0;
  double _cursor = 0.0;

  /// Screen y where the next element would be drawn.
  double get cursor => _cursor;

  /// Start a column of [width] px at screen ([x], [y]).
  void begin(double x, double y, double width) {
    _x = x;
    _y = y;
    _w = width;
    _cursor = y;
  }

  /// Underlined group heading.
  void section(String title) {
    _cursor += 10;
    kit.text(_x, _cursor, _w, title, Palette.textFaint, size: 10);
    _cursor += 14;
    kit.rect(Rect.fromLTWH(_x, _cursor, _w, 1), Palette.border);
    _cursor += 6;
  }

  /// Label on the left, value right-aligned and tinted by [tone] — or by
  /// [color], for the rows whose colour identifies a series rather than a
  /// verdict (sparklines, per-lane readouts).
  void row(
    String label,
    String value, {
    HudTone tone = HudTone.plain,
    Color? color,
  }) {
    kit.text(_x, _cursor, _w, label, Palette.textDim, size: 12);
    kit.text(_x, _cursor, _w, value, color ?? tone.color,
        size: 12, align: TextAlign.right);
    _cursor += 18;
  }

  /// A keybinding line: the key in a chip, its meaning beside it. Stands in
  /// for the web build's on-screen controls where a lab is keyboard-only.
  void keyHint(String key, String desc) {
    kit.rect(Rect.fromLTWH(_x, _cursor - 1, 58, 15), Palette.inset);
    kit.text(_x + 4, _cursor - 2, 60, key, Palette.text, size: 10);
    kit.text(_x + 64, _cursor - 2, _w - 64, desc, Palette.textDim, size: 10);
    _cursor += 17;
  }

  /// Wrapped caption.
  void note(String text) {
    final h = kit.textWrapped(_x, _cursor, _w, text, Palette.textFaint, size: 10);
    _cursor += h + 6;
  }

  /// One chip per pending (unacked) input — the row drains as acks land.
  void chips(int count, {String label = 'pending', int max = 48}) {
    row(label, '$count', color: Palette.accent);
    // The count row above is the truth; the chips are the feel of it.
    var cx = _x;
    var cy = _cursor;
    for (var i = 0; i < math.min(count, max); i++) {
      kit.rect(Rect.fromLTWH(cx, cy, 5, 10), Palette.accent.fade(0.75));
      cx += 7;
      if (cx + 5 > _x + _w) {
        cx = _x;
        cy += 12;
      }
    }
    _cursor = cy + 18;
  }

  /// A labelled row plus the sparkline's own inset plot. [value] defaults to
  /// the newest sample at 3 decimals (`hud.ts`'s default format).
  void spark(
    String label,
    Spark s, {
    Color color = Palette.accent,
    String? value,
    double fixedMax = 0,
  }) {
    row(label, value ?? s.last.toStringAsFixed(3), color: color);
    const gh = 30.0;
    final box = Rect.fromLTWH(_x, _cursor, _w, gh);
    kit.rect(box, Palette.inset);
    s.draw(kit, box, color, fixedMax: fixedMax);
    _cursor += gh + 8;
  }

  /// Blank vertical space.
  void gap([double px = 8]) => _cursor += px;

  /// Height consumed since [begin].
  double get height => _cursor - _y;
}
