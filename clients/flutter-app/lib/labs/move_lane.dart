import 'package:colyseus/colyseus.dart';

import '../kb.dart';
import '../net/net_delay.dart';
import '../net/schema_bridge.dart';
import '../sim/sim.dart';
import '../trail.dart';

/// Every MoveLane room shares one shape: a `players` map of that lab's
/// player schema. The root state classes differ per room, so this façade
/// names just the part the lane needs, typed by [P].
final class PlayersState<P extends SchemaRef> extends SchemaRef {
  final P Function(int) _player;

  PlayersState(super.handle, this._player);

  MapSchema<P> get players => mapOf('players', _player);
}

/// Extra work inside the reconciler step, after the shared movement step.
///
/// Runs on the live input and again on every rollback replay, so it must be
/// deterministic. Guard one-shot effects on `ctx.isReplay`, or predict them
/// through `ctx.predict`, which is replay-safe by construction.
typedef LaneStep = void Function(StepContext ctx, SchemaBody body);

/// Fills the input fields this room declares beyond movement — aim, fire.
typedef LaneInputFill = void Function(SchemaView data);

/// The predicted-movement stack, in one reusable piece.
///
/// Labs 03, 08 and 09 all need the same thing: join, smooth the other players,
/// predict and reconcile your own. Only what they draw, and what else rides
/// the same step, differs — so the rooms that share the `players` map and the
/// movement input reuse this by naming their own room and fields.
///
/// The whole point is visible in three positions:
/// - [predictedX]/[predictedY] — what you should draw. Responds instantly.
/// - [serverX]/[serverY] — the last decoded truth. A round trip behind.
/// - other players — smoothed, since their inputs aren't yours to predict.
class MoveLane<P extends SchemaRef> {
  final ColyseusRoom room;

  /// Wraps a decoded player handle in this room's generated player class.
  final P Function(int) playerType;

  /// Fields the reconciler mirrors and replays.
  final List<String> fields;

  /// Extra simulation folded into the step — the score gate, in lab 08.
  ///
  /// Read at call time, so it can be set after [mount] without rebuilding.
  LaneStep? onStep;

  /// Fills the non-movement input fields before each send.
  LaneInputFill? fillInput;

  /// Runs once per input step, right after the send.
  ///
  /// The input has already been applied to the predicted mirror by then, so
  /// this is where to read [Reconciler.state] for something that starts at the
  /// post-step pose — a projectile leaving the muzzle, in lab 09.
  void Function()? afterSend;

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

  MoveLane(this.room,
      {required this.playerType, this.fields = const ['x', 'y', 'vx', 'vy']});

  /// Joins [roomName] and wires prediction. Returns null if the player never
  /// decoded.
  ///
  /// [playerType] is the room's generated player class — it types [me] and
  /// [others]. [fields] are the ones the reconciler mirrors; a room that
  /// carries extra reconciled state (lab 08's `scoreTicks`) names it here so
  /// rollback replay covers it too.
  static Future<MoveLane<P>?> mount<P extends SchemaRef>(
    ColyseusClient client, {
    required P Function(int) playerType,
    String roomName = 'lab-move',
    List<String> fields = const ['x', 'y', 'vx', 'vy'],
  }) async {
    final room = await client.joinOrCreate(roomName);
    final lane = MoveLane<P>(room, playerType: playerType, fields: fields);

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
    predict = Predict.get(room);

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

  /// The root state, narrowed to the players map every lane room carries.
  PlayersState<P>? get state =>
      room.stateAs((handle) => PlayersState<P>(handle, playerType));

  /// The authoritative entity for this client, re-read every time.
  ///
  /// Re-reading is cheap: the room's schema cache hands back the same wrapper
  /// while the underlying instance is alive, and drops it on reconnect when
  /// the decoder replaces instances.
  P? get me => state?.players[room.sessionId];

  Future<bool> _rebuildReconciler() async {
    final truth = await _waitForMe();
    if (truth == null) return false;

    _recon?.dispose();
    _recon = predict.reconciler(
      truth,
      input: input,
      fields: fields,
      smoothing: smoothing,
      step: (ctx, state, cmd) {
        // The server's own movement rules, run over the predicted mirror.
        final body = _binding.body(state);
        stepEntity(body, _binding.input(cmd), ctx.dt);
        onStep?.call(ctx, body);
      },
    );
    lastReconcileSeq = _recon!.reconcileSeq;
    return true;
  }

  Future<P?> _waitForMe() async {
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
      fillInput?.call(input.data);
      input.send();
      afterSend?.call();
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
      serverTrail.add(truth.view['x'], truth.view['y']);
    }
  }

  /// Where to draw this client's own entity.
  double get predictedX => _recon?.value('x') ?? 0;
  double get predictedY => _recon?.value('y') ?? 0;

  /// The last position the server confirmed — a round trip in the past.
  double get serverX => me?.view['x'] ?? 0;
  double get serverY => me?.view['y'] ?? 0;

  /// Inputs sent but not yet acknowledged.
  int get pending => _recon?.pendingCount ?? 0;

  /// How far the prediction is drifting from the server.
  Drift get drift => _recon?.drift ?? const Drift(0, 0);

  /// Every other player, smoothed.
  Iterable<({P instance, double x, double y, int hue})> get others sync* {
    final players = state?.players;
    if (players == null) return;

    for (final entry in players.entries) {
      if (entry.key == room.sessionId) continue;
      final instance = entry.value;
      yield (
        instance: instance,
        x: predict.value(instance, 'x'),
        y: predict.value(instance, 'y'),
        hue: instance.view['hue'].toInt(),
      );
    }
  }

  /// This client's colour.
  int get hue => me?.view['hue'].toInt() ?? 200;

  void dispose() {
    _recon?.dispose();
    _recon = null;
    predict.dispose();
    NetDelay.unregister(room);
  }
}
