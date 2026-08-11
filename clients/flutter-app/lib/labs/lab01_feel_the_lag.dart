import 'dart:ui';

import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../controls.dart';
import '../hud.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../pacer.dart';
import '../palette.dart';
import '../sim/sim.dart';
import '../spark.dart';
import '../trail.dart';

/// What latency feels like with no prediction at all.
///
/// This lab draws the server's position directly. Every keypress has to reach
/// the server and come back before anything moves, so the square lags your
/// input by a full round trip. Turn the network preset up and it becomes
/// unplayable — which is the entire reason the rest of the labs exist.
class Lab01FeelTheLag extends Lab {
  @override
  String get id => '01';

  @override
  String get title => 'Feel the Lag';

  @override
  String get blurb => 'No prediction: your square is always a round trip old.';

  InputHandle? _input;
  final _pacer = FixedStepPacer(1000 / tickHz);
  final _trail = Trail();
  final _lagSpark = Spark();

  double _lastSparkPush = 0;
  double _pressedAt = 0;
  double _measuredLagMs = 0;
  double _lastX = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await ctx.client.joinOrCreate('lab-move');
    room = joined;
    _input = joined.input();
    NetDelay.register(joined);

    // Localhost is instant, so the lab shows nothing at the default preset.
    if (NetDelay.index == 0) NetDelay.select(2);
    return _input != null;
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final input = _input;
    final joined = room;
    if (input == null || joined == null) return;

    final mx = Kb.moveX();
    final my = Kb.moveY();

    // No reconciler here, so nothing advertises the fixed step — pace the
    // sends on a timer instead.
    final steps = _pacer.steps(now);
    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = mx;
      input.data['moveY'] = my;
      input.send();
    }

    // Time from "key pressed" to "the drawn square actually moved".
    final me = _me(joined);
    final x = (me?['x'] as double?) ?? 0;
    if (mx != 0 || my != 0) {
      if (_pressedAt == 0) _pressedAt = now;
      if (_pressedAt > 0 && (x - _lastX).abs() > 0.01) {
        _measuredLagMs = now - _pressedAt;
        _pressedAt = 0;
      }
    } else {
      _pressedAt = 0;
    }
    _lastX = x;

    if (me != null) _trail.add(x, me['y'] as double);

    if (now - _lastSparkPush > 100) {
      _lastSparkPush = now;
      _lagSpark.push(joined.clock.smoothedRtt);
    }
  }

  SchemaInstance? _me(ColyseusRoom joined) =>
      joined.state?.getMap('players')?[joined.sessionId] as SchemaInstance?;

  @override
  void render(LabContext ctx) {
    final joined = room;
    if (joined == null) return;

    final draw = ctx.draw;
    final players = joined.state?.getMap('players');

    if (players != null) {
      for (final entry in players.entries) {
        final instance = entry.value;
        if (instance is! SchemaInstance) continue;
        final own = entry.key == joined.sessionId;
        final hue = (instance['hue'] as num?)?.toInt() ?? 0;
        draw.square(
          instance['x'] as double,
          instance['y'] as double,
          playerHalf,
          hueColor(hue, alpha: own ? 1 : 0.4),
        );
        if (own) {
          draw.squareOutline(instance['x'] as double, instance['y'] as double,
              playerHalf, const Color(0xFFFFFFFF), width: 1.5);
        }
      }
    }

    _trail.draw(draw, hueColor(200, alpha: 0.25));

    final hud = ctx.hud;
    hud.section('NO PREDICTION');
    hud.row('input → motion', '${_measuredLagMs.round()} ms',
        tone: _measuredLagMs > 120 ? HudTone.bad : HudTone.warn);
    hud.row('rtt', '${joined.clock.smoothedRtt.round()} ms');
    hud.spark('rtt', _lagSpark);
    hud.row('injected', NetDelay.current.label);
    hud.note('Drawing the server position directly. Every keypress waits a '
        'full round trip. Lab 03 predicts instead.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) => const [
        NoteSpec('Raise the network preset and hold a movement key — the '
            'square trails your input by the whole round trip.'),
      ];

  @override
  void unmount() {
    _trail.clear();
    NetDelay.unregister(room!);
  }
}
