import 'dart:math' as math;

import 'package:colyseus/colyseus.dart';

import '../controls.dart';
import '../hud.dart';
import '../lab.dart';
import '../net/schema_bridge.dart';
import '../palette.dart';
import '../sim/sim.dart';
import 'move_lane.dart';
import '../gen/schema.dart';

/// Hitting something that is moving, and having the server agree.
///
/// The bot patrols, you drive into it, and the shove has to land the same
/// frame on both sides. That only works if both sides answer the same
/// question: *where was the bot at the instant this input was stamped?*
///
/// - The server rewinds the bot to that instant (`allowRewindState` with
///   `mode: "reckon"`, plus the per-input `lastSeenBy` read).
/// - The client asks [Predict.valueAt] for the same instant, [StepContext
///   .reckonTime]. Reading anything else — the newest snapshot, the smoothed
///   render position — tests against a pose the server never looks at.
/// - [StepContext.memoVec] freezes the verdict. The client keeps no history of
///   the bot, so a rollback replay would re-reckon it from a *newer* snapshot
///   and could flip a knife-edge call. The memo computes once, on the live
///   step, and replays that tuple verbatim.
///
/// What to look for: the marker where the hit was tested sits under the drawn
/// bot while the toggle is on. Turn it off and the marker jumps back onto the
/// dashed snapshot ring, roughly half a round trip behind — and grazes start
/// disagreeing with the server, which shows up as corrections that shove you
/// out of a bot you never touched.
///
/// `bumpTicks` is the other half: post-bump immunity is reconciled state, so
/// the countdown rewinds and replays with the position. "Can I be bumped right
/// now?" is therefore never itself a misprediction.
class Lab07Wysiwyg extends Lab {
  @override
  String get id => '07';

  @override
  String get title => 'WYSIWYG Collision';

  @override
  String get blurb => 'Client and server test the hit at the same instant.';

  /// Verdicts kept for the replay check. Comfortably more than the in-flight
  /// window, which is what bounds how many inputs can be replayed.
  static const _verdictLogMax = 128;

  /// A correction this big right after a predicted bump is a flipped verdict,
  /// not knockback-direction epsilon: the 48 u/s shove either happened or it
  /// did not.
  static const _flippedCorrection = 3.0;

  MoveLane<BumpPlayer>? lane;
  final StepBinding _botBinding = StepBinding();

  /// Read the bot at `ctx.reckonTime` (the server's instant) or at the newest
  /// snapshot (the naive read). Live — the step reads it per call.
  bool _atReckonTime = true;

  /// Verdicts frozen on the live step, keyed by input sequence, so a replay of
  /// the same input can be compared against what the live step decided.
  final Map<int, List<double>> _verdicts = {};

  /// Bumps this client predicted.
  int bumps = 0;

  /// Replayed inputs whose verdict was checked against the live one.
  int replayedVerdicts = 0;

  /// Replays that reached a different verdict. Stays at 0 while the memo is
  /// doing its job.
  int verdictFlips = 0;

  /// Corrections large enough, and soon enough after a bump, to be a verdict
  /// the server disagreed with.
  int mispredicts = 0;

  int _lastReconcileSeq = 0;
  double _lastBumpAt = double.negativeInfinity;
  double _flashAt = double.negativeInfinity;

  /// Server instant the newest live verdict was taken at.
  double _reckonTime = 0;

  /// Where that verdict was evaluated — the marker the lab is built around.
  double _evalX = double.nan;
  double _evalY = double.nan;

  /// The decoded `kind`, handed to the reckon step: its scratch carries
  /// scalars only, so a string field does not survive into it.
  String _kind = '';

  @override
  Future<bool> mount(LabContext ctx) async {
    // bumpTicks is reconciled state: the immunity counter has to rewind with
    // the position, or a rollback re-opens the gate and bumps twice.
    final joined = await MoveLane.mount(
      ctx.client,
      playerType: BumpPlayer.new,
      roomName: 'lab-bump',
      fields: const ['x', 'y', 'vx', 'vy', 'bumpTicks'],
    );
    if (joined == null) return false;

    lane = joined;
    room = joined.room;

    // Reckoned rather than interpolated: valueAt can only answer for an
    // arbitrary instant when the field is projected through the shared step.
    joined.predict
        .attachAllReckon('bots', const ['x', 'y'], _reckonBot, smoothMs: 40);
    joined.onStep = _step;
    return true;
  }

  /// The forward pass the SDK runs over a scratch copy of the bot's snapshot.
  void _reckonBot(SchemaView state, double dt, double elapsedMs) {
    stepBot(_botBinding.body(state), dt, elapsedMs, kindOverride: _kind);
  }

  /// The bots collection, re-read every time — the decoder replaces instances.
  MapSchema<Bot>? get bots => room?.stateAs(BumpState.new)?.bots;

