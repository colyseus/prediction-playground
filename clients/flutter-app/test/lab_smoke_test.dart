// Each lab mounts, drives real frames against the live server, and renders.
//
// Cheaper and far more reliable than driving the window: it catches a lab that
// fails to join, throws in its step, or blows up in render, which is most of
// what breaks when a lab is wired up wrong.
//
// Needs the playground server:
//   cd demos/prediction-tools && pnpm dev --host 0.0.0.0
import 'dart:io';
import 'dart:ui';

import 'package:colyseus/colyseus.dart';
import 'package:colyseus_playground/controls.dart';
import 'package:colyseus_playground/draw_kit.dart';
import 'package:colyseus_playground/hud.dart';
import 'package:colyseus_playground/kb.dart';
import 'package:colyseus_playground/lab.dart';
import 'package:colyseus_playground/labs/lab04_interp_modes.dart';
import 'package:colyseus_playground/labs/lab05_dead_reckoning.dart';
import 'package:colyseus_playground/labs/lab06_lag_comp.dart';
import 'package:colyseus_playground/labs/lab07_wysiwyg.dart';
import 'package:colyseus_playground/labs/lab08_optimistic_events.dart';
import 'package:colyseus_playground/labs/lab09_predicted_spawns.dart';
import 'package:colyseus_playground/labs/lab10_composite_sim.dart';
import 'package:colyseus_playground/labs/lab11_deterministic_rng.dart';
import 'package:colyseus_playground/net/net_delay.dart';
import 'package:colyseus_playground/sim/sim.dart';
import 'package:colyseus_playground/shell.dart';
import 'package:colyseus_playground/world_view.dart';
import 'package:flutter_test/flutter_test.dart';

