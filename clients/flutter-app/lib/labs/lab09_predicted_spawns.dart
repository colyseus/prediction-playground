import 'dart:math' as math;

import 'package:colyseus/colyseus.dart';
import 'package:flutter/services.dart';

import '../controls.dart';
import '../hud.dart';
import '../kb.dart';
import '../lab.dart';
import '../net/schema_bridge.dart';
import '../palette.dart';
import '../sim/sim.dart';
import 'move_lane.dart';
import '../gen/schema.dart';

/// Firing without waiting for permission.
///
/// The projectile leaves your square the same frame you click, but the
/// authoritative entity does not exist until the fire input reaches the
/// server, half a round trip later. The spawn store owns that gap: it holds
/// the local prediction, matches it to the server entity when it arrives, and
/// collapses the two onto one entry with a stable id.
///
/// Everything is drawn through `store.value(entry, ...)`, which reads the
/// local while the entry is pending and the authoritative entity once it is
/// confirmed. The handoff is meant to be invisible; the amber-to-white tint is
/// added here only so it can be watched at all.
///
/// `spawnTime` is what keeps it invisible. The server stamps `bornMs` when it
/// creates the entity, which is later than the moment you fired, so a
/// confirmed projectile drawn at server-present would snap backwards by the
/// lead times its speed. The store measures that lead per shot and keeps owned
/// entries flying the shooter's timeline instead.
///
/// The turret's shots come through the same store as foreign entries. Nobody
/// predicted those, so they arrive a full one-way trip late.
class Lab09PredictedSpawns extends Lab {
  @override
  String get id => '09';

  @override
  String get title => 'Predicted Spawns';

  @override
  String get blurb => 'Optimistic projectile, then an invisible handoff.';

  /// Where the server's turret sits, and how big to draw it.
  static const _turretX = arenaW / 2;
  static const _turretY = 8.0;
  static const _turretHalf = 2.0;

  static const _flashMs = 350.0;

  MoveLane<Player>? lane;
  Spawns? _store;

  /// Scratch adapters for the reckon step. The core reuses a small set of
  /// scratch views, so this stays tiny.
  final _bodies = <SchemaView, SchemaBody>{};

  /// Entries seen pending, so the frame they flip can be spotted.
  final Set<int> _pendingIds = {};

  /// Entry id to the room-clock instant it crossed the handoff.
  final Map<int, double> _flashes = {};

  double _aimX = arenaW / 2;
  double _aimY = 20;
  bool _pendingFire = false;
  bool _optimistic = true;

  int _fired = 0;
  int _pending = 0;
  int _confirmed = 0;
  int _foreign = 0;
  double _lastLeadMs = double.nan;

  @override
  Future<bool> mount(LabContext ctx) async {
    final joined = await MoveLane.mount(ctx.client,
        playerType: Player.new, roomName: 'lab-projectile');
    if (joined == null) return false;

    lane = joined;
    room = joined.room;

    final sid = joined.room.sessionId;
    _store = joined.predict.spawns(
      'projectiles',
      SpawnsOptions(
        // The turret's shots are nobody's prediction, so they must never be
        // matched to a local one.
        owned: (server) => server['owner'] == sid,
        spawnTime: (server) => (server['bornMs'] as num).toDouble(),
        step: (local, dt) => stepProjectile(local as _Shot, dt),
        localRead: (local, field) => (local as _Shot).read(field),
        // Confirmed entities dead-reckon through the same flight function, so
        // they are drawn at the present rather than at the last patch.
        fields: const ['x', 'y'],
        reckonStep: (state, dt, elapsedMs) {
          final view = state as SchemaView;
          stepProjectile(_bodies.putIfAbsent(view, () => SchemaBody(view)), dt);
        },
      ),
    );

    joined.fillInput = (data) {
      data['aimX'] = _aimX;
      data['aimY'] = _aimY;
      data.setBool('fire', _pendingFire);
    };
    joined.afterSend = () {
      if (!_pendingFire) return;
      _pendingFire = false;
      _fired++;
      if (_optimistic) _spawn();
    };

    return true;
  }

  /// Spawns the optimistic local at the predicted pose.
  ///
  /// The input has already been applied to the mirror by the time this runs,
  /// so this is the same origin the server will use once it processes it.
  void _spawn() {
    final recon = lane?.reconciler;
    final store = _store;
    if (recon == null || store == null) return;

    final x = recon.state['x'];
    final y = recon.state['y'];
    final dx = _aimX - x;
    final dy = _aimY - y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return;

    store.spawn(_Shot(
      x,
      y,
      dx / len * projectileSpeed,
      dy / len * projectileSpeed,
    ));
  }

  @override
  void frame(LabContext ctx, double now, double dtMs) {
    final l = lane;
    if (l == null || !l.ready) return;

    // Aiming follows the pointer while it is over the arena; the panel keeps
    // its own clicks.
    final pointer = Kb.mousePos;
    final overStage = pointer.dx < ctx.view.stage.right;
    if (overStage && !Kb.autopilot) {
      _aimX = ctx.view.wx(pointer.dx).clamp(0.0, arenaW);
      _aimY = ctx.view.wy(pointer.dy).clamp(0.0, arenaH);
    }
    if ((overStage && Kb.mouseDown) || Kb.pressed(LogicalKeyboardKey.space)) {
      _pendingFire = true;
    }

    l.drive(now);
    _sweep(now);
  }