  /// The patrolling bot, for readouts.
  Bot? get bot => bots?['bot1'];

  void _step(StepContext ctx, SchemaBody body) {
    // Only a countdown, so running it after the movement step lands on the
    // same number the server gets running it before — and it still precedes
    // the collision test, which is what reads it.
    stepBumpGate(body);

    final when = ctx.reckonTime;
    final verdict = ctx.memoVec('bump', () => _testBots(body, when));
    _trackReplay(ctx, verdict);
    if (verdict.length < 3 || verdict[0] == 0) return;

    body.vx = verdict[1];
    body.vy = verdict[2];
    body.bumpTicks = bumpCooldownTicks; // immunity rides adopt + replay
    if (ctx.isReplay) return; // counters and the flash: live step only

    bumps++;
    _lastBumpAt = lane?.room.clock.now ?? 0;
    _flashAt = _lastBumpAt;
  }

  /// The bump verdict as a memo-able tuple: `[hit 0/1, vx, vy]`.
  ///
  /// Called from inside the memo, so it runs once per input on the live step —
  /// which is also why recording the evaluated position here is safe: a replay
  /// never re-enters it.
  List<double> _testBots(SchemaBody player, double when) {
    final predict = lane?.predict;
    final all = bots;
    if (predict == null || all == null) return const [0, 0, 0];

    _reckonTime = when;
    for (final entry in all.entries) {
      final target = entry.value;

      // The server rewinds THIS input to `when`, so this is the only read that
      // can agree with it. The naive branch takes the newest decoded sample
      // instead: about half a round trip behind what the server tests.
      final bx =
          _atReckonTime ? predict.valueAt(target, 'x', when) : target.x;
      final by =
          _atReckonTime ? predict.valueAt(target, 'y', when) : target.y;
      _evalX = bx;
      _evalY = by;

      final hit = collideBot(player, bx, by);
      if (hit != null) return [1, hit.vx, hit.vy];
    }
    return const [0, 0, 0];
  }

  /// Compares a replayed input's verdict against the one the live step froze.
  ///
  /// This is the memo's whole value made visible: without it a replay would
  /// re-derive the test against fresher bot data, and [verdictFlips] would
  /// start climbing.
  void _trackReplay(StepContext ctx, List<double> verdict) {
    if (!ctx.isReplay) {
      if (_verdicts.length >= _verdictLogMax) {
        _verdicts.remove(_verdicts.keys.first);
      }
      _verdicts[ctx.tick] = verdict;
      return;
    }

    final live = _verdicts[ctx.tick];
    if (live == null) return;
    replayedVerdicts++;
    if (live.length != verdict.length) {
      verdictFlips++;
      return;
    }
    for (var i = 0; i < live.length; i++) {
      if (live[i] == verdict[i]) continue;
      verdictFlips++;
      return;
    }
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    final target = bot;
    if (target != null) _kind = (target['kind'] as String?) ?? '';

    l.drive(now);

    final recon = l.reconciler;
    if (recon == null || recon.reconcileSeq == _lastReconcileSeq) return;
    _lastReconcileSeq = recon.reconcileSeq;
    if (recon.lastCorrectionMag <= _flippedCorrection ||
        now - _lastBumpAt >= 700) {
      return;
    }
    mispredicts++;
    // One per bump: a flipped verdict keeps correcting for several acks while
    // the in-flight window drains, and that is still one disagreement.
    _lastBumpAt = double.negativeInfinity;
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;
    final view = ctx.view;

    for (final other in l.others) {
      draw.square(
          other.x, other.y, playerHalf, hueColor(other.hue, alpha: 0.45));
    }

    final all = bots;
    if (all != null) {
      for (final entry in all.entries) {
        final target = entry.value;

        // Where the bot is drawn: forward-simulated to the present.
        final bx = l.predict.value(target, 'x');
        final by = l.predict.value(target, 'y');
        draw.circle(bx, by, botRadius, Palette.warn.fade(0.28));
        draw.circleOutline(bx, by, botRadius, Palette.warn, width: 2);
        draw.label(bx, by, 'bot (drawn)', Palette.warn,
            size: 10, dy: -view.s(botRadius) - 14);

        // The newest decoded sample, which is already stale by the time it
        // arrives. The gap to the ring above is what reckoning buys back.
        final rawX = target.x;
        final rawY = target.y;
        draw.circleOutline(rawX, rawY, botRadius, Palette.text.fade(0.4),
            width: 1, dashed: true);
        draw.label(rawX, rawY, 'latest snapshot', Palette.text.fade(0.4),
            size: 9, dy: view.s(botRadius) + 4);
      }
    }

    // Where the collision was actually evaluated. On reckonTime it lands under
    // the drawn bot; on the snapshot it lands under the dashed ring, and that
    // is a position the server never tests against.
    if (!_evalX.isNaN) {
      final tone = _atReckonTime ? Palette.accent : Palette.bad;
      draw.marker(_evalX, _evalY, botRadius * 0.6, tone);
      draw.label(_evalX, _evalY, 'hit tested here', tone,
          size: 9, dy: view.s(botRadius) + 16);
    }

    // Where the server last said we were, against where we predict we are.
    draw.ghostSquare(l.serverX, l.serverY, playerHalf, Palette.text.fade(0.5));

    final flash = (l.room.clock.now - _flashAt) < 300;
    draw.square(l.predictedX, l.predictedY, playerHalf,
        flash ? Palette.bad : hueColor(l.hue));
    draw.squareOutline(l.predictedX, l.predictedY, playerHalf,
        Palette.text.fade(flash ? 1 : 0.85),
        width: flash ? 2.5 : 1.5);

    _renderHud(ctx, l);
  }

