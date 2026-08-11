import 'dart:typed_data';

/// A bounded ring of (time, value) samples, walked oldest → newest.
///
/// Port of `godot-gd-app/scripts/series.gd` — the backing store for the labs'
/// timeline strips (sample arrival times vs. interpolated outputs).
class Series {
  Series(this.capacity)
      : _t = Float64List(capacity),
        _v = Float64List(capacity);

  /// Maximum retained samples.
  final int capacity;

  final Float64List _t;
  final Float64List _v;
  int _head = 0;

  /// Samples currently retained.
  int count = 0;

  /// Append a sample, evicting the oldest once full.
  void push(double t, double value) {
    _t[_head] = t;
    _v[_head] = value;
    _head = (_head + 1) % capacity;
    if (count < capacity) count++;
  }

  /// Drop every sample.
  void clear() {
    _head = 0;
    count = 0;
  }

  /// Walk oldest → newest.
  void forEach(void Function(double t, double v) visit) {
    final start = (_head - count + capacity * 2) % capacity;
    for (var i = 0; i < count; i++) {
      final k = (start + i) % capacity;
      visit(_t[k], _v[k]);
    }
  }

  /// The newest sample, or `null` when empty.
  ({double t, double v})? get last {
    if (count == 0) return null;
    final k = (_head - 1 + capacity) % capacity;
    return (t: _t[k], v: _v[k]);
  }
}
