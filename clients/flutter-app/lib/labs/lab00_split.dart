import 'dart:math' as math;
import 'dart:ui';

import '../controls.dart';
import '../draw_kit.dart';
import '../hud.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/net_delay.dart';
import '../palette.dart';
import '../sim/sim.dart';
import '../trail.dart';
import '../world_view.dart';
import 'move_lane.dart';
import '../gen/schema.dart';

/// One reversal-heavy leg of the autopilot: direction and how long to hold it.
typedef _Leg = ({double dx, double dy, double ms});

/// Both answers to latency, on screen at once.
///
/// Two lanes, one connection, one entity. The top lane draws what the server
/// last confirmed; the bottom draws the prediction. Same inputs, same room, so
/// the only difference is whether the client waits for the server or runs
/// ahead of it.
///
/// The gap between the two squares is the round trip, made visible. Reversals
/// are where it shows worst: the echo lane keeps travelling the old direction
/// for a full round trip after you have already turned around, which is why
/// the autopilot is built out of them.
class Lab00Split extends Lab {
  @override
  String get id => '00';

  @override
  String get title => 'Lag vs Prediction';

  @override
  String get blurb =>
      'Same input, same server. The top lane waits; the bottom predicts.';

  /// Two lanes, each with its own arena.
  @override
  bool get ownArena => true;

  MoveLane<Player>? lane;

  final _topView = WorldView();
  final _bottomView = WorldView();
  final _echoTrail = Trail(capacity: 120);
  final _predictedTrail = Trail(capacity: 120);

  // Reversals are the point, so the script is mostly turns.
  static const _script = <_Leg>[
    (dx: 1, dy: 0, ms: 850),
    (dx: -1, dy: 0, ms: 700),
    (dx: 1, dy: 0, ms: 550),
    (dx: 0, dy: 1, ms: 650),
    (dx: 0, dy: -1, ms: 700),
    (dx: 1, dy: 1, ms: 600),
    (dx: -1, dy: -1, ms: 750),
    (dx: -1, dy: 0, ms: 550),
    (dx: 1, dy: 0, ms: 800),
    (dx: 0, dy: -1, ms: 500),
  ];

  bool _userDrove = false;
  int _legIndex = 0;
  double _legUntil = 0;
  double _legX = 1;
  double _legY = 0;

  @override
  Future<bool> mount(LabContext ctx) async {
    lane = await MoveLane.mount(ctx.client, playerType: Player.new);
    room = lane?.room;
    if (lane == null) return false;

    // Localhost has no latency, so at the default preset both lanes would sit
    // on top of each other and the lab would show nothing.
    if (NetDelay.index == 0) NetDelay.select(2);
    return true;
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    // Hand over the moment the viewer touches a key, and never take it back.
    if (!_userDrove && (Kb.moveX() != 0 || Kb.moveY() != 0)) _userDrove = true;

    if (_userDrove) {
      l.drive(now);
    } else {
      _advanceAutopilot(now, l.predictedX, l.predictedY);
      l.drive(now, moveX: _legX, moveY: _legY);
    }

    _echoTrail.add(l.serverX, l.serverY);
    _predictedTrail.add(l.predictedX, l.predictedY);
  }

  /// Picks the next scripted leg, steering away from the walls.
  ///
  /// A leg that would run the square into a wall gets flipped, so the demo
  /// keeps moving instead of grinding along an edge.
  void _advanceAutopilot(double now, double x, double y) {
    if (now < _legUntil) return;

    final leg = _script[_legIndex % _script.length];
    _legIndex++;
    _legX = leg.dx;
    _legY = leg.dy;

    if (x > arenaW * 0.72 && _legX > 0) {
      _legX = -1;
    } else if (x < arenaW * 0.28 && _legX < 0) {
      _legX = 1;
    }
    if (y > arenaH * 0.72 && _legY > 0) {
      _legY = -1;
    } else if (y < arenaH * 0.28 && _legY < 0) {
      _legY = 1;
    }

    _legUntil = now + leg.ms;
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    if (l == null) return;

    final draw = ctx.draw;
    final stage = ctx.view.stage;
    final laneHeight = stage.height / 2;
    const lanePad = 12.0;

    _topView.fit(Rect.fromLTWH(
      stage.left,
      stage.top,
      stage.width,
      laneHeight - lanePad,
    ));
    _bottomView.fit(Rect.fromLTWH(
      stage.left,
      stage.top + laneHeight,
      stage.width,
      laneHeight - lanePad,
    ));

    final hue = l.hue;

    _renderLane(
      DrawKit(draw.canvas, _topView),
      'SERVER ECHO',
      'every move waits the full round trip',
      l.serverX,
      l.serverY,
      _echoTrail,
      Palette.textDim,
      hueColor(hue, alpha: 0.55),
    );

    _renderLane(
      DrawKit(draw.canvas, _bottomView),
      'PREDICTED',
      'responds on the frame you press',
      l.predictedX,
      l.predictedY,
      _predictedTrail,
      Palette.good,
      hueColor(hue),
    );

    _renderHud(ctx, l);
  }

  /// Draws one lane through its own [DrawKit].
  ///
  /// A kit binds one world-to-screen transform, so each lane gets its own
  /// rather than mutating a shared one mid-frame.
  void _renderLane(
    DrawKit draw,
    String title,
    String subtitle,
    double x,
    double y,
    Trail trail,
    Color titleColor,
    Color fill,
  ) {
    final view = draw.view;

    draw.arena();
    trail.draw(draw, fill.withValues(alpha: 0.22));
    draw.square(x, y, playerHalf, fill);
    draw.squareOutline(x, y, playerHalf, const Color(0xFFFFFFFF), width: 1.5);

    final tx = view.sx(0) + 10;
    final ty = view.sy(0) + 6;
    draw.text(tx, ty, 220, title, titleColor, size: 12);
    draw.text(tx + 120, ty, view.s(arenaW) - 130, subtitle, Palette.textDim,
        size: 11);
  }

  void _renderHud(LabContext ctx, MoveLane<Player> l) {
    final hud = ctx.hud;
    final clock = l.room.clock;

    // How far the echo lane trails the prediction, in world units.
    final dx = l.predictedX - l.serverX;
    final dy = l.predictedY - l.serverY;
    final gap = math.sqrt(dx * dx + dy * dy);

    hud.section('THE GAP');
    hud.row('round trip', '${clock.smoothedRtt.round()} ms');
    hud.row('echo trails by', gap.toStringAsFixed(1),
        tone: gap > 4 ? HudTone.bad : HudTone.warn);
    hud.chips(l.pending, label: 'pending inputs');
    hud.row('injected', NetDelay.current.label);

    hud.note(_userDrove
        ? 'Both lanes are the same entity in the same room. Only the lane you '
            'draw from differs.'
        : 'Autopilot is driving. Press a movement key to take over.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) => [
        const NoteSpec('The top lane is lab 01. The bottom is lab 03. Same '
            'code path, same room, drawn from two different positions.'),
        ButtonsSpec([
          (
            label: 'Take over',
            onPressed: () => _userDrove = true,
          ),
        ]),
      ];

  @override
  void onReconnect() {
    _echoTrail.clear();
    _predictedTrail.clear();
  }

  @override
  void unmount() {
    lane?.dispose();
    lane = null;
    _echoTrail.clear();
    _predictedTrail.clear();
  }
}
