import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'draw_kit.dart';

/// Rolling sparkline; auto-scales to the window max unless given a fixed one.
///
/// Port of `godot-gd-app/scripts/spark.gd`; [cap] matches the web build's
/// `SPARK_SAMPLES` in `framework/hud.ts`.
class Spark {
  /// Retained samples.
  static const int cap = 140;

  final Float64List _data = Float64List(cap);
  int _head = 0;
  int _count = 0;

  /// Samples currently retained.
  int get length => _count;

  /// Append a sample, evicting the oldest once full.
  void push(double v) {
    _data[_head] = v;
    _head = (_head + 1) % cap;
    if (_count < cap) _count++;
  }

  /// The newest sample, or 0 when empty.
  double get last => _count == 0 ? 0.0 : _data[(_head - 1 + cap) % cap];

  /// Drop every sample.
  void clear() {
    _head = 0;
    _count = 0;
  }

  /// Plot into a screen-space [box]. [fixedMax] pins the vertical scale;
  /// 0 (the default) auto-scales to the window's own maximum.
  void draw(DrawKit d, Rect box, Color color, {double fixedMax = 0}) {
    if (_count < 2) return;
    var mx = fixedMax;
    if (mx <= 0.0) {
      for (var i = 0; i < _count; i++) {
        mx = math.max(mx, _data[i]);
      }
    }
    if (mx <= 0.0) mx = 1e-6;
    final start = (_head - _count + cap * 2) % cap;
    for (var i = 1; i < _count; i++) {
      final v0 = _data[(start + i - 1) % cap];
      final v1 = _data[(start + i) % cap];
      final x0 = box.left + (i - 1) / (cap - 1) * box.width;
      final x1 = box.left + i / (cap - 1) * box.width;
      final y0 = box.bottom - 2 - math.min(1.0, v0 / mx) * (box.height - 4);
      final y1 = box.bottom - 2 - math.min(1.0, v1 / mx) * (box.height - 4);
      d.lineScreen(Offset(x0, y0), Offset(x1, y1), color);
    }
  }
}
