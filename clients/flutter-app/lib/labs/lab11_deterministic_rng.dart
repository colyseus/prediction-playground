import 'dart:async';
import 'dart:math' as math;

import '../controls.dart';
import '../hud.dart';
import '../lab.dart';
import '../palette.dart';
import '../sim/sim.dart';
import 'range_lane.dart';

/// Randomness both machines can agree on without sending any of it.
///
/// A shotgun blast has to look the same on your screen and on the server, or
/// the pellets you watched fly are not the ones that were tested for hits.
/// Sending six angles per shot would work and would also be the thing
/// prediction exists to avoid, since the client could not draw the fan until
/// the server answered.
///
/// Instead the fan is derived. Both sides seed the same tiny generator from
/// two integers they already share:
///
/// - the input sequence number, which the engine counts on both ends (the
///   client gets it from `input.send()`, the server from
///   `channel.consumedCount`, and they are the same number for the same
///   input);
/// - a per-room salt, rolled once by the server and synced as state.
///
/// `shotSeed(seq, salt)` feeds [mulberry32], six draws become six pellet
/// angles, and the client draws its fan the frame you click. The server's
/// `spread` broadcast carries its own angles purely so this lab can lay them
/// over yours: when the derivation matches, the two fans coincide and the
/// divergence readout stays at zero.
///
/// The toggle swaps the seeded stream for an unseeded [math.Random]. Nothing
/// else changes, and the fans immediately stop agreeing. That is why a
/// predicted code path may never reach for ambient randomness or a wall
/// clock.
class Lab11DeterministicRng extends Lab {
  @override
  String get id => '11';

  @override
  String get title => 'Deterministic RNG';

  @override
  String get blurb => 'Same seed both sides, nothing on the wire.';

  /// How far the pellet rays are drawn, in world units.
  static const _fanLength = 40.0;

  static const _maxFans = 4;
  static const _fadeMs = 2400.0;

  RangeLane? lane;
  StreamSubscription<dynamic>? _spreadSub;

  final List<_Fan> _fans = [];
  final math.Random _loose = math.Random();

  /// Swaps the seeded stream for one the server cannot reproduce.
  bool cheat = false;

  /// Fans the server has answered.
  int answered = 0;

  /// Largest per-pellet angle delta on the newest answered fan, in radians.
  double lastDelta = double.nan;

  /// Worst delta over every honestly derived fan since mounting. Stays at
  /// zero for as long as the derivation holds; the smoke test reads it.
  double worstDelta = 0;

  /// Pellets the server scored on the newest answered fan.
  int lastHits = -1;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await RangeLane.mount(ctx.client);
    if (joined == null) return false;

    lane = joined;
    room = joined.room;

    // Every fired input asks for the fan rather than a single ray.
    joined.spread = true;
    joined.onFire = _record;

