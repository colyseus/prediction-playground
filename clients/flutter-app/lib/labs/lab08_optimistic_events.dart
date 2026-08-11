import 'dart:async';
import 'dart:ui';

import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../controls.dart';
import '../hud.dart';
import '../lab.dart';
import '../palette.dart';
import '../sim/sim.dart';
import 'move_lane.dart';

/// Predicting something that is not a position.
///
/// Scoring a goal deserves the same instant feedback as movement: the banner
/// goes up the moment your *predicted* square crosses the line, then settles
/// against the server one of two ways.
///
/// - predicted — `ctx.predict` inside the reconciler step. It fires on the
///   live step only, so a rollback replay re-runs the simulation without
///   re-firing the banner.
/// - confirmed — the server's `goal` broadcast lands about a round trip later
///   and confirms the oldest pending prediction. Nothing visible changes,
///   which is the whole idea.
/// - rejected — when the server processes past the predicting input without
///   confirming, the channel auto-rejects and the banner retracts. Raise the
///   deny rate to see that path on demand.
///
/// The gate itself ([stepScoreGate]) is shared deterministic simulation over a
/// reconciled tick field, so *whether you entered* is never a misprediction at
/// any latency. Only the award can be denied.
class Lab08OptimisticEvents extends Lab {
  @override
  String get id => '08';

  @override
  String get title => 'Optimistic Events';

  @override
  String get blurb => 'Instant feedback, then confirmed or retracted.';

  static const _maxRecords = 30;
  static const _bannerMs = 1400.0;

  MoveLane? lane;
  EventChannel? _goals;
  StreamSubscription<dynamic>? _goalSub;

  final List<_Record> _records = [];
  String _bannerText = '';
  Color _bannerColor = Palette.good;
  double _bannerAt = double.negativeInfinity;
  int _denyRate = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    // scoreTicks is reconciled state: the re-entry lockout has to rewind and
    // replay with the position, or a rollback would re-open the gate.
    final joined = await MoveLane.mount(
      ctx.client,
      roomName: 'lab-goal',
      fields: const ['x', 'y', 'vx', 'vy', 'scoreTicks'],
    );
    if (joined == null) return false;

    lane = joined;
    room = joined.room;
    _denyRate = (joined.room.state?['denyRate'] as num?)?.toInt() ?? 0;

    final goals = joined.predict.defineEvent(
      onPredict: (_) {
        _push();
        _banner('GOAL', Palette.good);
      },
      onConfirm: (_) => _settle('confirmed'),
      onReject: (_) {
        _settle('rejected');
        _banner('DENIED', Palette.bad);
      },
    );
    _goals = goals;

    joined.onStep = (stepCtx, body) {
      // Replay-safe by construction: ctx.predict is a no-op off the live step.
      if (stepScoreGate(body)) stepCtx.predict(goals, 'goal:${stepCtx.tick}');
    };

    // The authoritative signal. It rides the same broadcast the server sends
    // when the award survives its deny roll.
    _goalSub = joined.room.onMessage('goal').listen((data) {
      if (data is Map && data['sid'] == joined.room.sessionId) goals.confirm();
    });

