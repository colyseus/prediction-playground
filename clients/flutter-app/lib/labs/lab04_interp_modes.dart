import 'dart:ui';

import 'package:colyseus_flutter/colyseus_flutter.dart';

import '../controls.dart';
import '../hud.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../pacer.dart';
import '../palette.dart';
import '../series.dart';
import '../sim/sim.dart';
import '../smoothness.dart';

/// The same bot drawn four ways at once.
///
/// You cannot predict an entity someone else drives; you can only choose how
/// to draw the samples that arrive. Each ring here is the identical decoded
/// bot under a different rule:
///
/// - raw (dashed) — the snapshot verbatim, so it steps at the patch rate.
/// - lerp — drawn `delay` ms in the past, always between two real samples.
/// - damped — chases the newest sample, rounding every corner.
/// - extrapolate — projects the trend forward, overshooting every turn.
///
/// The strip along the bottom is the lesson in one picture: white dots are the
/// samples that arrived, the coloured traces are what each mode rendered. The
/// HUD scores them by the coefficient of variation of rendered speed, where
/// lower is smoother.
class Lab04InterpModes extends Lab {
  @override
  String get id => '04';

  @override
  String get title => 'Interp Modes';

  @override
  String get blurb => 'lerp, damped, extrapolate and raw, side by side.';

  /// The lab re-fits the view to leave the timeline strip its own band.
  @override
  bool get ownArena => true;

  static const _patterns = ['patrol', 'circle', 'wander', 'teleport'];
  static const _stripSpanMs = 2500.0;
  static const _stripHeight = 118.0;

  /// The x range the strip plots. The bot lives in [22, 78]; the headroom is
  /// for extrapolation overshoot.
  static const _plotMin = 12.0;
  static const _plotMax = 88.0;

  final List<_Mode> _modes = [];
  final _samples = Series(400);
  final _pacer = FixedStepPacer(1000 / tickHz);

  InputHandle? _input;
  String _pattern = 'patrol';
  double _lerpDelay = remoteInterpMs;
  double _damping = 12;
  double _maxExtrapolate = 250;

  double _lastRawX = double.nan;
  double _lastRawY = double.nan;
  double _cvRefreshAt = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await ctx.client.joinOrCreate('lab-bots');
    room = joined;
    NetDelay.register(joined);

    _input = joined.input();
    if (_input == null) return false;
    if (await _bot() == null) return false;

    _modes.addAll([
      _Mode('raw', Palette.text, null),
      _Mode('lerp', Palette.blue,
          FieldOptions(mode: PredictMode.lerp, delay: _lerpDelay)),
      _Mode('damped', Palette.good,
          FieldOptions(mode: PredictMode.damped, damping: _damping)),
      _Mode(
          'extrapolate',
          Palette.warn,
          FieldOptions(
              mode: PredictMode.extrapolate, maxExtrapolate: _maxExtrapolate)),
    ]);
    for (final mode in _modes) {
      mode.attach(joined);
    }

