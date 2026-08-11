/// The playground's shared simulation, ported to Dart.
///
/// Bit-exact f64 transliteration of `src/shared/*.ts`: same op order, same
/// literals (Dart `double` is f64, like a JS `number`). The server runs the
/// TypeScript original, so steady-state reconcile corrections must sit at wire
/// precision — do not "clean up" a formula here.
///
/// ## State shape
///
/// TypeScript passes structural types (`{ x, y, vx, vy }`), satisfied equally
/// by a server Schema instance and by the reconciler's plain predicted copy.
/// Dart has no structural typing, so each step declares a minimal **abstract
/// interface** ([EntityState], [BotState], [ScorerState], [BumpableState]) with
/// a getter/setter pair per field it touches. A step therefore runs unchanged
/// over:
///
///  * [SimEntity] — the plain, mutable object below (the god-object shape the
///    reckon scratch already has: every field the sim can read, in one place);
///  * an SDK-backed view that forwards `get x` / `set x` into the reconciler's
///    storage, with no copying.
///
/// Interfaces only declare a setter for fields the step actually mutates, so a
/// read-only projection over decoded state is cheap to implement.
library;

import 'dart:math' as math;

import 'bump.dart';
import 'constants.dart';
import 'goal.dart';
import 'hitscan.dart';
import 'hockey.dart';
import 'movement.dart';
import 'movers.dart';
import 'projectile.dart';
import 'random.dart';
import 'spread.dart';

export 'bump.dart';
export 'constants.dart';
export 'goal.dart';
export 'hitscan.dart';
export 'hockey.dart';
export 'movement.dart';
export 'movers.dart';
export 'projectile.dart';
export 'random.dart';
export 'spread.dart';

/// One mutable body that satisfies every step function's interface — players,
/// bots, pucks and projectiles all in one shape, mirroring the reckon scratch
/// (a full copy of the entity, so fields the server never attaches are still
/// readable).
class SimEntity implements BumpableState, ScorerState, BotState {
  @override
  double x;
  @override
  double y;
  @override
  double vx;
  @override
  double vy;

  /// Bump immunity countdown, in fixed steps.
  @override
  int bumpTicks;

  /// Goal re-entry lockout, in fixed steps.
  @override
  int scoreTicks;

  /// Mover behaviour — see [BotKind].
  @override
  String kind;
  @override
  double minX;
  @override
  double maxX;
  @override
  double baseY;
  @override
  double phaseMs;
  @override
  double speed;
  @override
  double lastTeleport;

  SimEntity({
    this.x = 0.0,
    this.y = 0.0,
    this.vx = 0.0,
    this.vy = 0.0,
    this.bumpTicks = 0,
    this.scoreTicks = 0,
    this.kind = '',
    this.minX = 0.0,
    this.maxX = 0.0,
    this.baseY = 0.0,
    this.phaseMs = 0.0,
    this.speed = 0.0,
    this.lastTeleport = 0.0,
  });
}

// ignore: avoid_print
void _emit(String line) => print(line);

