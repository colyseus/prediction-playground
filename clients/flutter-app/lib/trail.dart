import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'draw_kit.dart';
import 'palette.dart';

/// A bounded ring of world-space points, drawn as a fading polyline.
///
/// Motion history is what makes a lag/prediction difference legible in a still
/// frame — port of `godot-gd-app/scripts/trail.gd`.
class Trail {
  /// [capacity] samples ≈ 2.5 s of 60 Hz frames at the default 150.
  Trail({this.capacity = 150}) : _pts = Float64List(capacity * 2);

  /// Maximum retained points.
  final int capacity;

  final Float64List _pts;
  int _head = 0;
  int _count = 0;

  /// Points currently retained.
  int get length => _count;

  /// Append a world-space point, evicting the oldest once full.
  void add(double x, double y) {
    _pts[_head * 2] = x;
    _pts[_head * 2 + 1] = y;
    _head = (_head + 1) % capacity;
    if (_count < capacity) _count++;
  }

  /// Forget the history — call on teleport/reconnect so the trail does not
  /// draw a line across the discontinuity.
  void clear() {
    _head = 0;
    _count = 0;
  }

  /// Fading polyline, oldest → newest, ramping to [maxAlpha] at the head.
  /// [maxPoints] draws only the newest N (a shorter tail without reallocating).
  void draw(
    DrawKit d,
    Color color, {
    double width = 1.5,
    double maxAlpha = 0.4,
    int? maxPoints,
  }) {
    final n = maxPoints == null ? _count : math.min(_count, maxPoints);
    if (n < 2) return;
    final base = _head - n + capacity * 2;
    for (var i = 1; i < n; i++) {
      final a = (base + i - 1) % capacity;
      final b = (base + i) % capacity;
      d.line(
        _pts[a * 2],
        _pts[a * 2 + 1],
        _pts[b * 2],
        _pts[b * 2 + 1],
        color.fade(maxAlpha * i / n),
        width: width,
      );
    }
  }
}
