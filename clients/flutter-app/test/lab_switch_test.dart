// Switching between labs, which is what a viewer actually does.
//
// The per-lab smoke test mounts each one in isolation. This drives the
// transition instead: mount, run, tear down, mount the next. Getting that
// wrong leaves listeners attached to a dead room or instance handles pointing
// at state the decoder has already replaced, and neither shows up when a lab
// is exercised on its own.
//
// Needs the playground server:
//   cd demos/prediction-tools && pnpm dev --host 0.0.0.0
import 'dart:io';
import 'dart:ui';

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:colyseus_playground/draw_kit.dart';
import 'package:colyseus_playground/hud.dart';
import 'package:colyseus_playground/kb.dart';
import 'package:colyseus_playground/lab.dart';
import 'package:colyseus_playground/labs/lab00_split.dart';
import 'package:colyseus_playground/labs/lab01_feel_the_lag.dart';
import 'package:colyseus_playground/labs/lab02_clocks.dart';
import 'package:colyseus_playground/labs/lab03_reconcile.dart';
import 'package:colyseus_playground/labs/lab04_interp_modes.dart';
import 'package:colyseus_playground/labs/lab05_dead_reckoning.dart';
import 'package:colyseus_playground/labs/lab06_lag_comp.dart';
import 'package:colyseus_playground/labs/lab07_wysiwyg.dart';
import 'package:colyseus_playground/labs/lab08_optimistic_events.dart';
import 'package:colyseus_playground/labs/lab09_predicted_spawns.dart';
import 'package:colyseus_playground/labs/lab10_composite_sim.dart';
import 'package:colyseus_playground/labs/lab11_deterministic_rng.dart';
import 'package:colyseus_playground/shell.dart';
import 'package:colyseus_playground/world_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<bool> serverUp() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 5173,
        timeout: const Duration(milliseconds: 500));
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

List<Lab> allLabs() => [
      Lab00Split(),
      Lab01FeelTheLag(),
      Lab02Clocks(),
      Lab03Reconcile(),
      Lab04InterpModes(),
      Lab05DeadReckoning(),
      Lab06LagComp(),
      Lab07Wysiwyg(),
      Lab08OptimisticEvents(),
      Lab09PredictedSpawns(),
      Lab10CompositeSim(),
      Lab11DeterministicRng(),
    ];

void main() {
  test('every lab can be switched into and out of', () async {
    if (!await serverUp()) {
      markTestSkipped('playground server is not running on :5173');
      return;
    }

    // A lab that throws while drawing or stepping would otherwise be swallowed
    // by the framework and only show up as a wrong-looking screen.
    final failures = <String>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      failures.add('${details.exception}');
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    final client = ColyseusClient(defaultEndpoint);
    final view = WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600));
    final ctx = LabContext(client: client, view: view);
    Kb.autopilot = true;

    for (final lab in allLabs()) {
      final ok = await lab.mount(ctx);
      expect(ok, isTrue, reason: 'lab ${lab.id} could not join');

      for (var i = 0; i < 45; i++) {
        Colyseus.pump();
        final now = lab.room!.clock.now;
        Kb.autoX = (i ~/ 15) % 2 == 0 ? 1 : -1;
        lab.frame(ctx, now, 16);

        final recorder = PictureRecorder();
        ctx.draw = DrawKit(Canvas(recorder), view);
        ctx.hud = Hud(ctx.draw)..begin(920, 96, 300);
        lab.render(ctx);
        recorder.endRecording().dispose();

        await Future<void>.delayed(const Duration(milliseconds: 16));
      }

      // The shell's teardown, in the same order.
      final room = lab.room!;
      lab.unmount();
      room.setLatency();
      await room.leave();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline) && room.isConnected) {
        Colyseus.pump();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      room.dispose();
      lab.room = null;

      expect(failures, isEmpty,
          reason: 'lab ${lab.id} raised: ${failures.join(" | ")}');
    }

    Kb.autopilot = false;
    client.dispose();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
