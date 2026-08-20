import 'package:colyseus/colyseus.dart';
import 'package:flutter/services.dart';

import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../net/schema_bridge.dart';
import '../palette.dart';
import '../sim/sim.dart';
import '../gen/schema.dart';

/// One fired input, handed to [RangeLane.onFire] the moment it goes out.
///
/// [seq] is the sequence the server will see as `channel.consumedCount` for
/// the same input, which is what lab 11 seeds its pellet fan from. [ox]/[oy]
/// are the muzzle pose *after* the input was applied, so they match the pose
/// the server steps to before it resolves the shot. [aimX]/[aimY] are read
/// back out of the input payload, so they are the wire values, not the
/// pre-rounding ones.
typedef RangeShot = ({
  int seq,
  double ox,
  double oy,
  double aimX,
  double aimY,
});

/// The shooting-range stack shared by labs 06 and 11.
///
/// Both labs join `lab-range`, reconcile their own movement, smooth the bots
/// on the lerp timeline, aim with the pointer and fire on the input channel.
/// All of that lives here; each lab adds only what it draws on top.
///
/// Deliberately not built on [MoveLane]: the lag-compensation stamp is
/// installed through `room.input(InputOptions(allowRewind: ...))`, the input
/// handle is first-call-wins, and there is no public setter for the gate
/// afterwards. [MoveLane] creates the handle with no options, so a lane that
/// needs the gate has to create it itself. The binding below is otherwise the
/// same shape as `MoveLane._bind`.
class RangeLane {
  final ColyseusRoom<RangeState> room;

  late final Predict predict;
  late final InputHandle input;
  Reconciler? _recon;

  final _binding = StepBinding();

  /// Where the player is aiming, in world units.
  double aimX = arenaW / 2;
  double aimY = 20;

  /// Set to fire on the next input step; cleared once it is sent.
  bool pendingFire = false;

  /// Whether fired inputs ask for the seeded shotgun fan (lab 11) instead of
  /// a single ray (lab 06).
  bool spread = false;

  /// Called once per fired input, right after it reaches the wire.
  void Function(RangeShot shot)? onFire;

  RangeLane._(this.room);

  /// Joins `lab-range` and wires prediction. Returns null if the player or the
  /// bot never decoded.
  static Future<RangeLane?> mount(ColyseusClient client) async {
    final room =
        await client.joinOrCreate('lab-range', stateType: RangeState.new);
    final lane = RangeLane._(room);

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
    // The bots collection has to have decoded before it can be attached to.
    if (await _waitFor(() => bot) == null) return false;

    predict = Predict.get(room);

    // The bots are drawn in the past, and the server rewinds to exactly that
    // instant — display timeline and rewind timeline have to be the same one.
    // Attached before the reconciler exists, because building it binds the
    // input's render delay from this lerp delay.
    const past = FieldOptions(mode: PredictMode.lerp, delay: remoteInterpMs);
    predict.attachAll('bots', config: {'x': past, 'y': past});
    predict.attachAll(
      'players',
      config: {'x': PredictMode.damped, 'y': PredictMode.damped},
      exceptKey: room.sessionId,
    );

    // The stamp that makes lag compensation possible, gated to the inputs
    // that need it — a movement frame carries no shot to rewind for.
    final handle = room.input(
      InputOptions(allowRewind: (data) => data.getBool('fire')),
    );
    if (handle == null) return false;
    input = handle;

    return _rebuildReconciler();
  }

  Future<bool> _rebuildReconciler() async {
    final truth = await _waitFor(() => me);
    if (truth == null) return false;

    _recon?.dispose();
    _recon = predict.reconciler(
      truth,
      input: input,
      fields: const ['x', 'y', 'vx', 'vy'],
      smoothMs: 65,
      step: (ctx, state, cmd) {
        stepEntity(_binding.body(state), _binding.input(cmd), ctx.dt);
      },
    );
    return true;
  }

  /// The typed root state, straight off the typed room.
  RangeState? get state => room.state;

  /// The authoritative entity for this client, re-read every time.
  RangePlayer? get me => state?.players[room.sessionId];

  /// The target. The room only ever creates `bot1`.
  Bot? get bot => state?.bots['bot1'];

  Future<T?> _waitFor<T>(T? Function() read) async {
    // The join resolves on the JOIN opcode, which can land a patch or two
    // before the state carrying the players and bots.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final found = read();
      if (found != null) return found;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return null;
  }

  void _onReconnect() {
    // Sequences restart at zero, so replaying the old ones would corrupt the
    // mirror. Rebuild against the fresh instance instead.
    input.reset();
    pendingFire = false;
    NetDelay.register(room);
    _rebuildReconciler();
  }

  /// The reconciler, once bound.
  Reconciler? get reconciler => _recon;

  /// Whether the lane is ready to drive.
  bool get ready => _recon != null;

