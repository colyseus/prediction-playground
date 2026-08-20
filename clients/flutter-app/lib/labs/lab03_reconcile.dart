import 'dart:ui';

import 'package:colyseus/colyseus.dart';

import '../controls.dart';
import '../hud.dart';
import '../lab.dart';
import '../palette.dart';
import '../sim/sim.dart';
import '../spark.dart';
import 'move_lane.dart';
import '../gen/schema.dart';

/// Prediction and server reconciliation, side by side.
///
/// Your square responds the instant you press a key. The dashed ghost is where
/// the server last said you were — a full round trip behind. They stay locked
/// together while the client's simulation agrees with the server's; when they
/// disagree, the correction arrow shows by how much, and the difference is
/// absorbed smoothly instead of snapping.
class Lab03Reconcile extends Lab {
  @override
  String get id => '03';

  @override
  String get title => 'Reconcile';

  @override
  String get blurb =>
      'Predict locally, rewind and replay when the server disagrees.';

  MoveLane<Player>? lane;
  final _driftSpark = Spark();
  double _lastSparkPush = 0;
  bool _showGhost = true;
  bool _showExact = false;

  @override
  Future<bool> mount(LabContext ctx) async {
    lane = await MoveLane.mount(ctx.client, playerType: Player.new);
    room = lane?.room;
    return lane != null;
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    l.drive(now);

    // The drift average moves slowly; sampling it every frame would just be
    // the same number 60 times.
    if (now - _lastSparkPush > 100) {
      _lastSparkPush = now;
      _driftSpark.push(l.drift.ema);
    }
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;

    // Other players: smoothed, since their inputs aren't ours to predict.
    for (final other in l.others) {
      draw.square(other.x, other.y, playerHalf,
          hueColor(other.hue, alpha: 0.45));
    }

    // Where the server last said we were: a round trip in the past.
    if (_showGhost) {
      draw.ghostSquare(l.serverX, l.serverY, playerHalf,
          Palette.textDim.withValues(alpha: 0.55));
    }

    // Where we predict we are: instant.
    final x = _showExact ? (l.reconciler?.state['x'] ?? 0) : l.predictedX;
    final y = _showExact ? (l.reconciler?.state['y'] ?? 0) : l.predictedY;
    draw.square(x, y, playerHalf, hueColor(l.hue));
    draw.squareOutline(x, y, playerHalf, const Color(0xFFFFFFFF), width: 1.5);

    // The correction the server just applied.
    final mag = l.reconciler?.lastCorrectionMag ?? 0;
    if (mag > 0.02) {
      draw.arrow(x, y, x + l.lastCorrectionX * 4, y + l.lastCorrectionY * 4,
          Palette.bad);
    }

    _renderHud(ctx, l);
  }

  void _renderHud(LabContext ctx, MoveLane<Player> l) {
    final hud = ctx.hud;
    final recon = l.reconciler;

    hud.section('PREDICTION');
    hud.chips(l.pending, label: 'pending');
    hud.row('reconciles', '${recon?.reconcileSeq ?? 0}');
    hud.row('corrections', '${l.corrections}');
    hud.row('last correction', (recon?.lastCorrectionMag ?? 0)
        .toStringAsFixed(3));

    final status = classifyDrift(l.drift);
    hud.row('drift', status.name, tone: switch (status) {
      DriftStatus.matched => HudTone.good,
      DriftStatus.jitter => HudTone.warn,
      DriftStatus.diverging => HudTone.bad,
    });
    hud.spark('drift ema', _driftSpark, value: l.drift.ema.toStringAsFixed(4));

    hud.section('CLOCK');
    final clock = l.room.clock;
    hud.row('rtt', '${clock.smoothedRtt.round()} ms');
    hud.row('jitter', '${clock.jitter.round()} ms');

    hud.note(l.pending == 0
        ? 'Hold a movement key: the chips are inputs the server has not '
            'confirmed yet.'
        : 'Each chip is one input applied locally but not yet acknowledged.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    final l = lane;
    if (l == null) return const [];

    return [
      ButtonsSpec([
        (label: 'Impulse', onPressed: () => l.room.send('impulse')),
        (label: 'Teleport', onPressed: () => l.room.send('teleport')),
      ]),
      const NoteSpec('Impulse kicks you server-side — a correction the client '
          'never predicted.'),
      SliderSpec('smoothing', 0, 200, l.smoothMs < 0 ? 50 : l.smoothMs,
          l.setSmoothMs),
      ToggleSpec('server ghost', _showGhost, (v) => _showGhost = v),
      ToggleSpec('exact (no smoothing)', _showExact, (v) => _showExact = v),
      ToggleSpec('auto-snap teleports', l.autoSnap, (v) => l.autoSnap = v),
    ];
  }

  @override
  void onReconnect() {
    _driftSpark.clear();
  }

  @override
  void unmount() {
    lane?.dispose();
    lane = null;
  }
}