  /// Folds the store into counters and handoff flashes.
  ///
  /// Lives in the frame rather than the render so a headless run reports the
  /// same numbers.
  void _sweep(double now) {
    final store = _store;
    final sid = lane?.room.sessionId;
    if (store == null || sid == null) return;

    _pending = 0;
    _confirmed = 0;
    _foreign = 0;
    final live = <int>{};

    for (final entry in store.entries) {
      live.add(entry.id);
      if (!entry.confirmed) {
        _pending++;
        _pendingIds.add(entry.id);
        continue;
      }

      _confirmed++;
      if (entry.server?['owner'] != sid) _foreign++;

      if (_pendingIds.remove(entry.id)) {
        _flashes[entry.id] = now;
        if (entry.leadMs > 0) _lastLeadMs = entry.leadMs;
      }
    }

    _pendingIds.removeWhere((id) => !live.contains(id));
    _flashes.removeWhere((id, _) => !live.contains(id));
  }

  @override
  void render(LabContext ctx) {
    final l = lane;
    final store = _store;
    if (l == null || store == null) return;

    final draw = ctx.draw;
    final now = l.room.clock.now;
    final sid = l.room.sessionId;

    draw.square(_turretX, _turretY, _turretHalf, Palette.bad.fade(0.3));
    draw.squareOutline(_turretX, _turretY, _turretHalf, Palette.bad);
    draw.label(_turretX, _turretY, 'turret (foreign shots)', Palette.bad,
        size: 10, dy: -ctx.view.s(_turretHalf) - 16);

    for (final other in l.others) {
      draw.square(other.x, other.y, playerHalf,
          hueColor(other.hue, alpha: 0.45));
    }
    draw.square(l.predictedX, l.predictedY, playerHalf, hueColor(l.hue));
    draw.squareOutline(l.predictedX, l.predictedY, playerHalf,
        const Color(0xFFFFFFFF), width: 1.5);
    draw.marker(_aimX, _aimY, 0.8, Palette.text.fade(0.6));

    // One render path across the handoff: the same call reads the stepped
    // local while pending and the reckoned entity once confirmed.
    for (final entry in store.entries) {
      final x = store.value(entry, 'x');
      final y = store.value(entry, 'y');
      if (x.isNaN || y.isNaN) continue;

      if (!entry.confirmed) {
        draw.circle(x, y, projectileRadius, Palette.warn.fade(0.9));
        continue;
      }

      final flashing = now - (_flashes[entry.id] ?? double.negativeInfinity) <
          _flashMs;
      final mine = entry.server?['owner'] == sid;
      draw.circle(x, y, projectileRadius * (flashing ? 1.8 : 1.0),
          mine ? Palette.text.fade(0.95) : Palette.bad.fade(0.9));
    }

    _renderHud(ctx, l);
  }

  void _renderHud(LabContext ctx, MoveLane<Player> l) {
    final hud = ctx.hud;

    hud.section('SPAWN STORE');
    hud.row('entries', '${_store?.size ?? 0}');
    hud.row('pending (mine)', '$_pending',
        tone: _pending > 0 ? HudTone.warn : HudTone.plain);
    hud.row('confirmed', '$_confirmed');
    hud.row('of those, foreign', '$_foreign');
    hud.row(
      'last measured lead',
      _lastLeadMs.isNaN ? '—' : '${_lastLeadMs.round()} ms',
      color: _lastLeadMs.isNaN ? Palette.textFaint : Palette.good,
    );
    hud.row('shots fired', '$_fired');

    hud.section('CLOCK');
    hud.row('rtt', '${l.room.clock.smoothedRtt.round()} ms');
    hud.chips(l.pending, label: 'inputs pending');

    hud.note('Amber is your local prediction, white is confirmed and '
        'correlated, red is the turret. Turn optimistic spawn off and your '
        'own shot only appears when the server entity arrives, a full round '
        'trip late.');
  }

  @override
  List<ControlSpec> controls(LabContext ctx) {
    return [
      ToggleSpec('optimistic spawn', _optimistic, (v) => _optimistic = v),
      ButtonsSpec([
        (label: 'Fire', onPressed: () => _pendingFire = true),
      ]),
      const NoteSpec('Click on the arena or press space to fire; the pointer '
          'aims. The turret fires at the nearest player on its own schedule, '
          'so foreign shots keep arriving whether or not you do.'),
    ];
  }

  @override
  void onReconnect() {
    _store?.clear();
    _pendingIds.clear();
    _flashes.clear();
    _bodies.clear();
    _pendingFire = false;
  }

  @override
  void unmount() {
    // The store belongs to the lane's Predict, which disposes it.
    _store = null;
    lane?.dispose();
    lane = null;
    _pendingIds.clear();
    _flashes.clear();
    _bodies.clear();
  }
}

/// The optimistic projectile, owned entirely by this lab.
///
/// The store treats it as opaque and only reaches it through the callbacks,
/// so it implements just enough for the shared flight step to run over it.
class _Shot implements EntityState {
  @override
  double x;
  @override
  double y;
  @override
  double vx;
  @override
  double vy;

  _Shot(this.x, this.y, this.vx, this.vy);

  /// Field access for the store, so a pending entry renders like a confirmed
  /// one.
  double read(String field) => switch (field) {
        'x' => x,
        'y' => y,
        'vx' => vx,
        'vy' => vy,
        _ => double.nan,
      };
}
