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

/// The three clocks a networked client has to keep straight.
///
/// `now` is local and means nothing to the server. `serverNow` is the
/// estimated server clock, which is what deadlines and lag compensation are
/// expressed in. `renderNow` is the same estimate on a slew-limited timeline,
/// so a corrected estimate doesn't make everything on screen jump.
///
/// All of it is derived from the input round trip — which is why the lab keeps
/// sending inputs even though it predicts nothing.
class Lab02Clocks extends Lab {
  @override
  String get id => '02';

  @override
  String get title => 'Clocks';

  @override
  String get blurb =>
      'Local time, estimated server time, and the render timeline.';

  InputHandle? _input;
  final _pacer = FixedStepPacer(1000 / tickHz);
  final _rttSpark = Spark();
  final _jitterSpark = Spark();
  double _lastSparkPush = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await ctx.client.joinOrCreate('lab-move');
    room = joined;
    _input = joined.input();
    NetDelay.register(joined);
    return _input != null;
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final input = _input;
    if (input == null) return;

    // The clock is fed by the timing prefix on input acknowledgements, so a
    // client that stops sending stops learning what time it is.
    final steps = _pacer.steps(now);
    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = Kb.moveX();
      input.data['moveY'] = Kb.moveY();
      input.send();
    }

    if (now - _lastSparkPush > 100) {
      _lastSparkPush = now;
      final clock = room!.clock;
      _rttSpark.push(clock.smoothedRtt);
      _jitterSpark.push(clock.jitter);
    }
  }

  @override
  void render(LabContext ctx) {
    final joined = room;
    if (joined == null) return;

    final clock = joined.clock;
    final draw = ctx.draw;

    // Players, drawn raw — this lab is about the numbers.
    final players = joined.state?.getMap('players');
    if (players != null) {
      for (final entry in players.entries) {
        final instance = entry.value;
        if (instance is! SchemaInstance) continue;
        draw.square(
          instance['x'] as double,
          instance['y'] as double,
          playerHalf,
          hueColor((instance['hue'] as num?)?.toInt() ?? 0,
              alpha: entry.key == joined.sessionId ? 1 : 0.4),
        );
      }
    }

    final hud = ctx.hud;

    hud.section('CLOCKS');
    hud.row('now (local)', '${clock.now.round()} ms');
    hud.row('serverNow', '${clock.serverNow.round()} ms');
    hud.row('renderNow', '${clock.renderNow.round()} ms');
    hud.row('offset', '${clock.offset.round()} ms');
    hud.row('last snapshot', '${clock.lastServerTime.round()} ms');

    hud.section('ROUND TRIP');
    hud.row('rtt', '${clock.rtt.round()} ms');
    hud.row('smoothed', '${clock.smoothedRtt.round()} ms');
    hud.spark('rtt', _rttSpark);
    hud.row('jitter', '${clock.jitter.round()} ms',
        tone: clock.jitter > 30 ? HudTone.warn : HudTone.good);
    hud.spark('jitter', _jitterSpark);
    hud.row('patch interval', '${clock.patchInterval.round()} ms');
    hud.row('injected', NetDelay.current.label);

    hud.note('serverNow is the estimate; renderNow is the same estimate '
        'slew-limited, so a correction never makes the scene jump.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) => const [
        NoteSpec('Change the network preset and watch rtt and jitter follow. '
            'renderNow keeps advancing smoothly through the change.'),
      ];

  @override
  void unmount() {
    NetDelay.unregister(room!);
  }
}
