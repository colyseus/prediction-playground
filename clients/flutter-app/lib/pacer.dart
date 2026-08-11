/// Fixed-step accumulator for labs WITHOUT a reconciler: `predict.tick()` only
/// paces once a reconciler adopts the fixed step, but a prediction-free client
/// still has to send one input per server tick.
///
/// Port of `godot-gd-app/scripts/pacer.gd`.
class FixedStepPacer {
  FixedStepPacer(this.stepMs);

  /// Milliseconds per fixed step (`1000 / TICK_HZ` for the playground).
  final double stepMs;

  double _acc = 0.0;
  double _last = 0.0;
  bool _started = false;

  /// Forget the accumulator — after a reconnect, or a deliberate stall.
  void reset() {
    _acc = 0.0;
    _started = false;
  }

  /// Steps due at [nowMs]. The first call only latches the clock (0 steps).
  int steps(double nowMs) {
    if (!_started) {
      _started = true;
      _last = nowMs;
      return 0;
    }
    _acc += nowMs - _last;
    _last = nowMs;
    var n = (_acc / stepMs).floor();
    if (n > 5) {
      // Hitch (a stall, a breakpoint): drop the backlog rather than firing a
      // burst of inputs the server would reject as a flood.
      n = 5;
      _acc = 0.0;
    } else {
      _acc -= n * stepMs;
    }
    return n;
  }
}
