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

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:colyseus_playground/controls.dart';
import 'package:colyseus_playground/draw_kit.dart';
import 'package:colyseus_playground/hud.dart';
import 'package:colyseus_playground/kb.dart';
import 'package:colyseus_playground/lab.dart';
import 'package:colyseus_playground/labs/lab04_interp_modes.dart';
import 'package:colyseus_playground/labs/lab05_dead_reckoning.dart';
import 'package:colyseus_playground/labs/lab08_optimistic_events.dart';
import 'package:colyseus_playground/labs/lab09_predicted_spawns.dart';
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
}
