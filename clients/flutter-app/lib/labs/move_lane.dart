import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../kb.dart';
import '../net/net_delay.dart';
import '../net/schema_bridge.dart';
import '../sim/sim.dart';
import '../trail.dart';

/// The predicted-movement stack against `lab-move`, in one reusable piece.
///
/// Labs 00 and 03 both need the same thing: join, smooth the other players,
/// predict and reconcile your own. Only what they draw differs.
///
/// The whole point is visible in three positions:
/// - [predictedX]/[predictedY] — what you should draw. Responds instantly.
/// - [serverX]/[serverY] — the last decoded truth. A round trip behind.
/// - other players — smoothed, since their inputs aren't yours to predict.
class MoveLane {
  final ColyseusRoom room;

  late final Predict predict;
  late final InputHandle input;
  Reconciler? _recon;

  final _binding = StepBinding();

  /// Trail of the predicted position, for showing the path taken.
  final Trail predictedTrail = Trail();

  /// Trail of the raw server position, to compare against.
  final Trail serverTrail = Trail();

  /// Correction smoothing, in 1/s. Rebuilt when changed.
  double smoothing = -1;

  /// Whether a correction bigger than a teleport should snap instead of decay.
  bool autoSnap = true;

  /// Reconciles seen, so the UI can notice new ones.
  int lastReconcileSeq = 0;

  /// Corrections larger than the noise floor since mounting.
  int corrections = 0;

  /// The most recent correction, for drawing an arrow.
  double lastCorrectionX = 0;
  double lastCorrectionY = 0;

  MoveLane(this.room);

  /// Joins and wires prediction. Returns false if the player never decoded.
  static Future<MoveLane?> mount(ColyseusClient client) async {
    final room = await client.joinOrCreate('lab-move');
    final lane = MoveLane(room);

    if (!await lane._bind()) {
      await room.leave();
      room.dispose();
      return null;
    }

    NetDelay.register(room);
    room.onReconnect.listen((_) => lane._onReconnect());
    return lane;
  }

  Future<bool> _bind() async {
    predict = Predict.of(room);

    // Everyone else is smoothed; this client's own entity is left out because
    // the reconciler predicts it instead.
    predict.attachAll(
      'players',
      config: {'x': PredictMode.damped, 'y': PredictMode.damped},
      exceptKey: room.sessionId,
    );

    final handle = room.input();
    if (handle == null) return false;
    input = handle;

    return _rebuildReconciler();
  }

  /// The authoritative entity for this client, re-read every time.
  ///
  /// Never cached: the decoder can replace instances on a resync, and a stale
  /// handle would be a dangling read.
  SchemaInstance? get me =>
      room.state?.getMap('players')?[room.sessionId] as SchemaInstance?;

  Future<bool> _rebuildReconciler() async {
    final truth = await _waitForMe();
    if (truth == null) return false;

    _recon?.dispose();
    _recon = predict.reconciler(
      truth,
      input: input,
      fields: const ['x', 'y', 'vx', 'vy'],
      smoothing: smoothing,
      step: (ctx, state, cmd) {
        // The server's own movement rules, run over the predicted mirror.
        stepEntity(_binding.body(state), _binding.input(cmd), ctx.dt);
      },
    );
    lastReconcileSeq = _recon!.reconcileSeq;
    return true;
  }

  Future<SchemaInstance?> _waitForMe() async {
    // The join resolves on the JOIN opcode, which can land a patch or two
    // before the state carrying this player.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final entry = me;
      if (entry != null) return entry;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return null;
  }

  void _onReconnect() {
    // Sequences restart at zero, so replaying the old ones would corrupt the
    // mirror. Rebuild against the fresh instance instead.
    input.reset();
    predictedTrail.clear();
    serverTrail.clear();
    corrections = 0;
    NetDelay.register(room);
    _rebuildReconciler();
  }

  /// Rebuilds the reconciler with a new [smoothing] value.
  void setSmoothing(double value) {
    if (smoothing == value) return;
    smoothing = value;
    _rebuildReconciler();
  }

  /// The reconciler, once bound.
  Reconciler? get reconciler => _recon;

  /// Whether the lane is ready to drive.
  bool get ready => _recon != null;

  /// Advances one frame: send the inputs that are due and read telemetry.
  ///
  /// [moveX]/[moveY] default to the keyboard.
  void drive(double now, {double? moveX, double? moveY}) {
    final recon = _recon;
    if (recon == null) return;

    final steps = predict.tick(now);
    final mx = moveX ?? Kb.moveX();
    final my = moveY ?? Kb.moveY();

    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = mx;
      input.data['moveY'] = my;
      input.send();
    }

    if (recon.reconcileSeq != lastReconcileSeq) {
      lastReconcileSeq = recon.reconcileSeq;
      lastCorrectionX = recon.lastCorrection('x');
      lastCorrectionY = recon.lastCorrection('y');

      final mag = recon.lastCorrectionMag;
      if (mag > 0.02) corrections++;
      // A teleport isn't a misprediction; smoothing across one would drag the
      // player through the arena.
      if (autoSnap && mag > teleportSnapDist) recon.reset();
    }

    predictedTrail.add(predictedX, predictedY);
    final truth = me;
    if (truth != null) {
      serverTrail.add(truth['x'] as double, truth['y'] as double);
    }
  }

  /// Where to draw this client's own entity.
  double get predictedX => _recon?.value('x') ?? 0;
  double get predictedY => _recon?.value('y') ?? 0;

  /// The last position the server confirmed — a round trip in the past.
  double get serverX => (me?['x'] as double?) ?? 0;
  double get serverY => (me?['y'] as double?) ?? 0;

  /// Inputs sent but not yet acknowledged.
  int get pending => _recon?.pendingCount ?? 0;

  /// How far the prediction is drifting from the server.
  Drift get drift => _recon?.drift ?? const Drift(0, 0);

  /// Every other player, smoothed.
  Iterable<({SchemaInstance instance, double x, double y, int hue})>
      get others sync* {
    final players = room.state?.getMap('players');
    if (players == null) return;

    for (final entry in players.entries) {
      if (entry.key == room.sessionId) continue;
      final instance = entry.value;
      if (instance is! SchemaInstance) continue;
      yield (
        instance: instance,
        x: predict.value(instance, 'x'),
        y: predict.value(instance, 'y'),
        hue: (instance['hue'] as num?)?.toInt() ?? 0,
      );
    }
  }

  /// This client's colour.
  int get hue => (me?['hue'] as num?)?.toInt() ?? 200;

  void dispose() {
    _recon?.dispose();
    _recon = null;
    predict.dispose();
    NetDelay.unregister(room);
  }
}
