// Diagnostic: does the server's rewind land where the client's screen was?
//
// Lab 06's claim is that shooting at what you see hits it. That only holds if
// the pose the server rewinds a target to matches the pose the client drew.
//
// It does not, quite. Measured against the live server, the rewound pose sits
// consistently AHEAD of the drawn pose along the target's travel, by roughly
// one 50 ms server tick — about 1 world unit at the bot's 22 u/s. The target
// radius is 1.8, so a centre shot is unaffected and a trailing-edge shot
// flips from hit to miss.
//
// Ruled out by measurement, not argument:
//   - the stamp's rtt/2 term: the implied offset is ~50 ms against a half-RTT
//     of ~250 ms;
//   - clock slew between serverNow and renderNow: measured at ~0 ms.
//
// What is left is snapshot granularity. The server's rewind buffer holds one
// pose per tick, so it cannot resolve finer than a tick, and it lands on the
// far side. The client's optimistic ray test uses the continuously
// interpolated pose, which is finer than anything the server can answer with.
//
// This test is a regression guard on that bias, not a passing grade.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:colyseus_playground/controls.dart';
import 'package:colyseus_playground/draw_kit.dart';
import 'package:colyseus_playground/hud.dart';
import 'package:colyseus_playground/kb.dart';
import 'package:colyseus_playground/sim/sim.dart';
import 'package:colyseus_playground/lab.dart';
import 'package:colyseus_playground/labs/lab06_lag_comp.dart';
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
  test('the server rewinds to the pose the client drew', () async {
    if (!await serverUp()) {
      markTestSkipped('playground server is not running on :5173');
      return;
    }

    final client = ColyseusClient(defaultEndpoint);
    final lab = Lab06LagComp();
    final view = WorldView()..fit(const Rect.fromLTWH(0, 64, 900, 600));
    final ctx = LabContext(client: client, view: view);

    expect(await lab.mount(ctx), isTrue);
    var botSpeed = 0.0;
    // The lerp draws on the renderNow axis; the input stamp is computed from
    // serverNow. Any gap between those two is lag-comp error by construction.
    var slewSum = 0.0;
    var slewSamples = 0;
    // Aim at the bot's TRAILING edge, not its centre. A centre shot is
    // forgiving of a small rewind error; the tail is where half a radius of
    // disagreement flips hit into miss, which is what a player reports.
    Kb.autopilot = false;
    final fire = lab
        .controls(ctx)
        .whereType<ButtonsSpec>()
        .first
        .buttons
        .first
        .onPressed;

    for (var i = 0; i < 400; i++) {
      Colyseus.pump();
      lab.frame(ctx, lab.room!.clock.now, 16);

      final recorder = PictureRecorder();
      ctx.draw = DrawKit(Canvas(recorder), view);
      ctx.hud = Hud(ctx.draw)..begin(920, 96, 300);
      lab.render(ctx);
      recorder.endRecording().dispose();

      // Point the mouse at the trailing edge of the bot as this screen draws
      // it, then fire through the same path a click takes.
      final target = lab.lane!.bot;
      if (target != null) {
        final sp = math.sqrt(
          math.pow((target['vx'] as num?)?.toDouble() ?? 0, 2) +
              math.pow((target['vy'] as num?)?.toDouble() ?? 0, 2),
        );
        if (sp > botSpeed) botSpeed = sp;
        final vx = (target['vx'] as num?)?.toDouble() ?? 0;
        final vy = (target['vy'] as num?)?.toDouble() ?? 0;
        final speed = math.sqrt(vx * vx + vy * vy);
        final bx = lab.lane!.botX;
        final by = lab.lane!.botY;
        final tailX = speed > 1e-6 ? bx - (vx / speed) * botRadius * 0.75 : bx;
        final tailY = speed > 1e-6 ? by - (vy / speed) * botRadius * 0.75 : by;
        Kb.mousePos = Offset(view.sx(tailX), view.sy(tailY));
      }

      if (i > 60) {
        slewSum += lab.room!.clock.serverNow - lab.room!.clock.renderNow;
        slewSamples++;
      }
      if (i > 60 && i % 12 == 0) fire();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    final answered = lab.answeredShots;
    expect(answered, isNotEmpty, reason: 'the server never answered a shot');

    // Blue to green: what the screen drew vs where the server rewound to.
    // These should sit on top of each other; the bot radius is 1.8, so
    // anything approaching that flips edge shots.
    var worstGap = 0.0;
    var totalGap = 0.0;
    // Signed along the bot's travel: consistently negative means the server
    // rewinds further back than the screen drew (a bias); alternating signs
    // mean the rewind is landing on tick boundaries (quantisation).
    final signed = <double>[];
    var agree = 0;
    var clientHitServerMiss = 0;
    var clientMissServerHit = 0;

    for (final shot in answered) {
      final gap = math.sqrt(
        math.pow(shot.rewoundX - shot.drewX, 2) +
            math.pow(shot.rewoundY - shot.drewY, 2),
      );
      totalGap += gap;
      if (gap > worstGap) worstGap = gap;
      signed.add(shot.aheadOfDrawn);

      if (shot.predictedHit == shot.serverHit) {
        agree++;
      } else if (shot.predictedHit) {
        clientHitServerMiss++;
      } else {
        clientMissServerHit++;
      }
    }

    // ignore: avoid_print
    print('LAB06DIAG answered=${answered.length} '
        'meanGap=${(totalGap / answered.length).toStringAsFixed(3)} '
        'worstGap=${worstGap.toStringAsFixed(3)} '
        'agree=$agree clientHitServerMiss=$clientHitServerMiss '
        'clientMissServerHit=$clientMissServerHit '
        'renderDelay=${lab.lane!.renderDelay} '
        'rtt=${lab.room!.clock.smoothedRtt.round()} '
        'botSpeed=${botSpeed.toStringAsFixed(1)} '
        // gap / speed is the time offset the rewind is out by. Compare it to
        // half the round trip, which is the term the stamp subtracts on top
        // of the render delay.
        'impliedOffsetMs=${botSpeed > 0 ? ((totalGap / answered.length) / botSpeed * 1000).round() : -1} '
        'halfRtt=${(lab.room!.clock.smoothedRtt / 2).round()} '
        'signed=${signed.map((v) => v.toStringAsFixed(2)).join(",")} '
        'meanSlewMs=${slewSamples > 0 ? (slewSum / slewSamples).toStringAsFixed(1) : "-"}');

    final room = lab.room!;
    lab.unmount();
    Kb.autopilot = false;
    room.setLatency();
    await room.leave();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Colyseus.pump();
    room.dispose();
    client.dispose();

    // One tick of the bot's travel is the expected ceiling. Beyond that,
    // something worse than snapshot granularity has crept in.
    final tickTravel = botSpeed * (1000 / tickHz) / 1000;
    expect(worstGap, lessThan(tickTravel * 1.5),
        reason: 'the rewind is out by more than a tick of travel '
            '(${worstGap.toStringAsFixed(2)} u vs a tick of '
            '${tickTravel.toStringAsFixed(2)} u), which is worse than '
            'snapshot granularity explains');

    // The bias has a direction: the server places the target further along
    // its path than the screen showed. If this ever flips, the rewind model
    // has changed and the lab's framing needs revisiting.
    final forward = signed.where((v) => v > 0).length;
    expect(forward, signed.length,
        reason: 'the rewind bias changed direction: $signed');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
