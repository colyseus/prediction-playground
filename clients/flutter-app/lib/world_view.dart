import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'sim/constants.dart';

/// World↔screen transform: the fixed logical arena ([arenaW] × [arenaH] world
/// units) letterboxed into a stage rect.
///
/// Port of `src/client/framework/draw.ts`'s `WorldView` via
/// `godot-gd-app/scripts/world_view.gd` — same margin default, same centring.
class WorldView {
  /// Screen pixels per world unit.
  double scale = 1.0;

  /// Screen x of world x=0.
  double ox = 0.0;

  /// Screen y of world y=0.
  double oy = 0.0;

  /// The rect the arena was last fitted into.
  Rect stage = Rect.zero;

  /// Letterbox the arena into [stage], keeping [margin] screen px of breathing
  /// room on the tight axis.
  void fit(Rect stage, {double margin = 28}) {
    this.stage = stage;
    final fx = (stage.width - margin * 2.0) / arenaW;
    final fy = (stage.height - margin * 2.0) / arenaH;
    scale = math.min(fx, fy);
    ox = stage.left + (stage.width - arenaW * scale) / 2.0;
    oy = stage.top + (stage.height - arenaH * scale) / 2.0;
  }

  /// World x → screen x.
  double sx(double x) => ox + x * scale;

  /// World y → screen y.
  double sy(double y) => oy + y * scale;

  /// World length → screen length.
  double s(double len) => len * scale;

  /// Screen x → world x, for pointer aiming.
  double wx(double px) => (px - ox) / scale;

  /// Screen y → world y, for pointer aiming.
  double wy(double py) => (py - oy) / scale;
}
