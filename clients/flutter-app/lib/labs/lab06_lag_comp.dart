import 'dart:async';
import 'dart:math' as math;

import '../controls.dart';
import '../hud.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../palette.dart';
import '../sim/sim.dart';
import 'range_lane.dart';

/// Shooting at what you see, not at where the target already is.
///
/// Everything you aim at is drawn in the past: the bot rides the lerp
/// timeline, [remoteInterpMs] behind the newest patch, and your click needs
/// another half round trip to reach the server. By the time the shot is
/// resolved the bot has moved on. Without help you would have to lead it.
///
/// Lag compensation moves that burden to the server. It records the bots
/// every tick and, when an input carrying the rewind stamp arrives, reads
/// every target as this client saw it at the instant it fired. Each shot
/// drops three crosshairs:
///
/// - blue — the bot where this screen showed it when you clicked.
/// - green — where the server rewound it to for the hit test. With lag comp
///   on, green lands on blue: your view was reconstructed.
/// - red — where the bot actually was on the server, ahead of your view by
///   about (rtt / 2 + render delay) times its speed.
///
/// What makes it work is the client being honest about its own timeline. The
/// bots are displayed with the same delay the input handle reports as its
/// render delay, so the server rewinds to a frame that was really drawn.
/// Turn the toggle off and the same crosshair aim starts missing by the
/// red-to-blue gap.
class Lab06LagComp extends Lab {
  @override
  String get id => '06';

  @override
  String get title => 'Lag Compensation';

  @override
  String get blurb => 'The server rewinds targets to what you saw.';

  /// Matches `SHOT_RANGE` in RangeRoom, for the client-side hit preview.
  static const _shotRange = 200.0;

  static const _maxShots = 6;
  static const _fadeMs = 1500.0;

  RangeLane? lane;
  StreamSubscription<dynamic>? _shotSub;

  final List<_Shot> _shots = [];

  /// Server verdicts, split by whether lag comp was on when they resolved.
  int shotsOn = 0;
  int hitsOn = 0;
  int shotsOff = 0;
  int hitsOff = 0;

  /// Shot reports received for this client. The smoke test reads it.
  int reports = 0;

  int _predictedHits = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await RangeLane.mount(ctx.client);
    if (joined == null) return false;

    lane = joined;
    room = joined.room;
    joined.onFire = _record;

    _shotSub = joined.room.onMessage('shot').listen(_onShot);

