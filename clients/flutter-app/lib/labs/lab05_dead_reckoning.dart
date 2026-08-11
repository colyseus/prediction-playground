import 'dart:math' as math;

import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../controls.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../net/schema_bridge.dart';
import '../pacer.dart';
import '../palette.dart';
import '../sim/sim.dart';

/// Drawing the present instead of the past.
///
/// Interpolation renders between two samples that already arrived, so it is
/// always a delay behind. Dead reckoning takes the newest snapshot and runs it
/// forward with the same step function the server runs — [stepBot] out of
/// `lib/sim`, the very code the server's TypeScript is a twin of. The distance
/// between the two ghosts is the delay that buys back.
///
/// The dashed line from the white dot is the reckon horizon: it grows between
/// patches and collapses when one lands, so its length is the snapshot age.
///
/// What to look for per pattern:
/// - patrol and circle are entirely in the shared step, so the reckoned bot
///   sits on the truth and corrections stay at wire precision.
/// - teleport rides a synced schedule (`lastTeleport`), so even the warp is
///   predicted; the snap threshold decides whether the residual pops or glides.
/// - wander re-rolls its heading from a seed only the server has. Reckoning
///   runs straight through every turn and gets corrected. That error is the
///   point, not a defect.
class Lab05DeadReckoning extends Lab {
  @override
  String get id => '05';

  @override
  String get title => 'Dead Reckoning';

  @override
  String get blurb => 'Forward-simulate the last snapshot with the shared step.';

  static const _patterns = ['patrol', 'circle', 'wander', 'teleport'];
  static const _maxDots = 40;

  /// An x jump this large in one frame is a warp, not motion.
  static const _warpDistance = 15.0;

  Predict? _lerp;
  Predict? _reckon;
  InputHandle? _input;
  final _pacer = FixedStepPacer(1000 / tickHz);
  final _binding = StepBinding();

  final List<({double x, double y, double t})> _dots = [];

  String _pattern = 'patrol';
  double _smoothing = 25;
  double _snap = 8;

  /// The decoded `kind`, handed to the step: the reckon scratch carries
  /// numbers only, so a string field does not survive into it.
  String _kind = '';

  double _lastRawX = double.nan;
  double _lastRawY = double.nan;
  double _lastReckonX = double.nan;
  double _warpFlashAt = double.negativeInfinity;
  int _warps = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await ctx.client.joinOrCreate('lab-bots');
    room = joined;
    NetDelay.register(joined);

    _input = joined.input();
    if (_input == null) return false;
    if (await _waitForBot() == null) return false;

    // The delayed baseline to measure the reckoned one against.
    _lerp = Predict.of(joined)
      ..attachAll('bots', config: {
        'x': const FieldOptions(mode: PredictMode.lerp, delay: remoteInterpMs),
        'y': const FieldOptions(mode: PredictMode.lerp, delay: remoteInterpMs),
      });

