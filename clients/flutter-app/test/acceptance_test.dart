// Acceptance checks for the Flutter playground client.
//
// Runs the real app code — real SDK, real dylib, real server — rather than
// widget-testing a mock. Start the playground first:
//
//   cd demos/prediction-tools && pnpm dev --host 0.0.0.0
//   cd clients/flutter-app && ./run-acceptance.sh
//
// The checks mirror the other ports' harnesses (native, GameMaker, godot-gd):
// the shared simulation matches the server, prediction runs ahead of it,
// corrections are absorbed, latency is felt, and a dropped connection
// recovers.

import 'dart:io';

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:colyseus_playground/labs/move_lane.dart';
import 'package:colyseus_playground/net/net_delay.dart';
import 'package:colyseus_playground/shell.dart';
import 'package:colyseus_playground/sim/sim.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives [frames] frames of the real loop.
Future<void> drive(
  MoveLane lane,
  int frames, {
  double moveX = 0,
  double moveY = 0,
}) async {
  for (var i = 0; i < frames; i++) {
    Colyseus.pump();
    lane.drive(lane.room.clock.now, moveX: moveX, moveY: moveY);
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

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
  // The shell turns autoPoll off because its Ticker pumps. These checks
  // exercise the lab code rather than the shell, so the SDK's own timer stays
  // on — otherwise nothing pumps while a join is being awaited and the future
  // never resolves. drive() pumps too; draining twice is harmless.

  // Each check drives a few hundred real frames against a live server, which
  // runs well past the 30 s default.
  const budget = Timeout(Duration(minutes: 2));

  test('1. the shared simulation matches the server', () async {
    {
      expect(selfcheck(), 0,
          reason: 'sim canaries failed — the Dart port has drifted from the '
              'TypeScript the server runs, and every drift reading below '
              'would be measuring that instead of the network');
    }
  }, timeout: budget);

  test('2. joins lab-move and decodes its own player', () async {
    {
      if (!await serverUp()) {
        markTestSkipped('playground server is not running on :5173');
        return;
      }

      final client = ColyseusClient(defaultEndpoint);
      final lane = await MoveLane.mount(client);
      expect(lane, isNotNull, reason: 'could not join lab-move');
      expect(lane!.ready, isTrue, reason: 'the reconciler never bound');
      expect(lane.room.sessionId, isNotEmpty);
      expect(lane.me, isNotNull, reason: 'own player never decoded');

      await close(lane, client);
    }
  }, timeout: budget);

  test('3. prediction runs ahead and stays matched', () async {
    {
      if (!await serverUp()) {
        markTestSkipped('playground server is not running on :5173');
        return;
      }

      final client = ColyseusClient(defaultEndpoint);
      final lane = (await MoveLane.mount(client))!;
      NetDelay.select(0); // no injected latency for the drift check

      final startX = lane.predictedX;
      await drive(lane, 90, moveX: 1);

      expect(lane.predictedX, greaterThan(startX + 5),
          reason: 'prediction never moved');
      expect(lane.reconciler!.reconcileSeq, greaterThan(10),
          reason: 'server acks never drove reconciles');
      expect(lane.drift.ema, lessThan(0.01),
          reason: 'drift ${lane.drift} — the client and server simulations '
              'disagree');
      expect(classifyDrift(lane.drift), DriftStatus.matched);

      await close(lane, client);
    }
  }, timeout: budget);

  test('4. a server impulse registers and decays', () async {
    {
      if (!await serverUp()) {
        markTestSkipped('playground server is not running on :5173');
        return;
      }

      final client = ColyseusClient(defaultEndpoint);
      final lane = (await MoveLane.mount(client))!;
      NetDelay.select(2); // 200 ms, so the impulse lands mid-flight

      await drive(lane, 30, moveX: 1);
      final before = lane.corrections;

      for (var i = 0; i < 4; i++) {
        lane.room.send('impulse');
        await drive(lane, 20, moveX: 1);
      }

      expect(lane.corrections, greaterThan(before),
          reason: 'an unpredicted server impulse should show as a correction');

      // Once the kicks stop, the offset decays back out.
      await drive(lane, 90, moveX: 1);
      expect(lane.reconciler!.lastCorrectionMag, lessThan(5),
          reason: 'corrections never settled');

      NetDelay.select(0);
      await close(lane, client);
    }
  }, timeout: budget);

  test('5. injected latency is visible in the round trip', () async {
    {
      if (!await serverUp()) {
        markTestSkipped('playground server is not running on :5173');
        return;
      }

      final client = ColyseusClient(defaultEndpoint);
      final lane = (await MoveLane.mount(client))!;

      // ping() measures directly. The clock's smoothedRtt is an EMA and needs
      // far longer than this window to converge, so it would report a number
      // between the two and prove nothing.
      NetDelay.select(0);
      await drive(lane, 30, moveX: 1);
      final baseline = await lane.room.ping().timeout(const Duration(seconds: 5));

      NetDelay.select(2); // 200 ms round trip
      await drive(lane, 30, moveX: 1);
      final delayed = await lane.room.ping().timeout(const Duration(seconds: 10));

      expect(delayed, greaterThan(baseline + 150),
          reason: 'baseline ${baseline}ms vs delayed ${delayed}ms');

      // ...and the deeper round trip leaves more inputs unacknowledged.
      await drive(lane, 60, moveX: 1);
      expect(lane.pending, greaterThan(1),
          reason: 'latency should deepen the unacknowledged window');

      NetDelay.select(0);
      await close(lane, client);
    }
  }, timeout: budget);

  test('6. a dropped connection recovers', () async {
    {
      if (!await serverUp()) {
        markTestSkipped('playground server is not running on :5173');
        return;
      }

      final client = ColyseusClient(defaultEndpoint);
      final lane = (await MoveLane.mount(client))!;
      NetDelay.select(0);

      // The defaults wait for 5 s of uptime before retrying.
      lane.room.setReconnectionOptions(
        minUptimeMs: 500,
        minDelayMs: 100,
        maxDelayMs: 500,
      );
      await drive(lane, 60, moveX: 1);

      var dropped = false;
      var reconnected = false;
      lane.room.onDrop.listen((_) => dropped = true);
      lane.room.onReconnect.listen((_) => reconnected = true);

      lane.room.dropConnection();

      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && !reconnected) {
        Colyseus.pump();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }

      expect(dropped, isTrue, reason: 'onDrop never fired');
      expect(reconnected, isTrue, reason: 'the SDK never reconnected');

      // The lane rebuilds its reconciler against the fresh instance, so
      // prediction has to keep working afterwards.
      await drive(lane, 90, moveX: 1);
      expect(lane.ready, isTrue, reason: 'the reconciler never rebound');
      expect(lane.drift.ema, lessThan(0.5),
          reason: 'drift ${lane.drift} after reconnect — stale inputs are '
              'probably replaying into the new connection');

      await close(lane, client);
    }
  }, timeout: budget);
}

/// Leaves and frees, waiting for the socket to close first.
Future<void> close(MoveLane lane, ColyseusClient client) async {
  final room = lane.room;
  lane.dispose();
  room.setLatency();
  await room.leave();

  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline) && room.isConnected) {
    Colyseus.pump();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  await Future<void>.delayed(const Duration(milliseconds: 250));

  room.dispose();
  client.dispose();
}