    return true;
  }

  double get _now => lane?.room.clock.now ?? 0;

  void _push() {
    if (_records.length == _maxRecords) _records.removeAt(0);
    _records.add(_Record(_now));
  }

  /// Settles the oldest prediction still waiting on the server.
  void _settle(String outcome) {
    for (final record in _records) {
      if (record.outcome != null) continue;
      record.outcome = outcome;
      record.settledAt = _now;
      return;
    }
  }

  void _banner(String text, Color color) {
    _bannerText = text;
    _bannerColor = color;
    _bannerAt = _now;
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;
    l.drive(now);
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;
    final view = ctx.view;

    // The goal zone, open on the arena wall behind it.
    draw.rect(
      Rect.fromLTRB(
        view.sx(goalZoneX),
        view.sy(goalZoneY),
        view.sx(goalZoneX + goalZoneW),
        view.sy(goalZoneY + goalZoneH),
      ),
      Palette.good.fade(0.12),
    );
    draw.line(goalZoneX, goalZoneY, goalZoneX + goalZoneW, goalZoneY,
        Palette.good.fade(0.5));
    draw.line(goalZoneX, goalZoneY + goalZoneH, goalZoneX + goalZoneW,
        goalZoneY + goalZoneH, Palette.good.fade(0.5));
    draw.line(goalZoneX, goalZoneY, goalZoneX, goalZoneY + goalZoneH,
        Palette.good.fade(0.5));
    draw.label(goalZoneX + goalZoneW / 2, goalZoneY, 'GOAL',
        Palette.good.fade(0.7), size: 10, dy: -14);

    for (final other in l.others) {
      draw.square(other.x, other.y, playerHalf,
          hueColor(other.hue, alpha: 0.45));
    }

    // Where the server last said we were, against where we predict we are.
    draw.ghostSquare(
        l.serverX, l.serverY, playerHalf, Palette.text.fade(0.4));
    draw.square(l.predictedX, l.predictedY, playerHalf, hueColor(l.hue));
    draw.squareOutline(l.predictedX, l.predictedY, playerHalf,
        const Color(0xFFFFFFFF), width: 1.5);

    _drawBanner(ctx);
    _renderHud(ctx, l);
  }

  void _drawBanner(LabContext ctx) {
    final age = _now - _bannerAt;
    if (_bannerText.isEmpty || age >= _bannerMs) return;

    // Full opacity for the first third, then out.
    final alpha = (3 * (1 - age / _bannerMs)).clamp(0.0, 1.0);
    final stage = ctx.view.stage;
    ctx.draw.text(stage.left, stage.top + 24, stage.width, _bannerText,
        _bannerColor.fade(alpha),
        size: 42, align: TextAlign.center);
  }

  void _renderHud(LabContext ctx, MoveLane l) {
    final hud = ctx.hud;

    var confirmed = 0, rejected = 0, pending = 0;
    var settleSum = 0.0;
    for (final record in _records) {
      switch (record.outcome) {
        case 'confirmed':
          confirmed++;
          settleSum += record.settledAt - record.predictedAt;
        case 'rejected':
          rejected++;
        default:
          pending++;
      }
    }

    hud.section('EVENTS');
    hud.row('score (authoritative)',
        '${(l.me?['score'] as num?)?.toInt() ?? 0}');
    hud.row('predicted', '${_records.length}');
    hud.row(
      'confirmed',
      confirmed == 0
          ? '0'
          : '$confirmed (${(settleSum / confirmed).round()} ms)',
      tone: confirmed > 0 ? HudTone.good : HudTone.plain,
    );
    hud.row('rejected', '$rejected',
        tone: rejected > 0 ? HudTone.bad : HudTone.plain);
    hud.row('pending', '$pending',
        tone: pending > 0 ? HudTone.warn : HudTone.plain);

    hud.section('RECENT');
    for (var i = 0; i < 5; i++) {
      final index = _records.length - 1 - i;
      if (index < 0) {
        hud.row('event ${i + 1}', '—', color: Palette.textFaint);
        continue;
      }
      final record = _records[index];
      final outcome = record.outcome;
      if (outcome == null) {
        hud.row('event ${i + 1}', 'pending…', tone: HudTone.warn);
      } else {
        hud.row(
          'event ${i + 1}',
          '$outcome +${(record.settledAt - record.predictedAt).round()} ms',
          tone: outcome == 'confirmed' ? HudTone.good : HudTone.bad,
        );
      }
    }

    hud.note('The banner is optimistic; the score is authoritative. The gap '
        'between predicted and confirmed is your round trip. At a high deny '
        'rate the banner goes up, then retracts once the server has answered '
        'past that input without awarding it.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      SliderSpec('server deny rate (room-wide)', 0, 100, _denyRate.toDouble(),
          (v) {
        _denyRate = v.round();
        room?.send('denyRate', {'rate': _denyRate});
      }, divisions: 10, format: (v) => '${v.round()} %'),
      const NoteSpec('Run into the goal zone on the right. Deny rate '
          'manufactures rejections so the retract path is visible without '
          'waiting for a real one.'),
    ];
  }

  @override
  void onReconnect() {
    _goals?.clear();
    _records.clear();
    _bannerText = '';
  }

  @override
  void unmount() {
    _goalSub?.cancel();
    _goalSub = null;
    // The channel belongs to the lane's Predict, which disposes it.
    _goals = null;
    lane?.dispose();
    lane = null;
    _records.clear();
  }
}

/// One optimistic prediction and how it settled.
class _Record {
  _Record(this.predictedAt);

  /// Room-clock ms the banner went up.
  final double predictedAt;

  /// Room-clock ms the server settled it.
  double settledAt = 0;

  /// 'confirmed', 'rejected', or null while pending.
  String? outcome;
}