/// Cheap check that the port still reproduces the reference numbers (values
/// pinned from running the TypeScript original, cross-checked against the C and
/// GDScript ports). Returns the number of FAILED checks — 0 means the port is
/// still bit-compatible with the server.
///
/// Every check is logged when [log] is supplied; failures are always reported
/// (to [log], or to stdout when none is given).
int selfcheck({void Function(String line)? log}) {
  var failed = 0;

  void check(bool ok, String line) {
    log?.call(line);
    if (ok) return;
    failed++;
    if (log != null) {
      log('    ^ FAIL');
    } else {
      _emit('selfcheck FAIL: $line');
    }
  }

  const dt = 1.0 / tickHz;
  final right = MoveInput(1, 0);
  final idle = MoveInput(0, 0);

  // 5 steps of pure-right acceleration from rest at the arena centre:
  // x 56.7000000000000028422, vx saturated at playerMaxSpeed on step 4.
  final e = SimEntity(x: 50, y: 30);
  for (var i = 0; i < 5; i++) {
    stepEntity(e, right, dt);
  }
  check(
    (e.x - 56.7).abs() < 1e-12 && e.vx == playerMaxSpeed && e.vy == 0.0,
    '  sim: 5x right  -> x=${e.x} vx=${e.vx} (want 56.7 / 34)',
  );

  // Diagonal: the sqrtHalf constant must match Math.SQRT1_2 exactly.
  final d = SimEntity(x: 50, y: 30);
  stepEntity(d, MoveInput(1, 1), dt);
  check(
    d.vx == d.vy && (d.vx - 7.77817459305202341113).abs() < 1e-15,
    '  sim: diagonal  -> vx=${d.vx} vy=${d.vy}',
  );

  // Wall clamp kills the outward velocity component.
  final w = SimEntity(x: playerHalf + 0.1, y: 30, vx: -30);
  stepEntity(w, idle, dt);
  check(
    (w.x - playerHalf).abs() < 1e-12 && w.vx == 0.0,
    '  sim: wall      -> x=${w.x} vx=${w.vx}',
  );

  // Friction deadzone snaps to a hard zero (no denormal drift).
  final f = SimEntity(x: 50, y: 30, vx: 0.06);
  stepEntity(f, idle, dt);
  check(f.vx == 0.0, '  sim: friction  -> vx=${f.vx} (want exactly 0)');

  // The circle's closed form must be evaluable at an arbitrary instant.
  final c = SimEntity(
    x: 50,
    y: 18,
    vx: 18,
    kind: BotKind.circle,
    minX: 22,
    maxX: 78,
    baseY: 18,
    speed: 18,
  );
  stepBot(c, dt, 1234);
  check(
    (c.x - 69.6422100736938887167).abs() < 1e-12 &&
        (c.y - 26.5519448209259039118).abs() < 1e-12,
    '  sim: circle    -> x=${c.x} y=${c.y}',
  );

  // The warp schedule chains within one forward pass.
  final tp = SimEntity(
    x: 70,
    y: 18,
    vx: 18,
    kind: BotKind.teleport,
    minX: 22,
    maxX: 78,
    baseY: 18,
    speed: 18,
    lastTeleport: 1000,
  );
  stepBot(tp, dt, 7100);
  check(
    (tp.x - 70.9).abs() < 1e-12 && tp.lastTeleport == 7000.0,
    '  sim: teleport  -> x=${tp.x} lastTeleport=${tp.lastTeleport}',
  );

  // A projectile wall bounce flips the sign, not the magnitude.
  final pj = SimEntity(x: 99, y: 30, vx: 34);
  stepProjectile(pj, dt);
  check(
    pj.x == arenaW && pj.vx == -34.0,
    '  sim: bounce    -> x=${pj.x} vx=${pj.vx}',
  );

  // The RNG is uint32 integer math — the module that breaks silently if the
  // port gets a shift or a wrap wrong. Compare the INTEGER stream (r * 2^32 is
  // exact) as well as the doubles.
  final rng = mulberry32(0xB07B07);
  final r0 = rng(), r1 = rng(), r2 = rng();
  check(
    (r0 * 4294967296.0).toInt() == 41909008 &&
        (r1 * 4294967296.0).toInt() == 944980053 &&
        (r2 * 4294967296.0).toInt() == 1966572806 &&
        (r0 - 0.00975770130753517150879).abs() < 1e-18 &&
        (r1 - 0.220020313980057835579).abs() < 1e-15 &&
        (r2 - 0.457878412213176488876).abs() < 1e-15 &&
        splitmix32(1) == 1580013426 &&
        shotSeed(7, 12345) == 1994071465,
    '  sim: mulberry  -> $r0 $r1 $r2\n'
    '  sim: seeds     -> splitmix32(1)=${splitmix32(1)} '
    'shotSeed(7,12345)=${shotSeed(7, 12345)}',
  );

  // The shotgun fan rides entirely on that stream.
  final fan = spreadAngles(0.5, 7, 12345);
  check(
    fan.length == pellets &&
        (fan[0] - 0.599485442587174510720).abs() < 1e-15 &&
        (fan[1] - 0.672593814930878552971).abs() < 1e-15,
    '  sim: spread    -> ${fan[0]} ${fan[1]}',
  );

  // A seed that EXCEEDS 2^31 — half of all real shots land in this range, and
  // a signed-32 collapse passes the vectors above while failing here.
  final wide = spreadAngles(0.5, 50, 3004265928);
  check(
    shotSeed(50, 3004265928) == 2712337003 &&
        (wide[0] - 0.558667531493119873254).abs() < 1e-15 &&
        (wide[5] - 0.613833207678981085387).abs() < 1e-15,
    '  sim: wide seed -> shotSeed=${shotSeed(50, 3004265928)} '
    '${wide[0]} ${wide[5]}',
  );

  // Hitscan: a tangent-free hit at t=8, and a clean miss past the radius.
  final tHit = rayCircle(0, 0, 1, 0, 10, 0, 2, 100);
  final tMiss = rayCircle(0, 0, 1, 0, 10, 5, 2, 100);
  check(
    tHit == 8.0 && tMiss == -1.0,
    '  sim: hitscan   -> hit t=$tHit miss t=$tMiss',
  );

  // Puck damping applies BEFORE integration.
  final pk = SimEntity(x: 50, y: 30, vx: 20);
  stepPuck(pk, dt);
  check(
    (pk.x - 50.985).abs() < 1e-12 && (pk.vx - 19.7).abs() < 1e-12,
    '  sim: puck      -> x=${pk.x} vx=${pk.vx}',
  );

  // A contact snaps the puck out to the contact circle.
  final contact = SimEntity(x: 52, y: 30);
  final touched = collidePaddlePuck(SimEntity(x: 50, y: 30, vx: 10), contact);
  check(
    touched && (contact.x - 53.6).abs() < 1e-12 && contact.vx == 17.5,
    '  sim: contact   -> hit=$touched x=${contact.x} vx=${contact.vx}',
  );

  // A paddle squeezing the puck against a wall keeps it INSIDE the arena.
  final pinch = SimEntity(x: 50, y: 59);
  final pinched = collidePaddlePuck(SimEntity(x: 50, y: 58, vy: 20), pinch);
  check(
    pinched &&
        (pinch.y - (arenaH - puckRadius)).abs() < 1e-12 &&
        (pinch.vy + 24.84).abs() < 1e-12,
    '  sim: wall pinch-> y=${pinch.y} vy=${pinch.vy}',
  );

  // The score gate is edge-triggered, then locked out for the cooldown.
  final scorer = SimEntity(x: goalZoneX + 1, y: arenaH / 2);
  final firstGoal = stepScoreGate(scorer);
  final repeatGoal = stepScoreGate(scorer);
  check(
    firstGoal && !repeatGoal && scorer.scoreTicks == scoreCooldownTicks - 1,
    '  sim: goal gate -> edge=$firstGoal repeat=$repeatGoal '
    'ticks=${scorer.scoreTicks}',
  );

  // Bump: a contact inside the radius knocks back along the normal, and an
  // armed cooldown suppresses it entirely.
  final bump = collideBot(SimEntity(x: 50, y: 30), 51, 30);
  final immune = collideBot(SimEntity(x: 50, y: 30, bumpTicks: 1), 51, 30);
  check(
    bump != null && immune == null && bump.vx == -bumpSpeed && bump.vy == 0.0,
    '  sim: bump      -> hit=${bump != null} immune=${immune != null} '
    'vx=${bump?.vx} vy=${bump?.vy}',
  );

  // The bot paddle's steering is a pure function of synced state.
  final steer = MoveInput();
  botInput(SimEntity(x: 50, y: 12), SimEntity(x: 70, y: 20), true, steer);
  final parked = MoveInput();
  botInput(SimEntity(x: 50, y: 12), SimEntity(x: 70, y: 20), false, parked);
  check(
    steer.moveX == 1.0 &&
        steer.moveY == 1.0 &&
        parked.moveX == 0.0 &&
        parked.moveY == 0.0,
    '  sim: bot input -> chase=(${steer.moveX},${steer.moveY}) '
    'park=(${parked.moveX},${parked.moveY})',
  );

  // The unclamped diagonal keeps its magnitude: sqrtHalf is the exact double.
  check(
    (sqrtHalf - math.sqrt1_2).abs() == 0.0,
    '  sim: sqrtHalf  -> $sqrtHalf (dart:math ${math.sqrt1_2})',
  );

  return failed;
}