  void _renderHud(LabContext ctx, MoveLane<BumpPlayer> l) {
    final hud = ctx.hud;
    final clock = l.room.clock;
    final recon = l.reconciler;

    hud.section('COLLISION');
    hud.row('bumps predicted', '$bumps');
    hud.row('bumps (server)', '${(l.me?['bumps'] as num?)?.toInt() ?? 0}');
    hud.row('immunity (ticks)',
        '${(recon?.state['bumpTicks'] ?? 0).round()}');
    final rate = bumps == 0 ? 0.0 : mispredicts / bumps * 100;
    hud.row(
      'mispredicts',
      bumps == 0 ? '$mispredicts' : '$mispredicts (${rate.round()} %)',
      tone: mispredicts == 0 ? HudTone.good : HudTone.warn,
    );

    hud.section('RECKONING');
    // The instant the verdict was taken at, relative to now and to the newest
    // snapshot: the first is how far back the test looked, the second is how
    // far the bot had to be projected forward to answer.
    final offset = math.max(0.0, clock.serverNow - _reckonTime);
    final horizon = _reckonTime - clock.lastServerTime;
    hud.row('reckon offset (now - eval)', '${offset.round()} ms');
    hud.row('projected past snapshot', '${horizon.round()} ms');
    hud.row('eval vs snapshot', '${_evalGap().toStringAsFixed(1)} u');
    hud.row('read', _atReckonTime ? 'ctx.reckonTime' : 'latest snapshot',
        tone: _atReckonTime ? HudTone.good : HudTone.bad);

    hud.section('REPLAY');
    hud.row('verdicts replayed', '$replayedVerdicts');
    hud.row('verdicts that changed', '$verdictFlips',
        tone: verdictFlips == 0 ? HudTone.good : HudTone.bad);

    hud.section('PREDICTION');
    hud.chips(l.pending, label: 'pending');
    final status = classifyDrift(l.drift);
    hud.row('drift', status.name, tone: switch (status) {
      DriftStatus.matched => HudTone.good,
      DriftStatus.jitter => HudTone.warn,
      DriftStatus.diverging => HudTone.bad,
    });
    hud.row('drift ema', l.drift.ema.toStringAsFixed(4));
    hud.row('rtt', '${clock.smoothedRtt.round()} ms');

    hud.note(_atReckonTime
        ? 'The verdict is taken at the instant the server rewinds this input '
            'to, and frozen with memoVec so a rollback replays it instead of '
            're-deriving it. Both counters above stay flat because the two '
            'sides are answering the same question.'
        : 'The verdict now comes from the newest snapshot, which is about half '
            'a round trip behind the pose the server tests. Graze the patrol '
            'path at high latency: bumps the server never awarded, and misses '
            'it did, both arrive as corrections.');
  }

  /// Distance between the evaluated pose and the newest snapshot, in world
  /// units — the visible size of the disagreement the naive read introduces.
  double _evalGap() {
    final target = bot;
    if (target == null || _evalX.isNaN) return 0;
    final dx = _evalX - target.x;
    final dy = _evalY - target.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      ToggleSpec('evaluate at ctx.reckonTime', _atReckonTime, (v) {
        _atReckonTime = v;
        mispredicts = 0;
        bumps = 0;
        verdictFlips = 0;
        replayedVerdicts = 0;
      }),
      const NoteSpec('On, the bot is read at the instant the server rewinds '
          'this input to, so both sides test the same pose. Off, the newest '
          'snapshot is read instead. Raise the latency preset and graze the '
          'patrol path: head-on hits survive a stale read, grazes do not.'),
    ];
  }

  @override
  void onReconnect() {
    // Sequences restart at zero, so the frozen verdicts belong to inputs that
    // no longer exist.
    _verdicts.clear();
    _lastReconcileSeq = 0;
    replayedVerdicts = 0;
    verdictFlips = 0;
  }

  @override
  void unmount() {
    lane?.dispose();
    lane = null;
    _verdicts.clear();
  }
}