    _send();
    return true;
  }

  /// The bot, re-read every frame — the decoder can replace instances.
  SchemaInstance? get bot =>
      room?.state?.getMap('bots')?['bot1'] as SchemaInstance?;

  /// Waits for the bot to decode; the join resolves before the first patch.
  Future<SchemaInstance?> _bot() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final found = bot;
      if (found != null) return found;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return null;
  }

  void _send() => room?.send('pattern', {'kind': _pattern});

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final joined = room;
    final input = _input;
    if (joined == null || input == null) return;

    // Nothing here reconciles, so predict.tick() never advertises a step rate
    // — the sends are paced on a timer, and they are what feeds the clock.
    final steps = _pacer.steps(now);
    for (var i = 0; i < steps; i++) {
      input.data['moveX'] = Kb.moveX();
      input.data['moveY'] = Kb.moveY();
      input.send();
    }

    for (final mode in _modes) {
      mode.predict?.tick(now);
    }

    final target = bot;
    if (target == null) return;

    final clock = joined.clock;
    final rawX = (target['x'] as num).toDouble();
    final rawY = (target['y'] as num).toDouble();

    // A received sample is the decoded value changing, which happens once per
    // patch — the dots on the strip are literally the wire.
    if (rawX != _lastRawX || rawY != _lastRawY) {
      _lastRawX = rawX;
      _lastRawY = rawY;
      _samples.push(clock.lastServerTime, rawX);
    }

    final serverNow = clock.serverNow;
    for (final mode in _modes) {
      final x = mode.read(target, 'x');
      final y = mode.read(target, 'y');
      mode.trace.push(serverNow, x);
      mode.smooth.sample(x, y, dtMs);
    }

    // The CV window is hundreds of samples deep; recomputing it every frame
    // would show the same number 60 times.
    if (now > _cvRefreshAt) {
      _cvRefreshAt = now + 500;
      for (final mode in _modes) {
        mode.cv = mode.smooth.cv();
      }
    }
  }

  @override
  void render(LabContext ctx) {
    final joined = room;
    if (joined == null) return;

    final draw = ctx.draw;
    final stage = ctx.view.stage;

    // Give the strip its own band instead of drawing it over the arena.
    ctx.view.fit(Rect.fromLTWH(
      stage.left,
      stage.top,
      stage.width,
      stage.height - _stripHeight - 12,
    ));
    draw.arena();

    // Players, raw and dim: this lab is about the bot.
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

    final target = bot;
    if (target != null) {
      for (var i = 0; i < _modes.length; i++) {
        final mode = _modes[i];
        if (!mode.visible) continue;
        final x = mode.read(target, 'x');
        final y = mode.read(target, 'y');
        draw.circleOutline(x, y, botRadius, mode.color,
            width: 2, dashed: mode.predict == null);
        // Staggered labels: the four rings sit within a bot radius of each
        // other most of the time, so one baseline is unreadable.
        draw.label(x, y, mode.name, mode.color,
            size: 10, dy: -ctx.view.s(botRadius) - 14 - i * 11);
      }
    }

    _drawStrip(
      ctx,
      Rect.fromLTRB(
        stage.left + 24,
        stage.bottom - _stripHeight,
        stage.right - 16,
        stage.bottom,
      ),
    );

    _renderHud(ctx);
  }

  void _renderHud(LabContext ctx) {
    final hud = ctx.hud;

    hud.section('SMOOTHNESS (SPEED CV)');
    for (final mode in _modes) {
      hud.row(
        mode.name,
        mode.cv.isNaN ? '—' : '${(mode.cv * 100).round()} %',
        color: mode.cv.isNaN ? Palette.textFaint : mode.color,
      );
    }
    hud.row('samples buffered', '${_samples.count}');
    hud.row('injected', NetDelay.current.label);

    final clock = room!.clock;
    hud.section('ARRIVALS');
    hud.row('patch interval', '${clock.patchInterval.round()} ms');
    hud.row('jitter', '${clock.jitter.round()} ms',
        tone: clock.jitter > 30 ? HudTone.warn : HudTone.good);

    hud.note('Lower CV is smoother. raw steps at the patch rate, lerp is '
        'smooth but late, damped rounds corners, extrapolate is present-time '
        'and overshoots reversals. Switch to circle to see that clearly.');
  }

  /// The buffer timeline: samples that arrived against what each mode drew.
  void _drawStrip(LabContext ctx, Rect box) {
    if (box.width < 200) return;

    final draw = ctx.draw;
    final clock = room!.clock;

    draw.rect(box, Palette.panel.fade(0.92));
    draw.rect(Rect.fromLTWH(box.left, box.top, box.width, 1), Palette.border);

    const pad = 10.0;
    final serverNow = clock.serverNow;
    final tMin = serverNow - _stripSpanMs;
    final tMax = serverNow + 150;

    double tx(double t) =>
        box.left + pad + (t - tMin) / (tMax - tMin) * (box.width - pad * 2);
    double ty(double v) =>
        box.bottom - pad -
        (v - _plotMin) / (_plotMax - _plotMin) * (box.height - pad * 2 - 14);

    // Time cursors: the newest patch, and where "now" sits relative to it.
    for (final cursor in [
      (t: clock.lastServerTime, label: 'newest patch'),
      (t: serverNow, label: 'now'),
    ]) {
      final x = tx(cursor.t);
      if (x < box.left || x > box.right) continue;
      draw.dashedScreen(Offset(x, box.top + 4), Offset(x, box.bottom - 4),
          Palette.text.fade(0.25));
      draw.text(x - 40, box.top + 5, 80, cursor.label, Palette.text.fade(0.5),
          size: 9, align: TextAlign.center);
    }

    // The samples that actually arrived.
    _samples.forEach((t, v) {
      if (t < tMin || t > tMax) return;
      draw.rect(
          Rect.fromLTWH(tx(t) - 1.5, ty(v) - 1.5, 3, 3), Palette.text.fade(0.85));
    });

    // What each mode rendered between them.
    for (final mode in _modes) {
      if (!mode.visible || mode.predict == null) continue;
      Offset? previous;
      mode.trace.forEach((t, v) {
        if (t < tMin || t > tMax) {
          previous = null;
          return;
        }
        final point = Offset(tx(t), ty(v));
        final from = previous;
        if (from != null) {
          draw.lineScreen(from, point, mode.color.fade(0.9), width: 1.2);
        }
        previous = point;
      });
    }
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
          for (final mode in _modes) {
            mode.smooth.clear();
          }
        },
      ),
      SliderSpec('lerp delay', 0, 300, _lerpDelay, (v) {
        _lerpDelay = v;
        _retune('lerp', FieldOptions(mode: PredictMode.lerp, delay: v));
      }, divisions: 12, format: (v) => '${v.round()} ms'),
      SliderSpec('damped damping', 2, 30, _damping, (v) {
        _damping = v;
        _retune('damped', FieldOptions(mode: PredictMode.damped, damping: v));
      }, divisions: 14, format: (v) => '${v.round()} /s'),
      SliderSpec('extrapolate cap', 50, 500, _maxExtrapolate, (v) {
        _maxExtrapolate = v;
        _retune('extrapolate',
            FieldOptions(mode: PredictMode.extrapolate, maxExtrapolate: v));
      }, divisions: 9, format: (v) => '${v.round()} ms'),
      for (final mode in _modes)
        ToggleSpec('show ${mode.name}', mode.visible, (v) => mode.visible = v),
      const NoteSpec('The pattern is room-wide. WASD drives your own square, '
          'which is drawn raw.'),
    ];
  }

  /// Re-attaches one mode with new options. Cheap: each mode owns its own
  /// Predict, because a field can only be tracked once per instance.
  void _retune(String name, FieldOptions options) {
    final joined = room;
    if (joined == null) return;
    for (final mode in _modes) {
      if (mode.name != name) continue;
      mode.options = options;
      mode.attach(joined);
      mode.smooth.clear();
      mode.trace.clear();
    }
  }

  @override
  void onReconnect() {
    _pacer.reset();
    _samples.clear();
    for (final mode in _modes) {
      mode.trace.clear();
      mode.smooth.clear();
    }
    _lastRawX = double.nan;
    _lastRawY = double.nan;
  }

  @override
  void unmount() {
    for (final mode in _modes) {
      mode.dispose();
    }
    _modes.clear();
    _samples.clear();
    NetDelay.unregister(room!);
  }
}

