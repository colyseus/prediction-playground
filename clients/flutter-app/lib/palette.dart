import 'package:flutter/widgets.dart';

/// The playground palette — the same hex values as the web build's
/// `index.html` and `godot-gd-app/scripts/palette.gd`, so a lab reads the same
/// on every client.
class Palette {
  const Palette._();

  /// Window background.
  static const Color bg = Color(0xFF0A0F1A);

  /// Side-panel background.
  static const Color panel = Color(0xFF0E1626);

  /// Recessed well behind sparklines and key chips.
  static const Color inset = Color(0xFF121C30);

  /// Hairline separators.
  static const Color border = Color(0xFF24304A);

  /// Primary label text.
  static const Color text = Color(0xFFD8E2F0);

  /// Secondary text; also the arena grid/border hue (rgb 138,160,192).
  static const Color textDim = Color(0xFF8AA0C0);

  /// Tertiary text — captions and notes.
  static const Color textFaint = Color(0xFF5E7196);

  /// The "this is the thing to watch" colour: pending chips, sparklines.
  static const Color accent = Color(0xFFFFD36B);

  /// Telemetry tones.
  static const Color good = Color(0xFF7BE08A);
  static const Color warn = Color(0xFFFFB454);
  static const Color bad = Color(0xFFFF6688);

  /// Remote/server-authoritative accents.
  static const Color blue = Color(0xFF6DB3FF);
}

/// Player colour from the server-assigned hue byte — `hsl(hue/256*360, 72%,
/// 62%)`, the same formula as `draw.ts`'s `hueColor` and `palette.gd`'s `hue`.
Color hueColor(int hue, {double alpha = 1, double light = 0.62}) {
  final h = (hue / 256.0) * 360.0;
  return HSLColor.fromAHSL(alpha, h % 360.0, 0.72, light).toColor();
}

/// `Palette.a(color, alpha)` from `palette.gd`, spelled as an extension so
/// draw calls stay readable: `Palette.accent.fade(0.75)`.
extension PaletteFade on Color {
  /// This colour at [alpha] (0..1), leaving its RGB untouched.
  Color fade(double alpha) => withValues(alpha: alpha);
}
