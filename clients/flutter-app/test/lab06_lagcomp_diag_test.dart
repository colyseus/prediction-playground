// Does the server's rewind land where the client's screen was?
//
// It has to, or shots at a target's trailing edge read as a hit here and a
// miss there — the bot radius is 1.8 u, so a gap approaching that flips the
// verdict. The aim below is deliberately the tail, not the centre: a centre
// shot forgives a rewind error that a player would still notice.
//
// This used to fail by 0.6 to 2.4 u, and the cause was not the stamp. The
// injector applied its delay to EACH direction while the JS SDK's __net()
// splits one round trip across both, so the "200 ms" preset ran at an RTT
// near 500. The rewind depth that needs (renderDelay + RTT + a tick) is past
// the room's maxRewindMs of 500, and the server clamps — landing about a unit
// ahead of the drawn pose. With the injector aligned (src/network/net_delay.c
// in the native SDK), the stamp error measures -0.2 ms and the rewind lands
// within 0.01 u, matching the web client against the same server.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:colyseus/colyseus.dart';
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

    // What the web client achieves against this same server.
    expect(worstGap, lessThan(0.1),
        reason: 'the rewind lands ${worstGap.toStringAsFixed(2)} u from the '
            'drawn pose; the web client reaches 0.01 u');
    expect(clientHitServerMiss, 0,
        reason: 'edge shots disagree: $clientHitServerMiss of '
            '${answered.length}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