    // Lag compensation has nothing to show on a 1 ms link: all three
    // crosshairs land on top of each other.
    NetDelay.select(2);
    return true;
  }

  /// Records what this screen showed at the moment of the shot.
  void _record(RangeShot fire) {
    final l = lane;
    if (l == null) return;

    var dx = fire.aimX - fire.ox;
    var dy = fire.aimY - fire.oy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return;
    dx /= len;
    dy /= len;

    // The same ray test the server runs, against the pose this screen was
    // showing. It is the client's own verdict, available immediately, and it
    // agrees with the server's whenever the rewind lands where it should.
    final seenX = l.botX;
    final seenY = l.botY;
    final predicted =
        rayCircle(fire.ox, fire.oy, dx, dy, seenX, seenY, botRadius, _shotRange) >=
            0;
    if (predicted) _predictedHits++;

    if (_shots.length == _maxShots) _shots.removeAt(0);
    _shots.add(_Shot(
      ox: fire.ox,
      oy: fire.oy,
      dx: dx,
      dy: dy,
      seenX: seenX,
      seenY: seenY,
      predictedHit: predicted,
      t: l.room.clock.now,
    ));
  }

  /// The server's shot report completes the oldest record still waiting.
  void _onShot(dynamic data) {
    final l = lane;
    if (l == null || data is! Map) return;
    if (data['sid'] != l.room.sessionId) return;

    final hit = data['hit'] == true;
    reports++;
    if (data['lagComp'] == true) {
      shotsOn++;
      if (hit) hitsOn++;
    } else {
      shotsOff++;
      if (hit) hitsOff++;
    }

    for (final shot in _shots) {
      if (shot.answered) continue;
      shot.answered = true;
      shot.hit = hit;
      shot.rewoundX = _read(data['seenX']);
      shot.rewoundY = _read(data['seenY']);
      shot.liveX = _read(data['liveX']);
      shot.liveY = _read(data['liveY']);

      // Project the rewind error onto the direction the bot is travelling.
      final travelX = shot.liveX - shot.seenX;
      final travelY = shot.liveY - shot.seenY;
      final travel = math.sqrt(travelX * travelX + travelY * travelY);
      if (travel > 1e-9) {
        shot.aheadOfDrawn = ((shot.rewoundX - shot.seenX) * travelX +
                (shot.rewoundY - shot.seenY) * travelY) /
            travel;
      }
      return;
    }
  }

  static double _read(Object? value) => (value as num?)?.toDouble() ?? 0;

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    l.readAim(ctx);
    l.drive(now);

    // Expire here rather than in the render, so a headless run keeps the same
    // records a windowed one does.
    _shots.removeWhere((shot) => now - shot.t > _fadeMs);
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;
    final now = l.room.clock.now;

    l.drawWorld(ctx);

    // The aim ray, from your predicted square to the crosshair.
    draw.dashedLine(l.predictedX, l.predictedY, l.aimX, l.aimY,
        Palette.text.fade(0.18));

    for (final shot in _shots) {
      final alpha = (1 - (now - shot.t) / _fadeMs).clamp(0.0, 1.0);
      // Until the report lands the ray wears the client's own verdict, faint;
      // the server's answer replaces it at full strength.
      final verdict = shot.answered
          ? (shot.hit ? Palette.good : Palette.bad).fade(alpha * 0.75)
          : (shot.predictedHit ? Palette.good : Palette.bad).fade(alpha * 0.3);

      draw.line(shot.ox, shot.oy, shot.ox + shot.dx * _shotRange,
          shot.oy + shot.dy * _shotRange, verdict, width: 1.2);
      draw.marker(shot.seenX, shot.seenY, botRadius * 0.7,
          Palette.blue.fade(alpha));
      if (!shot.answered) continue;
      draw.marker(shot.rewoundX, shot.rewoundY, botRadius * 0.85,
          Palette.good.fade(alpha));
      draw.marker(shot.liveX, shot.liveY, botRadius, Palette.bad.fade(alpha));
    }

    _renderHud(ctx, l);
  }

  void _renderHud(LabContext ctx, RangeLane l) {
    final hud = ctx.hud;
    final shots = l.shots;
    final hits = l.hits;

    hud.section('SHOOTING');
    hud.row('shots (server)', '$shots');
    hud.row('hits (server)', '$hits');
    hud.row(
      'hit rate',
      shots == 0 ? '—' : '${(hits * 100 / shots).round()} %',
      tone: shots == 0
          ? HudTone.plain
          : (hits * 10 > shots * 7 ? HudTone.good : HudTone.warn),
    );
    hud.row('predicted hits (client)', '$_predictedHits');
    hud.row('with lag comp on', '$hitsOn / $shotsOn',
        tone: shotsOn > 0 && hitsOn * 10 > shotsOn * 7
            ? HudTone.good
            : HudTone.plain);
    hud.row('with lag comp off', '$hitsOff / $shotsOff',
        tone: shotsOff > 0 && hitsOff * 2 < shotsOff
            ? HudTone.bad
            : HudTone.plain);

    hud.section('TIMELINE');
    hud.row('lag compensation', l.lagComp ? 'on' : 'off',
        tone: l.lagComp ? HudTone.good : HudTone.bad);
    hud.row('render delay', '${l.renderDelay.round()} ms');
    hud.row('rtt', '${l.room.clock.smoothedRtt.round()} ms');
    hud.row('injected', NetDelay.current.label);

    final gap = viewLag;
    hud.row('view lag (red to blue)', gap.isNaN ? '—' : '${gap.toStringAsFixed(1)} u',
        color: gap.isNaN ? Palette.textFaint : Palette.text);
    hud.chips(l.pending, label: 'inputs pending');

    hud.note('Blue is the bot where your screen had it, green is where the '
        'server rewound it to, red is where it was live. The blue to red gap '
        'is your view lag in world units: that is how far you would have to '
        'lead the target with compensation off.');
    hud.note('Green should sit on top of blue. Past about 500 ms of round '
        'trip it starts drifting ahead: the rewind the server would need is '
        'deeper than the room allows (maxRewindMs), so it clamps, and trailing '
        'edge shots read as a hit here and a miss there.');
  }

  /// Answered shots, for diagnostics.
  ///
  /// The lab's claim is that the pose the server rewinds to matches the pose
  /// this screen drew, so both are exposed alongside the two verdicts.
  List<
      ({
        double drewX,
        double drewY,
        double rewoundX,
        double rewoundY,
        bool predictedHit,
        bool serverHit,
        double aheadOfDrawn,
      })> get answeredShots => [
        for (final shot in _shots)
          if (shot.answered)
            (
              drewX: shot.seenX,
              drewY: shot.seenY,
              rewoundX: shot.rewoundX,
              rewoundY: shot.rewoundY,
              predictedHit: shot.predictedHit,
              serverHit: shot.hit,
              aheadOfDrawn: shot.aheadOfDrawn,
            ),
      ];

  /// Distance between the live pose and the seen pose on the newest answered
  /// shot, in world units. NaN until the server has answered one.
  double get viewLag {
    for (var i = _shots.length - 1; i >= 0; i--) {
      final shot = _shots[i];
      if (!shot.answered) continue;
      final dx = shot.liveX - shot.seenX;
      final dy = shot.liveY - shot.seenY;
      return math.sqrt(dx * dx + dy * dy);
    }
    return double.nan;
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    final l = lane;
    return [
      // Read from state rather than a local copy: the switch is room-wide, so
      // a peer flipping it has to move this toggle too.
      ToggleSpec('lag compensation (room-wide)', l?.lagComp ?? true,
          (v) => room?.send('lagcomp', {'on': v})),
      ButtonsSpec([
        (label: 'Fire', onPressed: () => lane?.pendingFire = true),
      ]),
      const NoteSpec('Aim with the pointer and click on the arena, or press '
          'space. WASD moves you. With lag compensation off the server tests '
          'your shot against where the bot is now, so you have to lead it by '
          'the blue to red gap; raise the injected latency to widen it.'),
    ];
  }

  @override
  void onReconnect() {
    _shots.clear();
  }

  @override
  void unmount() {
    _shotSub?.cancel();
    _shotSub = null;
    lane?.dispose();
    lane = null;
    _shots.clear();
  }
}

/// One shot and the three positions that explain it.
class _Shot {
  _Shot({
    required this.ox,
    required this.oy,
    required this.dx,
    required this.dy,
    required this.seenX,
    required this.seenY,
    required this.predictedHit,
    required this.t,
  });

  /// Muzzle pose the shot left from.
  final double ox;
  final double oy;

  /// Unit aim direction.
  final double dx;
  final double dy;

  /// The bot as this screen showed it at the click.
  final double seenX;
  final double seenY;

  /// The client's own ray verdict against [seenX]/[seenY].
  final bool predictedHit;

  /// Room-clock ms the shot was fired.
  final double t;

  /// Whether the server's report has landed.
  bool answered = false;

  /// The server's verdict.
  bool hit = false;

  /// Where the server rewound the bot to.
  double rewoundX = 0;
  double rewoundY = 0;

  /// Where the bot actually was when the input arrived.
  double liveX = 0;
  double liveY = 0;

  /// How far the server's rewound pose sits along the bot's travel relative
  /// to the pose this screen drew. Positive means the server placed it
  /// further ahead than the screen showed.
  double aheadOfDrawn = 0;
}