Future<bool> serverUp() async {
  try {
    final s = await Socket.connect('127.0.0.1', 5173,
        timeout: const Duration(milliseconds: 500));
    s.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> run(
  Lab lab,
  int frames, {
  double moveX = 0,
  void Function(Lab lab, int frame)? each,
}) async {
  final view = WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600));
  final ctx = LabContext(client: _client!, view: view);

  Kb.autopilot = true;
  Kb.autoX = moveX;
  Kb.mousePos = const Offset(400, 300);

  for (var i = 0; i < frames; i++) {
    Colyseus.pump();
    final now = lab.room!.clock.now;
    lab.frame(ctx, now, 16);

    final recorder = PictureRecorder();
    final draw = DrawKit(Canvas(recorder), view);
    ctx.draw = draw;
    ctx.hud = Hud(draw)..begin(920, 100, 300);
    lab.render(ctx);
    recorder.endRecording().dispose();

    Kb.endFrame();
    each?.call(lab, i);
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  Kb.autopilot = false;
}

ColyseusClient? _client;

Future<void> close(Lab lab) async {
  lab.unmount();
  final room = lab.room;
  if (room != null) {
    room.setLatency();
    await room.leave();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Colyseus.pump();
    room.dispose();
  }
  _client?.dispose();
  _client = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const budget = Timeout(Duration(minutes: 2));

  Future<Lab?> mountLab(Lab lab) async {
    if (!await serverUp()) {
      markTestSkipped('server down');
      return null;
    }
    _client = ColyseusClient(defaultEndpoint);
    final ctx = LabContext(
        client: _client!,
        view: WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600)));
    expect(await lab.mount(ctx), isTrue, reason: 'lab ${lab.id} did not mount');
    return lab;
  }

  test('04 drives and renders', () async {
    final lab = await mountLab(Lab04InterpModes());
    if (lab == null) return;
    await run(lab, 200, moveX: 1);
    await close(lab);
  }, timeout: budget);

  test('05 drives and renders', () async {
    final lab = await mountLab(Lab05DeadReckoning());
    if (lab == null) return;
    await run(lab, 200);
    await close(lab);
  }, timeout: budget);

  test('08 scores a goal and settles it', () async {
    final lab = await mountLab(Lab08OptimisticEvents());
    if (lab == null) return;
    await run(lab, 300, moveX: 1);
    final me = lab.room!.state?.getMap('players')?[lab.room!.sessionId]
        as SchemaInstance?;
    // ignore: avoid_print
    print('LAB08 score=${me?['score']} scoreTicks=${me?['scoreTicks']}');
    expect((me?['score'] as num?)?.toInt() ?? 0, greaterThan(0),
        reason: 'never reached the goal zone, so nothing was predicted');
    await close(lab);
  }, timeout: budget);

  test('09 fires and correlates', () async {
    final lab = await mountLab(Lab09PredictedSpawns());
    if (lab == null) return;

    final view = WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600));
    final ctx = LabContext(client: _client!, view: view);
    final buttons =
        lab.controls(ctx).whereType<ButtonsSpec>().first.buttons.first;

    await run(lab, 260, each: (l, i) {
      if (i % 40 == 20) buttons.onPressed();
    });

    // The turret fires on its own schedule, so only the owned entities prove
    // the fire input made the round trip.
    var mine = 0;
    final projectiles = lab.room!.state?.getMap('projectiles');
    for (final entry in projectiles?.entries ?? const <MapEntry<String, dynamic>>[]) {
      final instance = entry.value;
      if (instance is SchemaInstance && instance['owner'] == lab.room!.sessionId) {
        mine++;
      }
    }
    // ignore: avoid_print
    print('LAB09 projectiles=${projectiles?.length} mine=$mine');
    expect(mine, greaterThan(0),
        reason: 'the fire input never produced an authoritative projectile');
    await close(lab);
  }, timeout: budget);

  /// The Fire button a lab exposes, so a scripted run shoots without a cursor.
  VoidCallback fireButton(Lab lab) {
    final ctx = LabContext(
        client: _client!,
        view: WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600)));
    return lab.controls(ctx).whereType<ButtonsSpec>().first.buttons.first
        .onPressed;
  }

  test('06 fires and gets the server shot report', () async {
    final lab = Lab06LagComp();
    if (await mountLab(lab) == null) return;

    final fire = fireButton(lab);
    await run(lab, 280, each: (l, i) {
      if (i % 40 == 20) fire();
    });

    // ignore: avoid_print
    print('LAB06 reports=${lab.reports} on=${lab.hitsOn}/${lab.shotsOn} '
        'off=${lab.hitsOff}/${lab.shotsOff} viewLag=${lab.viewLag} '
        'renderDelay=${lab.lane!.renderDelay}');
    expect(lab.reports, greaterThan(0),
        reason: 'no shot broadcast came back, so nothing was ever resolved');
    // The stamp the whole lab rests on: with no render delay advertised the
    // server would rewind to the present, which is no rewind at all.
    expect(lab.lane!.renderDelay, greaterThan(0),
        reason: 'the input never picked up the display timeline');
    await close(lab);
    // The lab raises injected latency on mount; leave it as the next one
    // found it.
    NetDelay.select(0);
  }, timeout: budget);

  test('11 derives the same fan the server does', () async {
    // The seed derivation is what the whole lab rests on.
    expect(shotSeed(7, 12345), 1994071465);

    final lab = Lab11DeterministicRng();
    if (await mountLab(lab) == null) return;

    final fire = fireButton(lab);
    await run(lab, 280, each: (l, i) {
      if (i % 40 == 20) fire();
    });

    // ignore: avoid_print
    print('LAB11 answered=${lab.answered} worstDelta=${lab.worstDelta} '
        'lastHits=${lab.lastHits}');
    expect(lab.answered, greaterThan(0),
        reason: 'no spread broadcast matched a predicted fan');
    expect(lab.worstDelta, lessThan(1e-9),
        reason: 'the client and the server rolled different pellets');

    // The other half of the lesson: the unseeded generator has to visibly
    // disagree, or the toggle is demonstrating nothing.
    lab.cheat = true;
    await run(lab, 140, each: (l, i) {
      if (i % 40 == 20) fire();
    });
    // ignore: avoid_print
    print('LAB11 cheating lastDelta=${lab.lastDelta} '
        'worstSeeded=${lab.worstDelta}');
    expect(lab.lastDelta, greaterThan(1e-6),
        reason: 'the unseeded fan matched the server, which cannot happen');
    expect(lab.worstDelta, lessThan(1e-9),
        reason: 'a seeded fan diverged after the toggle was flipped');
    await close(lab);
  }, timeout: budget);

  test('07 predicts a bump and replays the same verdict', () async {
    final lab = Lab07Wysiwyg();
    if (await mountLab(lab) == null) return;

    // A predicted collision says nothing on a 1 ms link: the whole lab lives
    // in the window between stamping an input and the server processing it,
    // and that window is also what makes rollback replay happen at all.
    lab.room!.setLatency(delayMs: 240, jitterMs: 20);

    // Park in the patrol lane and let the sweep come to us: chasing a target
    // that moves at 20 u/s with a 34 u/s bang-bang controller just orbits it.
    await run(lab, 260, each: (l, i) {
      final bot = lab.bot;
      final lane = lab.lane;
      if (bot == null || lane == null) return;
      final dx = arenaW / 2 - lane.predictedX;
      final dy = (bot['y'] as num).toDouble() - lane.predictedY;
      // Only drift back toward the middle once a knockback has pushed us out
      // of the swept span.
      Kb.autoX = dx.abs() < 12 ? 0 : (dx > 0 ? 1 : -1);
      Kb.autoY = dy > 0.5 ? 1 : (dy < -0.5 ? -1 : 0);
    });

    final me = lab.lane!.me;
    // ignore: avoid_print
    print('LAB07 bumps=${lab.bumps} server=${me?['bumps']} '
        'replayed=${lab.replayedVerdicts} flips=${lab.verdictFlips} '
        'mispredicts=${lab.mispredicts} driftEma=${lab.lane!.drift.ema}');
    expect(lab.bumps, greaterThan(0),
        reason: 'never touched the bot, so no verdict was ever taken');
    expect(lab.replayedVerdicts, greaterThan(0),
        reason: 'nothing was replayed, so the frozen verdict was not exercised');
    expect(lab.verdictFlips, 0,
        reason: 'a replayed input reached a different verdict than its live '
            'step — memoVec is not freezing the collision test');
    await close(lab);
  }, timeout: budget);

  test('10 predicts a world, not an entity', () async {
    final lab = Lab10CompositeSim();
    if (await mountLab(lab) == null) return;

    // Enough delay that inputs are actually in flight: with none, the sim
    // would never rewind and the composite path would go untested.
    lab.room!.setLatency(delayMs: 240, jitterMs: 20);

    var retreat = 0;
    var struck = 0;
    await run(lab, 280, each: (l, i) {
      // Chase the puck, then back off to our own half after a strike: holding
      // it against a wall freezes the world, which agrees perfectly and proves
      // nothing.
      if (lab.touches != struck) {
        struck = lab.touches;
        retreat = 36;
      }
      if (retreat > 0) retreat--;
      final tx = retreat > 0 ? arenaW / 2 : lab.puckX;
      final ty = retreat > 0 ? arenaH * 0.75 : lab.puckY;
      final dx = tx - lab.paddleX;
      final dy = ty - lab.paddleY;
      Kb.autoX = dx > 0.4 ? 1 : (dx < -0.4 ? -1 : 0);
      Kb.autoY = dy > 0.4 ? 1 : (dy < -0.4 ? -1 : 0);
    });

    final sim = lab.sim!;
    final serverPuck = lab.puck!;
    // ignore: avoid_print
    print('LAB10 reconciles=${sim.reconcileSeq} stepMs=${sim.stepMs} '
        'pending=${sim.pendingCount} touches=${lab.touches} '
        'lastCorrection=${sim.lastCorrectionMag} driftEma=${sim.drift.ema} '
        'driftPeak=${sim.drift.peak} puckLead=${lab.maxPuckLead} '
        'puck=(${lab.puckX},${lab.puckY}) '
        'server=(${serverPuck['x']},${serverPuck['y']})');

    expect(sim.reconcileSeq, greaterThan(0),
        reason: 'the composite world never adopted an authoritative tick');
    expect(sim.stepMs, closeTo(1000 / tickHz, 1),
        reason: 'the sim is not running on the server-advertised fixed step');
    // The puck is a bound part, so its predicted pose reads back through
    // predict.value like any other entity.
    expect(lab.puckX, inInclusiveRange(0, arenaW));
    expect(lab.puckY, inInclusiveRange(0, arenaH));
    expect(lab.touches, greaterThan(0),
        reason: 'never predicted a contact, so the composite step did nothing '
            'a flat reconciler could not have done');
    await close(lab);
  }, timeout: budget);
}
