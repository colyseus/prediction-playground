// Lab 00 mounts, drives real frames against the live server, and renders.
//
// Separate from lab_smoke_test.dart only because this lab draws two lanes
// through their own DrawKits, which is worth exercising on its own.
//
// Needs the playground server:
//   cd demos/prediction-tools && pnpm dev --host 0.0.0.0
import 'dart:io';
import 'dart:ui';

import 'package:colyseus/colyseus.dart';
import 'package:colyseus_playground/draw_kit.dart';
import 'package:colyseus_playground/hud.dart';
import 'package:colyseus_playground/lab.dart';
import 'package:colyseus_playground/labs/lab00_split.dart';
import 'package:colyseus_playground/shell.dart';
import 'package:colyseus_playground/world_view.dart';
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

void main() {
  test('00 splits the lanes and both keep moving', () async {
    if (!await serverUp()) {
      markTestSkipped('playground server is not running on :5173');
      return;
    }

    final client = ColyseusClient(defaultEndpoint);
    final lab = Lab00Split();
    final view = WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600));
    final ctx = LabContext(client: client, view: view);

    expect(await lab.mount(ctx), isTrue, reason: 'lab 00 could not join');

    var echoMoved = false;
    var predictedMoved = false;
    final startEcho = lab.lane!.serverX;
    final startPredicted = lab.lane!.predictedX;

    for (var i = 0; i < 240; i++) {
      Colyseus.pump();
      final now = lab.room!.clock.now;
      lab.frame(ctx, now, 16);

      // Render every frame: painting is where a lane's transform goes wrong.
      final recorder = PictureRecorder();
      ctx.draw = DrawKit(Canvas(recorder), view);
      ctx.hud = Hud(ctx.draw)..begin(920, 96, 300);
      lab.render(ctx);
      recorder.endRecording().dispose();

      if ((lab.lane!.serverX - startEcho).abs() > 1) echoMoved = true;
      if ((lab.lane!.predictedX - startPredicted).abs() > 1) {
        predictedMoved = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    // The autopilot drives, so both lanes must travel.
    expect(predictedMoved, isTrue, reason: 'the predicted lane never moved');
    expect(echoMoved, isTrue, reason: 'the server echo lane never moved');
    expect(lab.lane!.reconciler!.reconcileSeq, greaterThan(5),
        reason: 'server acks never drove a reconcile');

    final room = lab.room!;
    lab.unmount();
    room.setLatency();
    await room.leave();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Colyseus.pump();
    room.dispose();
    client.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