  /// Points the aim and latches a fire from the pointer or the space bar.
  ///
  /// Under autopilot there is no cursor, so the aim tracks the bot on the same
  /// lerp timeline the shot will be resolved against — aiming at what this
  /// screen shows is the entire premise of the lag-comp lab.
  void readAim(LabContext ctx) {
    final pointer = Kb.mousePos;
    final overStage = pointer.dx < ctx.view.stage.right;

    if (Kb.autopilot) {
      aimX = botX;
      aimY = botY;
    } else if (overStage) {
      aimX = ctx.view.wx(pointer.dx).clamp(0.0, arenaW);
      aimY = ctx.view.wy(pointer.dy).clamp(0.0, arenaH);
    }

    if ((overStage && Kb.mouseDown) || Kb.pressed(LogicalKeyboardKey.space)) {
      pendingFire = true;
    }
  }

  /// Advances one frame: sends the inputs that are due and reports the shots.
  void drive(double now) {
    final recon = _recon;
    if (recon == null) return;

    final steps = predict.tick(now);
    for (var i = 0; i < steps; i++) {
      final data = input.data;
      data['moveX'] = Kb.moveX();
      data['moveY'] = Kb.moveY();
      data['aimX'] = aimX.clamp(0.0, arenaW);
      data['aimY'] = aimY.clamp(0.0, arenaH);
      data.setBool('fire', pendingFire);
      data.setBool('spread', spread);

      // Read back, don't reuse: aim is float32 on the wire, so this is the
      // value the server will resolve the shot with. Deriving anything from
      // the unrounded one would disagree with it in the last bits.
      final sentX = data['aimX'];
      final sentY = data['aimY'];

      final seq = input.send();
      if (!pendingFire) continue;
      pendingFire = false;
      if (seq <= 0) continue;

      // The input has already been applied to the mirror, so this is the pose
      // the server will step to before it resolves the same input.
      onFire?.call((
        seq: seq,
        ox: recon.state['x'],
        oy: recon.state['y'],
        aimX: sentX,
        aimY: sentY,
      ));
    }
  }

  /// Draws what both labs share: the other players, your predicted square, the
  /// bot on its lerp timeline, and the crosshair.
  void drawWorld(LabContext ctx) {
    final draw = ctx.draw;

    for (final other in others) {
      draw.square(other.x, other.y, playerHalf, hueColor(other.hue, alpha: 0.4));
    }
    draw.square(predictedX, predictedY, playerHalf, hueColor(hue));
    draw.squareOutline(predictedX, predictedY, playerHalf, Palette.text,
        width: 1.5);

    final bx = botX;
    final by = botY;
    draw.circle(bx, by, botRadius, Palette.blue.fade(0.25));
    draw.circleOutline(bx, by, botRadius, Palette.blue, width: 2);
    draw.label(bx, by, 'target (lerp view)', Palette.blue,
        size: 10, dy: -ctx.view.s(botRadius) - 14);

    draw.marker(aimX, aimY, 0.9, Palette.text.fade(0.7));
  }

  /// Where to draw this client's own entity.
  double get predictedX => _recon?.value('x') ?? 0;
  double get predictedY => _recon?.value('y') ?? 0;

  /// The bot as this screen shows it: interpolated, [remoteInterpMs] behind.
  double get botX {
    final target = bot;
    return target == null ? arenaW / 2 : predict.value(target, 'x');
  }

  double get botY {
    final target = bot;
    return target == null ? arenaH / 2 : predict.value(target, 'y');
  }

  /// This client's colour.
  int get hue => (me?['hue'] as num?)?.toInt() ?? 200;

  /// Shots and hits as the server counted them.
  int get shots => (me?['shots'] as num?)?.toInt() ?? 0;
  int get hits => (me?['hits'] as num?)?.toInt() ?? 0;

  /// The room-wide lag-compensation switch.
  bool get lagComp => room.state?['lagComp'] == true;

  /// The per-room spread salt, half of lab 11's seed.
  int get salt => (room.state?['salt'] as num?)?.toInt() ?? 0;

  /// Inputs sent but not yet acknowledged.
  int get pending => _recon?.pendingCount ?? 0;

  /// How far in the past this client tells the server it is rendering.
  double get renderDelay => input.renderDelay;

  /// Every other player, smoothed.
  Iterable<({RangePlayer instance, double x, double y, int hue})>
      get others sync* {
    final players = state?.players;
    if (players == null) return;

    for (final entry in players.entries) {
      if (entry.key == room.sessionId) continue;
      final instance = entry.value;
      yield (
        instance: instance,
        x: predict.value(instance, 'x'),
        y: predict.value(instance, 'y'),
        hue: instance.hue.toInt(),
      );
    }
  }

  void dispose() {
    _recon?.dispose();
    _recon = null;
    predict.dispose();
    NetDelay.unregister(room);
  }
}
