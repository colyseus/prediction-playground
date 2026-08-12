import 'dart:math' as math;

import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../controls.dart';
import '../hud.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../net/schema_bridge.dart';
import '../palette.dart';
import '../sim/sim.dart';
import '../spark.dart';
import '../trail.dart';

/// Which predicted body resolves a contact, in the server's iteration order.
enum _PaddleKind {
  /// This client's paddle — a bound part of the composite world.
  self,

  /// The AI paddle, predicted alongside it.
  bot,

  /// Someone else, frozen at their newest snapshot.
  remote,
}

/// One entry of the players map, as the contact pass sees it.
class _Contact {
  _Contact(this.kind, [this.body]);

  final _PaddleKind kind;

  /// The frozen snapshot for a [_PaddleKind.remote] paddle; null for the two
  /// that resolve against predicted bodies.
  final SimEntity? body;
}

/// Predicting a world instead of an entity.
///
/// A flat reconciler mirrors the fields of one instance, which is enough while
/// the only thing your input moves is you. It stops working the moment you hit
/// something: rolling your paddle back has to roll back the puck it struck, and
/// two independent reconcilers cannot do that — the puck's reconciler has no
/// idea your paddle just moved.
///
/// [Predict.sim] rewinds and replays the whole world together. The parts here
/// are your paddle and the puck; each ack re-seeds both from the same server
/// tick and replays every unacked input over them, so a shot leaves the paddle
/// the frame you swing and is still re-derived from truth twenty times a
/// second.
///
/// The step reproduces `HockeyRoom.step` exactly, because anything else shows
/// up as permanent drift: paddles move first (the AI steers from the *pre-step*
/// puck), then the puck integrates, then contacts resolve in players-map order.
/// The AI paddle is predicted too — its steering is a pure function of synced
/// state, so the client can run the server's own decision. Remote humans are
/// not: their next input is unknowable, so they enter as colliders frozen at
/// their newest snapshot, and a contested touch is the honest misprediction.
///
/// What to look for: the dashed ghost puck is the raw server position. After a
/// clean strike it trails the predicted puck by about a round trip, then
/// converges as acks land. That gap is what the composite sim bought you.
class Lab10CompositeSim extends Lab {
  @override
  String get id => '10';

  @override
  String get title => 'Composite Sim';

  @override
  String get blurb => 'One rollback over a whole world: paddle and puck.';

  /// Drift tolerance for this lab, in world units.
  ///
  /// A flat reconciler replays the server bit-exactly and corrects by zero, so
  /// the 1e-3 default floor is the right cut for one. A composite sim cannot
  /// reach it: it re-adopts an entire world on every ack, off state that came
  /// over the wire as float32, and a remote human is a frozen collider whose
  /// next input is unknowable. Left at the default the panel would read
  /// "diverging" forever and stop carrying information.
  static const _driftTolerance = 0.5;

  Predict? _predict;
  InputHandle? _input;
  Reconciler? _sim;

  /// The AI paddle's predicted body.
  ///
  /// Not a bound part: the store mirrors decoded instances, and this one is
  /// re-seeded from authority in the adopt callback instead — the same rewind
  /// point a bound part gets, without publishing a pose nobody reads.
  final SimEntity _bot = SimEntity();
  final MoveInput _botCmd = MoveInput();
  bool _botEnabled = true;

  /// The players map as the contact pass sees it, snapshotted once per frame.
  final List<_Contact> _contacts = [];

  final _paddleBinding = StepBinding();
  final _puckBinding = StepBinding();

  final Trail _puckTrail = Trail(capacity: 120);
  final Spark _driftSpark = Spark();
  double _lastSparkPush = 0;

  double _smoothing = 15;
  bool _showGhosts = true;

  int _lastReconcileSeq = 0;
  double _lastCorrection = 0;

  /// Contacts this client predicted, live steps only.
  int touches = 0;
  bool _touchedLiveStep = false;

  /// How far ahead of the server the predicted puck has ever been. Peak, not
  /// instantaneous: the lead is largest right after a strike.
  double maxPuckLead = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await ctx.client.joinOrCreate('lab-hockey');
    room = joined;
    NetDelay.register(joined);

    final predict = Predict.of(joined);
    _predict = predict;
    // Remote paddles are smoothed for drawing only. Inside the step they are
    // read raw, because the server resolves contacts against its own current
    // pose, not against a display position.
    predict.attachAll(
      'players',
      config: {'x': PredictMode.damped, 'y': PredictMode.damped},
      exceptKey: joined.sessionId,
    );