    _spreadSub = joined.room.onMessage('spread').listen(_onSpread);
    return true;
  }

  /// Derives this client's fan the instant the shot goes out.
  void _record(RangeShot fire) {
    final l = lane;
    if (l == null) return;

    final base = math.atan2(fire.aimY - fire.oy, fire.aimX - fire.ox);
    if (_fans.length == _maxFans) _fans.removeAt(0);
    _fans.add(_Fan(
      seq: fire.seq,
      ox: fire.ox,
      oy: fire.oy,
      client: _clientFan(base, fire.seq, l.salt),
      cheated: cheat,
      t: l.room.clock.now,
    ));
  }

  /// The client's half of the derivation, identical to the server's.
  List<double> _clientFan(double base, int seq, int salt) {
    if (!cheat) return spreadAngles(base, seq, salt);
    // The broken version: a local stream keyed to nothing the server has.
    return [
      for (var i = 0; i < pellets; i++)
        base + (_loose.nextDouble() - 0.5) * spreadRad,
    ];
  }

  /// The server's fan for the same (seq, salt) — for the overlay only.
  void _onSpread(dynamic data) {
    final l = lane;
    if (l == null || data is! Map) return;
    if (data['sid'] != l.room.sessionId) return;

    final seq = (data['seq'] as num?)?.toInt() ?? -1;
    final angles = data['angles'];
    if (angles is! List) return;

    for (final fan in _fans) {
      if (fan.seq != seq || fan.server != null) continue;

      final server = [for (final a in angles) (a as num).toDouble()];
      fan.server = server;
      fan.hits = (data['hits'] as num?)?.toInt() ?? 0;

      var worst = 0.0;
      for (var i = 0; i < math.min(server.length, fan.client.length); i++) {
        worst = math.max(worst, (fan.client[i] - server[i]).abs());
      }
      fan.delta = worst;

      answered++;
      lastDelta = worst;
      lastHits = fan.hits;
      if (!fan.cheated) worstDelta = math.max(worstDelta, worst);
      return;
    }
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    l.readAim(ctx);
    l.drive(now);

    _fans.removeWhere((fan) => now - fan.t > _fadeMs);
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;
    final now = l.room.clock.now;

    l.drawWorld(ctx);

    for (final fan in _fans) {
      final alpha = (1 - (now - fan.t) / _fadeMs).clamp(0.0, 1.0);

      for (final angle in fan.client) {
        draw.line(
          fan.ox,
          fan.oy,
          fan.ox + math.cos(angle) * _fanLength,
          fan.oy + math.sin(angle) * _fanLength,
          Palette.warn.fade(alpha * 0.75),
          width: 1.2,
        );
      }

      final server = fan.server;
      if (server == null) continue;
      // Red when the two derivations parted: at that point the pellets drawn
      // here are not the ones that were tested for hits.
      final tone = fan.delta > 1e-6 ? Palette.bad : Palette.text;
      for (final angle in server) {
        draw.dashedLine(
          fan.ox,
          fan.oy,
          fan.ox + math.cos(angle) * _fanLength,
          fan.oy + math.sin(angle) * _fanLength,
          tone.fade(alpha * 0.9),
        );
      }
    }

    if (_fans.isNotEmpty) {
      final last = _fans.last;
      draw.label(last.ox, last.oy, 'amber = client, white = server',
          Palette.text.fade(0.5),
          size: 9, dy: ctx.view.s(playerHalf) + 8);
    }

    _renderHud(ctx, l);
  }

  void _renderHud(LabContext ctx, RangeLane l) {
    final hud = ctx.hud;

    hud.section('DERIVED SPREAD');
    hud.row('pellets per shot', '$pellets');
    hud.row('room salt', '${l.salt}');
    hud.row('fans answered', '$answered');
    hud.row(
      'angle delta (last shot)',
      lastDelta.isNaN ? '—' : '${lastDelta.toStringAsFixed(5)} rad',
      tone: lastDelta.isNaN
          ? HudTone.plain
          : (lastDelta < 1e-6 ? HudTone.good : HudTone.bad),
    );
    hud.row(
      'angle delta (worst seeded)',
      '${worstDelta.toStringAsFixed(5)} rad',
      tone: worstDelta < 1e-6 ? HudTone.good : HudTone.bad,
    );
    hud.row('pellets hit (last shot)',
        lastHits < 0 ? '—' : '$lastHits / $pellets');

    hud.section('CLOCK');
    hud.row('rtt', '${l.room.clock.smoothedRtt.round()} ms');
    hud.chips(l.pending, label: 'inputs pending');

    hud.note('Amber is the fan this client derived at the click, white is the '
        'one the server derived from the same sequence and salt. Nothing '
        'about the pellets crosses the wire, so the delta is the whole '
        'measurement: zero means both machines rolled the same numbers.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      ToggleSpec('use an unseeded Random()', cheat, (v) => cheat = v),
      ButtonsSpec([
        (label: 'Fire', onPressed: () => lane?.pendingFire = true),
      ]),
      const NoteSpec('Click on the arena or press space to fire a six pellet '
          'fan. With the unseeded generator on, the client rolls pellets the '
          'server has no way to reproduce, the two fans separate, and the '
          'angle delta leaves zero.'),
    ];
  }

  @override
  void onReconnect() {
    // Sequences restart at zero, so the fans still waiting can never be
    // matched to a report.
    _fans.clear();
    lastDelta = double.nan;
    lastHits = -1;
  }

  @override
  void unmount() {
    _spreadSub?.cancel();
    _spreadSub = null;
    lane?.dispose();
    lane = null;
    _fans.clear();
  }
}

/// One blast: the angles this client derived, and the ones the server did.
class _Fan {
  _Fan({
    required this.seq,
    required this.ox,
    required this.oy,
    required this.client,
    required this.cheated,
    required this.t,
  });

  /// The input sequence, half of the seed and the key the report matches on.
  final int seq;

  /// Muzzle pose the fan left from.
  final double ox;
  final double oy;

  /// The angles this client derived at the click.
  final List<double> client;

  /// Whether [client] came from the unseeded generator.
  final bool cheated;

  /// Room-clock ms the shot was fired.
  final double t;

  /// The server's angles, once its report lands.
  List<double>? server;

  /// Largest per-pellet disagreement, in radians.
  double delta = double.nan;

  /// Pellets the server scored.
  int hits = -1;
}
