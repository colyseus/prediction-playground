import 'dart:math' as math;
import 'dart:typed_data';

/// Coefficient of variation of rendered per-frame speed — the "limp" metric
/// lab 04 scores its interpolation modes with. Constant speed scores 0; a mode
/// that stutters between stalls and jumps scores high.
///
/// Port of `godot-gd-app/scripts/smoothness.gd`.
class Smoothness {
  // Sized for wall time, not frames — a fast headless run needs the window to
  // still span several patches.
  static const int cap = 4000;

  /// The window must span several patches before the ratio means anything.
  static const double minWindowMs = 400.0;

  final Float64List _speeds = Float64List(cap);
  final Float64List _dts = Float64List(cap);
  int _head = 0;
  int _count = 0;
  double _lastX = 0.0;
  double _lastY = 0.0;
  bool _seeded = false;

  /// Drop the window — call when the thing being measured changes mode.
  void clear() {
    _head = 0;
    _count = 0;
    _seeded = false;
  }

  /// Feed one rendered pose. The first call only seeds the position: a speed
  /// needs two frames.
  void sample(double x, double y, double dtMs) {
    if (_seeded && dtMs > 0.0) {
      final dx = x - _lastX;
      final dy = y - _lastY;
      _speeds[_head] = math.sqrt(dx * dx + dy * dy) / dtMs * 1000.0;
      _dts[_head] = dtMs;
      _head = (_head + 1) % cap;
      if (_count < cap) _count++;
    }
    _lastX = x;
    _lastY = y;
    _seeded = true;
  }

  /// Why [cv] returned what it did — for a failing assertion to quote.
  String describe() {
    var span = 0.0;
    var mean = 0.0;
    for (var i = 0; i < _count; i++) {
      span += _dts[i];
      mean += _speeds[i];
    }
    if (_count > 0) mean /= _count;
    return 'n=$_count span=${span.toStringAsFixed(0)}ms '
        'mean=${mean.toStringAsFixed(2)}u/s';
  }

  /// Coefficient of variation — NaN until the window is long enough (or the
  /// motion fast enough) to mean anything.
  double cv() {
    if (_count < 20) return double.nan;
    var span = 0.0;
    for (var i = 0; i < _count; i++) {
      span += _dts[i];
    }
    if (span < minWindowMs) return double.nan;
    var mean = 0.0;
    for (var i = 0; i < _count; i++) {
      mean += _speeds[i];
    }
    mean /= _count;
    if (mean < 0.5) return double.nan;
    var variance = 0.0;
    for (var i = 0; i < _count; i++) {
      variance += (_speeds[i] - mean) * (_speeds[i] - mean);
    }
    return math.sqrt(variance / _count) / mean;
  }
}