    final handle = joined.input();
    if (handle == null) return false;
    _input = handle;

    if (!await _waitForWorld()) return false;
    return _build();
  }

  /// This client's paddle, re-read every time — the decoder can replace
  /// instances on a resync, and a cached handle would be a dangling read.
  SchemaInstance? get me =>
      room?.state?.getMap('players')?[room!.sessionId] as SchemaInstance?;

  /// The puck, likewise re-read.
  SchemaInstance? get puck => room?.state?.getRef('puck');

  /// The server-driven paddle.
  SchemaInstance? get botPaddle =>
      room?.state?.getMap('players')?[botId] as SchemaInstance?;

  /// The composite reconciler, once built.
  Reconciler? get sim => _sim;

  /// Whether the lab is ready to drive.
  bool get ready => _sim != null;

  /// The predicted puck pose, read back the same way any other entity is.
  double get puckX {
    final ball = puck;
    return ball == null ? 0 : _predict?.value(ball, 'x') ?? 0;
  }

  double get puckY {
    final ball = puck;
    return ball == null ? 0 : _predict?.value(ball, 'y') ?? 0;
  }

  /// The predicted paddle pose.
  double get paddleX {
    final self = me;
    return self == null ? 0 : _predict?.value(self, 'x') ?? 0;
  }

  double get paddleY {
    final self = me;
    return self == null ? 0 : _predict?.value(self, 'y') ?? 0;
  }

  /// The join resolves on the JOIN opcode, which can land a patch or two
  /// before the state carrying the world.
  Future<bool> _waitForWorld() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (me != null && puck != null && botPaddle != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return false;
  }

  bool _build() {
    final predict = _predict;
    final input = _input;
    final self = me;
    final ball = puck;
    if (predict == null || input == null || self == null || ball == null) {
      return false;
    }

    _sim?.dispose();
    _adoptBot();
    _sim = predict.sim(
      input: input,
      options: SimOptions(
        parts: [SimPart('paddle', self), SimPart('puck', ball)],
        // Bound parts are pulled from their sources for us; this restores the
        // one part the store does not own, from the same server tick.
        adopt: (_) => _adoptBot(),
        smoothing: _smoothing,
      ),
      step: _step,
    );
    _lastReconcileSeq = _sim!.reconcileSeq;
    return true;
  }

  void _adoptBot() {
    final source = botPaddle;
    if (source == null) return;
    _bot.x = (source['x'] as num).toDouble();
    _bot.y = (source['y'] as num).toDouble();
    _bot.vx = (source['vx'] as num).toDouble();
    _bot.vy = (source['vy'] as num).toDouble();
  }

  /// One input applied to the whole world, in `HockeyRoom.step`'s order.
  void _step(StepContext ctx, SimWorld world, SchemaView cmd) {
    final paddleView = world.part('paddle');
    final puckView = world.part('puck');
    if (paddleView == null || puckView == null) return;

    final paddle = _paddleBinding.body(paddleView);
    final ball = _puckBinding.body(puckView);

    stepEntity(paddle, _paddleBinding.input(cmd), ctx.dt);
    // The AI steers from the puck as it stands BEFORE the puck integrates,
    // exactly as the server does: its paddle loop runs first.
    botInput(_bot, ball, _botEnabled, _botCmd);
    stepEntity(_bot, _botCmd, ctx.dt);
    stepPuck(ball, ctx.dt);

    var touched = false;
    for (final contact in _contacts) {
      final hit = switch (contact.kind) {
        _PaddleKind.self => collidePaddlePuck(paddle, ball),
        _PaddleKind.bot => collidePaddlePuck(_bot, ball),
        _PaddleKind.remote => collidePaddlePuck(contact.body!, ball),
      };
      if (hit && contact.kind == _PaddleKind.self) touched = true;
    }
    if (touched && !ctx.isReplay) _touchedLiveStep = true;
  }

  /// Snapshots the players map for the contact pass.
  ///
  /// Once per frame, not once per step: a replay burst runs the step a dozen
  /// times, and decoded truth does not change inside one frame anyway.
  void _snapshotContacts() {
    final joined = room;
    final players = joined?.state?.getMap('players');
    _contacts.clear();
    if (joined == null || players == null) return;

    for (final entry in players.entries) {
      if (entry.key == joined.sessionId) {
        _contacts.add(_Contact(_PaddleKind.self));
        continue;
      }
      if (entry.key == botId) {
        _contacts.add(_Contact(_PaddleKind.bot));
        continue;
      }
      final other = entry.value;
      if (other is! SchemaInstance) continue;
      _contacts.add(_Contact(
        _PaddleKind.remote,
        SimEntity(
          x: (other['x'] as num).toDouble(),
          y: (other['y'] as num).toDouble(),
          vx: (other['vx'] as num).toDouble(),
          vy: (other['vy'] as num).toDouble(),
        ),
      ));
    }
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final predict = _predict;
    final input = _input;
    final recon = _sim;
    final joined = room;
    if (predict == null || input == null || recon == null || joined == null) {
      return;
    }

    _botEnabled = joined.state?['botEnabled'] == true;
    _snapshotContacts();

    // One input per fixed step. lab-hockey consumes exactly one per tick (it
    // folds in a second only while a backlog drains), and the composite sim
    // interleaves paddle, puck and contacts 1:1 with them — a hand-rolled
    // burst would step the paddle past the puck between two contact passes.
    final steps = predict.tick(now);
    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = Kb.moveX();
      input.data['moveY'] = Kb.moveY();
      input.send();
      if (!_touchedLiveStep) continue;
      _touchedLiveStep = false;
      touches++;
    }

    if (recon.reconcileSeq != _lastReconcileSeq) {
      _lastReconcileSeq = recon.reconcileSeq;
      _lastCorrection = recon.lastCorrectionMag;
    }

    final px = puckX;
    final py = puckY;
    _puckTrail.add(px, py);
    maxPuckLead = math.max(maxPuckLead, _puckLead(px, py));

    if (now - _lastSparkPush <= 100) return;
    _lastSparkPush = now;
    _driftSpark.push(recon.drift.ema);
  }

  /// Distance from the predicted puck to the authoritative one.
  double _puckLead(double px, double py) {
    final ball = puck;
    if (ball == null) return 0;
    final dx = px - (ball['x'] as num).toDouble();
    final dy = py - (ball['y'] as num).toDouble();
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  void render(LabContext ctx) {
    final predict = _predict;
    final joined = room;
    if (predict == null || joined == null) return;

    final draw = ctx.draw;
    final view = ctx.view;
    final players = joined.state?.getMap('players');

    // Remote humans, smoothed. Their poses are display only: the step reads
    // them raw.
    if (players != null) {
      for (final entry in players.entries) {
        if (entry.key == joined.sessionId || entry.key == botId) continue;
        final other = entry.value;
        if (other is! SchemaInstance) continue;
        final hue = (other['hue'] as num?)?.toInt() ?? 0;
        draw.circle(predict.value(other, 'x'), predict.value(other, 'y'),
            paddleRadius, hueColor(hue, alpha: 0.35));
        draw.circleOutline(predict.value(other, 'x'),
            predict.value(other, 'y'), paddleRadius, hueColor(hue, alpha: 0.8));
      }
    }

    // The AI paddle at its PREDICTED pose: it is part of the predicted world,
    // so drawing it smoothed would show it lagging the contacts it is making.
    draw.circle(_bot.x, _bot.y, paddleRadius, Palette.blue.fade(0.35));
    draw.circleOutline(_bot.x, _bot.y, paddleRadius, Palette.blue, width: 1.5);
    draw.label(_bot.x, _bot.y, _botEnabled ? 'AI (predicted)' : 'AI (parked)',
        Palette.blue, size: 10, dy: -view.s(paddleRadius) - 14);

    final ball = puck;
    final self = me;

    // Raw server poses, a round trip behind.
    if (_showGhosts && ball != null) {
      draw.circleOutline(
          (ball['x'] as num).toDouble(),
          (ball['y'] as num).toDouble(),
          puckRadius,
          Palette.text.fade(0.5),
          width: 1.2,
          dashed: true);
      draw.label((ball['x'] as num).toDouble(), (ball['y'] as num).toDouble(),
          'server puck', Palette.text.fade(0.45),
          size: 9, dy: view.s(puckRadius) + 4);
    }
    if (_showGhosts && self != null) {
      draw.circleOutline(
          (self['x'] as num).toDouble(),
          (self['y'] as num).toDouble(),
          paddleRadius,
          Palette.text.fade(0.35),
          width: 1,
          dashed: true);
    }

    // The predicted pair.
    _puckTrail.draw(draw, Palette.accent, width: 1.5, maxAlpha: 0.45);
    final px = puckX;
    final py = puckY;
    draw.circle(px, py, puckRadius, Palette.accent.fade(0.9));
    draw.circleOutline(px, py, puckRadius, Palette.accent, width: 1.5);
    draw.label(px, py, 'puck (predicted)', Palette.accent,
        size: 10, dy: -view.s(puckRadius) - 14);

    final hue = (self?['hue'] as num?)?.toInt() ?? 200;
    draw.circle(paddleX, paddleY, paddleRadius, hueColor(hue, alpha: 0.55));
    draw.circleOutline(paddleX, paddleY, paddleRadius, Palette.text,
        width: 1.5);
    draw.label(paddleX, paddleY, 'you (predicted)', Palette.text,
        size: 10, dy: -view.s(paddleRadius) - 16);

    _renderHud(ctx);
  }

  void _renderHud(LabContext ctx) {
    final hud = ctx.hud;
    final recon = _sim;
    final joined = room;
    if (recon == null || joined == null) return;

    hud.section('COMPOSITE SIM');
    hud.chips(recon.pendingCount, label: 'pending inputs');
    hud.row('reconciles', '${recon.reconcileSeq}');
    hud.row('last correction', _lastCorrection.toStringAsFixed(3));
    hud.row('step', '${recon.stepMs.round()} ms');
    hud.row('touches predicted', '$touches');
    hud.row('puck lead (peak)', '${maxPuckLead.toStringAsFixed(1)} u');

    final drift = recon.drift;
    final status = classifyDrift(drift, tolerance: _driftTolerance);
    hud.row('drift', status.name, tone: switch (status) {
      DriftStatus.matched => HudTone.good,
      DriftStatus.jitter => HudTone.warn,
      DriftStatus.diverging => HudTone.bad,
    });
    hud.spark('drift ema', _driftSpark, value: drift.ema.toStringAsFixed(4));

    hud.section('CLOCK');
    hud.row('rtt', '${joined.clock.smoothedRtt.round()} ms');
    hud.row('jitter', '${joined.clock.jitter.round()} ms');

    hud.note('Drift is judged against a $_driftTolerance u tolerance instead '
        'of the 1e-3 floor a flat reconciler holds to. A composite sim '
        're-adopts the whole world on every ack, off state that crossed the '
        'wire as float32, so its corrections settle in the thousandths rather '
        'than at zero. A second human in the arena pushes it further, because '
        'their paddle enters the step as a collider frozen at its last '
        'snapshot.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      ToggleSpec('AI paddle (room-wide)', _botEnabled, (v) {
        // Optimistic: the flag is server state, and the next patch overwrites
        // this. Waiting for it would step the AI from the old policy for a
        // round trip and mispredict every contact in the window.
        _botEnabled = v;
        room?.send('bot', {'on': v});
      }),
      ButtonsSpec([
        (
          label: 'Reset puck',
          onPressed: () {
            room?.send('resetPuck');
            _puckTrail.clear();
            maxPuckLead = 0;
          }
        ),
      ]),
      SliderSpec('smoothing', 0, 40, _smoothing, (v) {
        if (v == _smoothing) return;
        _smoothing = v;
        _build();
      }, divisions: 8, format: (v) => '${v.round()} /s'),
      ToggleSpec('server ghosts', _showGhosts, (v) => _showGhosts = v),
      const NoteSpec('WASD to skate. The puck answers your input the frame you '
          'touch it, at any latency, because it is predicted through your own '
          'inputs. Turn the AI off and the world is entirely yours; turn it on '
          'and it is still predicted, since its steering is a pure function of '
          'state you already have.'),
    ];
  }

  @override
  void onReconnect() {
    // Sequences restart at zero and the decoder may have replaced every
    // instance, so the world has to be rebound before anything replays.
    _input?.reset();
    final joined = room;
    if (joined != null) NetDelay.register(joined);
    _puckTrail.clear();
    _driftSpark.clear();
    touches = 0;
    maxPuckLead = 0;
    _lastCorrection = 0;
    _build();
  }

  @override
  void unmount() {
    _sim?.dispose();
    _sim = null;
    _predict?.dispose();
    _predict = null;
    _contacts.clear();
    _puckTrail.clear();
    final joined = room;
    if (joined != null) NetDelay.unregister(joined);
  }
}
