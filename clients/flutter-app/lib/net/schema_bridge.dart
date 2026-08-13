import 'package:colyseus/colyseus.dart';

import '../sim/sim.dart';

/// Runs the shared sim directly over SDK-backed storage.
///
/// The step functions in `lib/sim/` take abstract interfaces so the same code
/// can drive a plain [SimEntity] or someone else's storage. These adapters are
/// the second case: every getter and setter forwards straight into a
/// [SchemaView], so a reconciler's predicted mirror is stepped in place with
/// no copying and no chance of the copy drifting from the real thing.
///
/// [SchemaView] resolves each field name once, so this costs one leaf FFI call
/// per access.
class SchemaBody implements BumpableState, ScorerState, BotState {
  final SchemaView view;

  SchemaBody(this.view);

  @override
  double get x => view['x'];
  @override
  set x(double v) => view['x'] = v;

  @override
  double get y => view['y'];
  @override
  set y(double v) => view['y'] = v;

  @override
  double get vx => view['vx'];
  @override
  set vx(double v) => view['vx'] = v;

  @override
  double get vy => view['vy'];
  @override
  set vy(double v) => view['vy'] = v;

  // Counters are declared int on the sim side; the schema stores them as
  // numbers, so they round-trip through the view as whole doubles.
  @override
  int get bumpTicks => view['bumpTicks'].toInt();
  @override
  set bumpTicks(int v) => view['bumpTicks'] = v;

  @override
  int get scoreTicks => view['scoreTicks'].toInt();
  @override
  set scoreTicks(int v) => view['scoreTicks'] = v;

  @override
  String get kind => view.getString('kind') ?? '';

  @override
  double get minX => view['minX'];
  @override
  double get maxX => view['maxX'];
  @override
  double get baseY => view['baseY'];
  @override
  double get phaseMs => view['phaseMs'];
  @override
  double get speed => view['speed'];

  @override
  double get lastTeleport => view['lastTeleport'];
  @override
  set lastTeleport(double v) => view['lastTeleport'] = v;
}

/// The movement input, read out of the SDK's command view.
class SchemaMoveInput implements MoveInputLike {
  final SchemaView view;

  SchemaMoveInput(this.view);

  @override
  double get moveX => view['moveX'];
  @override
  set moveX(double v) => view['moveX'] = v;

  @override
  double get moveY => view['moveY'];
  @override
  set moveY(double v) => view['moveY'] = v;
}

/// A body and an input, both bound to views that only change when the SDK
/// swaps its storage.
///
/// Reconciler steps run dozens of times per frame during replay, so the
/// adapters are built once per view rather than per step.
class StepBinding {
  SchemaBody? _body;
  SchemaMoveInput? _input;

  /// The body adapter for [state], reused while the view is the same.
  SchemaBody body(SchemaView state) {
    final cached = _body;
    if (cached != null && identical(cached.view, state)) return cached;
    return _body = SchemaBody(state);
  }

  /// The input adapter for [command], reused while the view is the same.
  SchemaMoveInput input(SchemaView command) {
    final cached = _input;
    if (cached != null && identical(cached.view, command)) return cached;
    return _input = SchemaMoveInput(command);
  }
}