    _attachReckon();
    _send();
    return true;
  }

  /// The bot, re-read every frame — the decoder can replace instances.
  SchemaInstance? get bot =>
      room?.state?.getMap('bots')?['bot1'] as SchemaInstance?;

  Future<SchemaInstance?> _waitForBot() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final found = bot;
      if (found != null) return found;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return null;
  }

  void _attachReckon() {
    final joined = room;
    if (joined == null) return;

    _reckon?.dispose();
    _reckon = Predict.of(joined)
      ..attachAllReckon('bots', const ['x', 'y'], _step,
          smoothing: _smoothing, snap: _snap);
  }

  /// The forward pass, called by the SDK with a scratch copy of the snapshot.
  ///
  /// [elapsedMs] is absolute server time at the end of the sub-step, which is
  /// what makes the circle's closed form and the teleport schedule evaluable
  /// at any instant rather than only on tick boundaries.
  void _step(SchemaView state, double dt, double elapsedMs) {
    stepBot(_binding.body(state), dt, elapsedMs, kindOverride: _kind);
  }

  void _send() => room?.send('pattern', {'kind': _pattern});

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final joined = room;
    final input = _input;
    final lerp = _lerp;
    final reckon = _reckon;
    if (joined == null || input == null || lerp == null || reckon == null) {
      return;
    }

    // No reconciler here, so the sends are paced on a timer; they are also
    // what keeps the clock estimate fed.
    final steps = _pacer.steps(now);
    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = Kb.moveX();
      input.data['moveY'] = Kb.moveY();
      input.send();
    }

    lerp.tick(now);
    reckon.tick(now);

    final target = bot;
    if (target == null) return;
    _kind = (target['kind'] as String?) ?? '';

    final rawX = (target['x'] as num).toDouble();
    final rawY = (target['y'] as num).toDouble();
    if (rawX != _lastRawX || rawY != _lastRawY) {
      _lastRawX = rawX;
      _lastRawY = rawY;
      if (_dots.length == _maxDots) _dots.removeAt(0);
      _dots.add((x: rawX, y: rawY, t: now));
    }

    final reckonX = reckon.value(target, 'x');
    if (!_lastReckonX.isNaN && (reckonX - _lastReckonX).abs() > _warpDistance) {
      _warps++;
      _warpFlashAt = now;
    }
    _lastReckonX = reckonX;
  }

  @override
  void render(LabContext ctx) {
    final joined = room;
    final lerp = _lerp;
    final reckon = _reckon;
    if (joined == null || lerp == null || reckon == null) return;

    final draw = ctx.draw;
    final now = joined.clock.now;

    final players = joined.state?.getMap('players');
    if (players != null) {
      for (final entry in players.entries) {
        final instance = entry.value;
        if (instance is! SchemaInstance) continue;
        draw.square(
          (instance['x'] as num).toDouble(),
          (instance['y'] as num).toDouble(),
          playerHalf,
          hueColor((instance['hue'] as num?)?.toInt() ?? 0,
              alpha: entry.key == joined.sessionId ? 0.9 : 0.4),
        );
      }
    }

    // The snapshots the forward pass starts from, fading over 1.5 s.
    for (final dot in _dots) {
      final alpha = 1 - (now - dot.t) / 1500;
      if (alpha <= 0) continue;
      draw.circle(dot.x, dot.y, 0.4, Palette.text.fade(alpha * 0.5));
    }

    final target = bot;
    if (target == null) return;

    final rawX = (target['x'] as num).toDouble();
    final rawY = (target['y'] as num).toDouble();
    final lerpX = lerp.value(target, 'x');
    final lerpY = lerp.value(target, 'y');
    final reckonX = reckon.value(target, 'x');
    final reckonY = reckon.value(target, 'y');

    // The horizon: newest snapshot to the forward-simulated present.
    draw.dashedLine(rawX, rawY, reckonX, reckonY, Palette.warn.fade(0.8),
        width: 1.2);
    draw.circle(rawX, rawY, 0.7, Palette.text.fade(0.9));

    draw.circleOutline(lerpX, lerpY, botRadius, Palette.blue, width: 2);
    draw.label(lerpX, lerpY, 'lerp (past)', Palette.blue,
        size: 10, dy: ctx.view.s(botRadius) + 4);

    draw.circle(reckonX, reckonY, botRadius, Palette.warn.fade(0.25));
    draw.circleOutline(reckonX, reckonY, botRadius, Palette.warn, width: 2);
    draw.label(reckonX, reckonY, 'reckon (present)', Palette.warn,
        size: 10, dy: -ctx.view.s(botRadius) - 14);

    if (now - _warpFlashAt < 500) {
      draw.label(reckonX, reckonY, 'WARP', Palette.bad,
          size: 13, dy: -ctx.view.s(botRadius) - 30);
    }

    _renderHud(ctx, lerpX, lerpY, reckonX, reckonY);
  }

  void _renderHud(
    LabContext ctx,
    double lerpX,
    double lerpY,
    double reckonX,
    double reckonY,
  ) {
    final hud = ctx.hud;
    final clock = room!.clock;
    final age = math.max(0.0, clock.serverNow - clock.lastServerTime);
    final gap = math.sqrt((reckonX - lerpX) * (reckonX - lerpX) +
        (reckonY - lerpY) * (reckonY - lerpY));

    hud.section('RECKONING');
    hud.row('horizon (snapshot age)', '${age.round()} ms');
    hud.row('reckon vs lerp gap', '${gap.toStringAsFixed(1)} u');
    hud.row('warps seen', '$_warps');
    hud.row('pattern', _pattern);
    hud.row('injected', NetDelay.current.label);

    hud.section('CLOCK');
    hud.row('rtt', '${clock.smoothedRtt.round()} ms');
    hud.row('patch interval', '${clock.patchInterval.round()} ms');

    hud.note(switch (_pattern) {
      'wander' => 'wander re-rolls its heading from a seed only the server '
          'has. The forward pass runs straight through every turn and is '
          'corrected on the next patch, which is why the gap keeps reopening.',
      'teleport' => 'The warp schedule is synced state, so the forward pass '
          'predicts the discontinuity too. Raise the snap threshold past the '
          'warp distance and the correction glides across the arena instead '
          'of cutting.',
      _ => 'This pattern lives entirely in the shared step, so the reckoned '
          'ring sits on the truth and the horizon line is the only thing that '
          'moves between patches.',
    });
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      RadioSpec<String>(
        'bot pattern (room-wide)',
        [for (final kind in _patterns) (value: kind, label: kind)],
        _pattern,
        (kind) {
          _pattern = kind;
          _send();
          _warps = 0;
          _dots.clear();
        },
      ),
      SliderSpec('rebase smoothing', 0, 50, _smoothing, (v) {
        if (v == _smoothing) return;
        _smoothing = v;
        _attachReckon();
      }, divisions: 10, format: (v) => '${v.round()} /s'),
      SliderSpec('snap threshold', 2, 62, _snap, (v) {
        if (v == _snap) return;
        _snap = v;
        _attachReckon();
      }, divisions: 10, format: (v) => '${v.round()} u'),
      const NoteSpec('Smoothing is how fast a snapshot rebase glides out. '
          'Anything past the snap threshold cuts instead, because smoothing '
          'across a teleport draws the bot crossing ground it never covered.'),
    ];
  }

  @override
  void onReconnect() {
    _pacer.reset();
    _dots.clear();
    _lastRawX = double.nan;
    _lastRawY = double.nan;
    _lastReckonX = double.nan;
  }

  @override
  void unmount() {
    _reckon?.dispose();
    _reckon = null;
    _lerp?.dispose();
    _lerp = null;
    _dots.clear();
    NetDelay.unregister(room!);
  }
}