/// One way of rendering the bot: its own [Predict], its trace, its score.
class _Mode {
  _Mode(this.name, this.color, this.options);

  /// Label on the ring and in the HUD.
  final String name;

  /// Identifies this mode on the arena and in the strip.
  final Color color;

  /// How the fields are tracked; null renders the decoded value verbatim.
  FieldOptions? options;

  /// This mode's own prediction layer, or null for raw.
  Predict? predict;

  /// What this mode rendered, for the timeline strip.
  final Series trace = Series(400);

  /// Rendered-speed variation, the "does it limp?" score.
  final Smoothness smooth = Smoothness();

  /// Last computed coefficient of variation; NaN until the window fills.
  double cv = double.nan;

  /// Whether the ring and trace are drawn.
  bool visible = true;

  /// (Re)binds this mode's Predict to the bots collection.
  void attach(ColyseusRoom room) {
    predict?.dispose();
    predict = null;

    final config = options;
    if (config == null) return;

    final layer = Predict.of(room);
    layer.attachAll('bots', config: {'x': config, 'y': config});
    predict = layer;
  }

  /// The value this mode would draw. Raw reads straight through.
  double read(SchemaInstance instance, String field) =>
      predict?.value(instance, field) ?? (instance[field] as num).toDouble();

  void dispose() {
    predict?.dispose();
    predict = null;
  }
}
