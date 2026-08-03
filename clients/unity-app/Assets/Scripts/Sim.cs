using System;

namespace Playground
{
    /// <summary>
    /// The playground's shared simulation, ported to C#.
    ///
    /// Bit-exact double transliteration of the src/shared TypeScript: same op
    /// order, same constants. The server runs the original and this runs on the
    /// client, so steady-state reconcile corrections must stay at wire precision.
    /// (Schema `number` fields are float32 on this SDK, so unlike the C port the
    /// residual here is ~1e-6 rather than exactly zero — see clients/README.)
    /// </summary>
    public static class Sim
    {
        public const int TickHz = 20;
        public const double ArenaW = 100.0;
        public const double ArenaH = 60.0;
        public const double PlayerHalf = 1.6;
        public const double PlayerAccel = 220.0;
        public const double PlayerMaxSpeed = 34.0;
        public const double PlayerFrictionK = 0.72;
        public const double BotRadius = 1.8;
        public const double RemoteInterpMs = 100.0;
        public const double TeleportSnapDist = 8.0;
        /// <summary>Server rewind cap — also what bounds render-time spoofing.</summary>
        public const double MaxRewindMs = 500.0;

        /// <summary>Math.SQRT1_2 — the exact double the JS sim multiplies by.</summary>
        public const double Sqrt1_2 = 0.70710678118654752440;

        public struct Entity { public double x, y, vx, vy; }

        /// <summary>
        /// shared/movement.ts stepEntity — the single deterministic movement step,
        /// run identically by the server (once per received input) and by the
        /// reconciler (predict + rollback replay). sqrt/mul/add only.
        /// </summary>
        public static void StepEntity(ref Entity e, double moveX, double moveY, double dt)
        {
            double ax = moveX, ay = moveY;
            if (ax != 0 && ay != 0) { ax *= Sqrt1_2; ay *= Sqrt1_2; }

            if (ax != 0 || ay != 0)
            {
                e.vx += ax * PlayerAccel * dt;
                e.vy += ay * PlayerAccel * dt;
            }
            else
            {
                e.vx *= PlayerFrictionK;
                e.vy *= PlayerFrictionK;
                if (e.vx > -0.05 && e.vx < 0.05) e.vx = 0;
                if (e.vy > -0.05 && e.vy < 0.05) e.vy = 0;
            }

            double sq = e.vx * e.vx + e.vy * e.vy;
            if (sq > PlayerMaxSpeed * PlayerMaxSpeed)
            {
                double s = PlayerMaxSpeed / Math.Sqrt(sq);
                e.vx *= s; e.vy *= s;
            }

            e.x += e.vx * dt;
            e.y += e.vy * dt;

            double minX = PlayerHalf, maxX = ArenaW - PlayerHalf;
            double minY = PlayerHalf, maxY = ArenaH - PlayerHalf;
            if (e.x < minX) { e.x = minX; if (e.vx < 0) e.vx = 0; }
            else if (e.x > maxX) { e.x = maxX; if (e.vx > 0) e.vx = 0; }
            if (e.y < minY) { e.y = minY; if (e.vy < 0) e.vy = 0; }
            else if (e.y > maxY) { e.y = maxY; if (e.vy > 0) e.vy = 0; }
        }

        // ------------------------------------------------------ shared/goal.ts

        /// <summary>The goal zone: a strip on the right edge of the arena.</summary>
        public const double GoalZoneX = ArenaW - 8.0;
        public const double GoalZoneY = ArenaH / 2.0 - 9.0;
        public const double GoalZoneW = 8.0;
        public const double GoalZoneH = 18.0;
        /// <summary>Re-entry lockout, in fixed steps — reconciled tick state.</summary>
        public const int ScoreCooldownTicks = 50;

        /// <summary>
        /// shared/goal.ts stepScoreGate. A pure function of predicted state, so it
        /// is deterministic under rollback replay: true on the entry EDGE, the step
        /// that crossed into the zone with the gate open. Whether the goal is
        /// AWARDED stays server-only — the gate itself never mispredicts.
        /// </summary>
        public static bool StepScoreGate(double x, double y, ref int scoreTicks)
        {
            if (scoreTicks > 0) { scoreTicks--; return false; }
            if (x >= GoalZoneX && y >= GoalZoneY && y <= GoalZoneY + GoalZoneH)
            {
                scoreTicks = ScoreCooldownTicks;
                return true;
            }
            return false;
        }

        // ------------------------------------------------ shared/projectile.ts

        public const double ProjectileSpeed = 34.0;
        public const double ProjectileRadius = 0.7;
        public const double ProjectileTtlMs = 2600.0;

        /// <summary>Constant-velocity flight with wall bounces.</summary>
        public static void StepProjectile(ref Entity p, double dt)
        {
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            if (p.x < 0) { p.x = 0; p.vx = Math.Abs(p.vx); }
            else if (p.x > ArenaW) { p.x = ArenaW; p.vx = -Math.Abs(p.vx); }
            if (p.y < 0) { p.y = 0; p.vy = Math.Abs(p.vy); }
            else if (p.y > ArenaH) { p.y = ArenaH; p.vy = -Math.Abs(p.vy); }
        }

        // ---------------------------------------------------- shared/movers.ts

        /// <summary>Teleporter warp period, on the shared server-clock timeline.</summary>
        public const double TeleportPeriodMs = 3000.0;
        /// <summary>How often wander bots pick a new (server-secret) heading.</summary>
        public const double WanderTurnMs = 900.0;

        /// <summary>
        /// Structural bot state. The reckon scratch is a full copy of the entity,
        /// so fields the client never attached (kind, minX, ...) are readable here.
        /// </summary>
        public struct BotState
        {
            public double x, y, vx, vy;
            public string kind;
            public double minX, maxX, baseY, phaseMs, speed, lastTeleport;
        }

        /// <summary>Horizontal ping-pong between minX and maxX at |vx| = speed.</summary>
        private static void Patrol(ref BotState b, double dt)
        {
            b.x += b.vx * dt;
            b.y = b.baseY;
            if (b.x < b.minX) { b.x = b.minX; b.vx = Math.Abs(b.vx); }
            else if (b.x > b.maxX) { b.x = b.maxX; b.vx = -Math.Abs(b.vx); }
        }

        /// <summary>
        /// shared/movers.ts stepBot — run by the server each fixed tick AND by the
        /// client's reckon mode to forward-simulate from the latest snapshot to the
        /// present. <paramref name="elapsedMs"/> is the shared server-clock
        /// timeline, which is what makes time-sampled motion (the circle's closed
        /// form, the teleport schedule) evaluable at ANY instant.
        ///
        /// "wander" is deliberately only PARTLY predictable: it integrates
        /// velocity, but the heading changes are a server-side secret, so reckon
        /// extrapolates straight through every turn and gets corrected. That error
        /// is the lesson, not a bug.
        /// </summary>
        public static void StepBot(ref BotState b, double dt, double elapsedMs)
        {
            switch (b.kind)
            {
                case "circle":
                {
                    double cx = (b.minX + b.maxX) / 2;
                    double rx = (b.maxX - b.minX) / 2;
                    double ry = Math.Min(12.0, ArenaH / 2 - BotRadius - 2);
                    double w = b.speed / rx;                      // rad/s
                    double t = (elapsedMs + b.phaseMs) / 1000.0;
                    b.x = cx + rx * Math.Cos(w * t);
                    b.y = b.baseY + ry * Math.Sin(w * t);
                    b.vx = -rx * w * Math.Sin(w * t);
                    b.vy = ry * w * Math.Cos(w * t);
                    return;
                }
                case "teleport":
                {
                    Patrol(ref b, dt);
                    // Predict the warp from the synced schedule: jump half the
                    // patrol span (wrapping) every period — a constant, visible cut.
                    while (b.lastTeleport > 0 && elapsedMs - b.lastTeleport >= TeleportPeriodMs)
                    {
                        double span = b.maxX - b.minX;
                        b.x = b.minX + ((b.x - b.minX) + span / 2) % span;
                        b.lastTeleport += TeleportPeriodMs;
                    }
                    return;
                }
                case "wander":
                {
                    b.x += b.vx * dt;
                    b.y += b.vy * dt;
                    double min = BotRadius, maxX = ArenaW - BotRadius, maxY = ArenaH - BotRadius;
                    if (b.x < min) { b.x = min; b.vx = Math.Abs(b.vx); }
                    else if (b.x > maxX) { b.x = maxX; b.vx = -Math.Abs(b.vx); }
                    if (b.y < min) { b.y = min; b.vy = Math.Abs(b.vy); }
                    else if (b.y > maxY) { b.y = maxY; b.vy = -Math.Abs(b.vy); }
                    return;
                }
                default:
                    Patrol(ref b, dt);
                    return;
            }
        }

        // --------------------------------------------------- shared/hitscan.ts

        /// <summary>
        /// 2D hitscan: ray vs circle. Returns the ray parameter t (distance along
        /// the unit direction) of the nearest intersection, or -1 on a miss. Pure
        /// math, shared so the client's shot preview and the server's resolution
        /// cannot drift.
        /// </summary>
        public static double RayCircle(double ox, double oy, double dx, double dy,
            double cx, double cy, double r, double maxDist)
        {
            double mx = ox - cx, my = oy - cy;
            double b = mx * dx + my * dy;
            double c = mx * mx + my * my - r * r;
            if (c > 0 && b > 0) return -1;              // outside, pointing away
            double disc = b * b - c;
            if (disc < 0) return -1;
            double t = -b - Math.Sqrt(disc);
            double hit = t < 0 ? 0 : t;                 // inside the circle = t 0
            return hit <= maxDist ? hit : -1;
        }

        // ------------------------------------------------------ shared/bump.ts

        /// <summary>
        /// Post-bump immunity, in fixed steps — a RECONCILED tick gate: both sides
        /// run the identical countdown, so "can I be bumped?" never mispredicts.
        /// </summary>
        public const int BumpCooldownTicks = 12;
        public const double BumpSpeed = 48.0;

        /// <summary>Cooldown countdown — run BEFORE the movement step on both sides.</summary>
        public static void StepBumpGate(ref int bumpTicks)
        {
            if (bumpTicks > 0) bumpTicks--;
        }

        /// <summary>
        /// Player-vs-bot bump test at an agreed bot position. Writes the knockback
        /// velocity and returns true on a hit. The CALLER applies it and re-arms
        /// bumpTicks — on the client that happens inside the reconciler step, so
        /// the whole outcome (velocity + immunity window) rides adopt+replay.
        /// </summary>
        public static bool CollideBot(double px, double py, int bumpTicks,
            double botX, double botY, out double vx, out double vy)
        {
            vx = vy = 0;
            if (bumpTicks > 0) return false;
            double dx = px - botX, dy = py - botY;
            double r = PlayerHalf + BotRadius;
            double d2 = dx * dx + dy * dy;
            if (d2 >= r * r) return false;
            double d = Math.Sqrt(d2);
            if (d == 0) d = 1e-6;
            vx = dx / d * BumpSpeed;
            vy = dy / d * BumpSpeed;
            return true;
        }

        // ---------------------------------------------------- shared/random.ts

        /// <summary>
        /// splitmix32 — one-shot avalanche of a 32-bit seed into a well-mixed word.
        /// uint throughout, matching the JS `| 0` / `&gt;&gt;&gt; 0` / Math.imul
        /// semantics exactly.
        /// </summary>
        public static uint Splitmix32(uint a)
        {
            unchecked
            {
                a += 0x9e3779b9u;
                uint t = a ^ (a >> 16);
                t *= 0x21f0aaadu;
                t ^= t >> 15;
                t *= 0x735a2d97u;
                return t ^ (t >> 15);
            }
        }

        /// <summary>
        /// mulberry32 — the tiny seeded PRNG both sides roll. A struct so a stream
        /// is a value you can hold and advance, without a closure per shot.
        /// </summary>
        public struct Rng
        {
            private uint _state;

            public Rng(uint seed) { _state = seed; }

            /// <summary>Advance the stream and return the next value in [0,1).</summary>
            public double Next()
            {
                unchecked
                {
                    _state += 0x6d2b79f5u;
                    uint a = _state;
                    uint t = (a ^ (a >> 15)) * (1u | a);
                    t = (t + ((t ^ (t >> 7)) * (61u | t))) ^ t;
                    return (t ^ (t >> 14)) / 4294967296.0;
                }
            }
        }

        /// <summary>Per-shot seed from the input sequence + a synced per-round salt.</summary>
        public static uint ShotSeed(int seq, uint salt)
        {
            unchecked { return Splitmix32((uint)seq ^ (salt * 0x85ebca6bu)); }
        }

        // ---------------------------------------------------- shared/spread.ts

        public const int Pellets = 6;
        public const double SpreadRad = 0.38;

        /// <summary>
        /// The shotgun fan — the SAME derivation on both sides, with nothing random
        /// on the wire: the seed is (input seq, synced per-room salt), so client and
        /// server roll identical pellets for the same shot.
        /// </summary>
        public static void SpreadAngles(double baseAngle, int seq, uint salt, double[] outAngles)
        {
            var rng = new Rng(ShotSeed(seq, salt));
            for (int i = 0; i < Pellets; i++)
                outAngles[i] = baseAngle + (rng.Next() - 0.5) * SpreadRad;
        }

        // ---------------------------------------------------- shared/hockey.ts

        public const double PaddleRadius = 2.2;
        public const double PuckRadius = 1.4;
        /// <summary>Per-tick puck damping — dt is fixed, so this is a literal.</summary>
        public const double PuckFrictionK = 0.985;
        public const double PuckRestitution = 0.92;
        public const double PuckPushMin = 14.0;

        /// <summary>Puck free flight: bleed speed, integrate, bounce off the walls.</summary>
        public static void StepPuck(ref Entity p, double dt)
        {
            p.vx *= PuckFrictionK;
            p.vy *= PuckFrictionK;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            double min = PuckRadius, maxX = ArenaW - PuckRadius, maxY = ArenaH - PuckRadius;
            if (p.x < min) { p.x = min; p.vx = Math.Abs(p.vx) * PuckRestitution; }
            else if (p.x > maxX) { p.x = maxX; p.vx = -Math.Abs(p.vx) * PuckRestitution; }
            if (p.y < min) { p.y = min; p.vy = Math.Abs(p.vy) * PuckRestitution; }
            else if (p.y > maxY) { p.y = maxY; p.vy = -Math.Abs(p.vy) * PuckRestitution; }
        }

        /// <summary>
        /// Paddle↔puck contact: push the puck out of penetration along the contact
        /// normal and give it the paddle's velocity plus a minimum separation
        /// speed. The push-out then resolves against the arena walls (same rule
        /// as StepPuck), so a puck squeezed between a paddle and a wall stays
        /// inside the arena instead of being ejected past it.
        /// Deterministic (sqrt/mul/add only) and ORDER-DEPENDENT — both
        /// sides must resolve paddles in the same order, which is the players-map
        /// iteration order.
        /// </summary>
        public static bool CollidePaddlePuck(double paddleX, double paddleY,
            double paddleVx, double paddleVy, ref Entity puck)
        {
            double dx = puck.x - paddleX, dy = puck.y - paddleY;
            double r = PaddleRadius + PuckRadius;
            double d2 = dx * dx + dy * dy;
            if (d2 >= r * r) return false;
            double d = Math.Sqrt(d2);
            if (d == 0) d = 1e-6;
            double nx = dx / d, ny = dy / d;
            puck.x = paddleX + nx * r;
            puck.y = paddleY + ny * r;
            double paddleAlong = paddleVx * nx + paddleVy * ny;
            double speed = paddleAlong > PuckPushMin ? paddleAlong : PuckPushMin;
            puck.vx = nx * speed + paddleVx * 0.35;
            puck.vy = ny * speed + paddleVy * 0.35;
            double min = PuckRadius, maxX = ArenaW - PuckRadius, maxY = ArenaH - PuckRadius;
            if (puck.x < min) { puck.x = min; puck.vx = Math.Abs(puck.vx) * PuckRestitution; }
            else if (puck.x > maxX) { puck.x = maxX; puck.vx = -Math.Abs(puck.vx) * PuckRestitution; }
            if (puck.y < min) { puck.y = min; puck.vy = Math.Abs(puck.vy) * PuckRestitution; }
            else if (puck.y > maxY) { puck.y = maxY; puck.vy = -Math.Abs(puck.vy) * PuckRestitution; }
            return true;
        }

        /// <summary>Session id of the server-driven AI paddle in lab-hockey.</summary>
        public const string BotId = "bot";

        /// <summary>
        /// The AI paddle's steering, quantized to the same -1/0/1 move input a
        /// human sends. A server-owned DECISION but a pure function of synced
        /// state — the puck it chases and <c>botEnabled</c> — so a predicting
        /// client derives it exactly: the bot is remote but NOT unpredictable.
        /// Port of shared/hockey.ts <c>botInput</c>.
        /// </summary>
        public static void BotInput(double botX, double botY,
            double puckX, double puckY, bool enabled, out int moveX, out int moveY)
        {
            bool chase = enabled && puckY < ArenaH / 2;
            double tx = chase ? puckX : ArenaW / 2;
            double ty = chase ? puckY : ArenaH * 0.2;
            moveX = tx - botX > 1 ? 1 : tx - botX < -1 ? -1 : 0;
            moveY = ty - botY > 1 ? 1 : ty - botY < -1 ? -1 : 0;
        }

        /// <summary>
        /// Cheap check that the port still reproduces the reference numbers
        /// (values pinned from running the TypeScript original). Returns the
        /// number of FAILED checks.
        /// </summary>
        public static int SelfCheck(Action<string> log = null)
        {
            int failed = 0;
            const double dt = 1.0 / TickHz;

            var e = new Entity { x = 50, y = 30 };
            for (int i = 0; i < 5; i++) StepEntity(ref e, 1, 0, dt);
            bool ok = Math.Abs(e.x - 56.7) < 1e-12 && e.vx == PlayerMaxSpeed;
            log?.Invoke($"  sim: 5x right  -> x={e.x:R} vx={e.vx:R} (want 56.7 / 34)");
            if (!ok) failed++;

            var d = new Entity { x = 50, y = 30 };
            StepEntity(ref d, 1, 1, dt);
            ok = d.vx == d.vy && Math.Abs(d.vx - 7.77817459305202341113) < 1e-15;
            log?.Invoke($"  sim: diagonal  -> vx={d.vx:R} vy={d.vy:R}");
            if (!ok) failed++;

            var w = new Entity { x = PlayerHalf + 0.1, y = 30, vx = -30 };
            StepEntity(ref w, 0, 0, dt);
            ok = Math.Abs(w.x - PlayerHalf) < 1e-12 && w.vx == 0;
            log?.Invoke($"  sim: wall      -> x={w.x:R} vx={w.vx:R}");
            if (!ok) failed++;

            var f = new Entity { x = 50, y = 30, vx = 0.06 };
            StepEntity(ref f, 0, 0, dt);
            ok = f.vx == 0;
            log?.Invoke($"  sim: friction  -> vx={f.vx:R} (want exactly 0)");
            if (!ok) failed++;

            // The circle's closed form must be evaluable at an arbitrary instant.
            var c = new BotState
            {
                x = 50, y = 18, vx = 18, kind = "circle",
                minX = 22, maxX = 78, baseY = 18, speed = 18,
            };
            StepBot(ref c, dt, 1234);
            ok = Math.Abs(c.x - 69.6422100736938887167) < 1e-12
              && Math.Abs(c.y - 26.5519448209259039118) < 1e-12;
            log?.Invoke($"  sim: circle    -> x={c.x:R} y={c.y:R}");
            if (!ok) failed++;

            // The warp schedule chains within one forward pass.
            var tp = new BotState
            {
                x = 70, y = 18, vx = 18, kind = "teleport",
                minX = 22, maxX = 78, baseY = 18, speed = 18, lastTeleport = 1000,
            };
            StepBot(ref tp, dt, 7100);
            ok = Math.Abs(tp.x - 70.9) < 1e-12 && tp.lastTeleport == 7000;
            log?.Invoke($"  sim: teleport  -> x={tp.x:R} lastTeleport={tp.lastTeleport:R}");
            if (!ok) failed++;

            // A projectile wall bounce flips the sign, not the magnitude.
            var pj = new Entity { x = 99, y = 30, vx = 34 };
            StepProjectile(ref pj, dt);
            ok = pj.x == ArenaW && pj.vx == -34.0;
            log?.Invoke($"  sim: bounce    -> x={pj.x:R} vx={pj.vx:R}");
            if (!ok) failed++;

            // The RNG is the one module that is NOT a straight double
            // transliteration — uint32 integer math, so it is the one that breaks
            // silently if the port gets a shift or a wrap wrong.
            var rng = new Rng(0xB07B07u);
            double r0 = rng.Next(), r1 = rng.Next(), r2 = rng.Next();
            ok = Math.Abs(r0 - 0.00975770130753517150879) < 1e-18
              && Math.Abs(r1 - 0.220020313980057835579) < 1e-15
              && Math.Abs(r2 - 0.457878412213176488876) < 1e-15
              && Splitmix32(1) == 1580013426u
              && ShotSeed(7, 12345) == 1994071465u;
            log?.Invoke($"  sim: mulberry  -> {r0:R} {r1:R} {r2:R}");
            log?.Invoke($"  sim: seeds     -> splitmix32(1)={Splitmix32(1)} shotSeed(7,12345)={ShotSeed(7, 12345)}");
            if (!ok) failed++;

            // The shotgun fan rides entirely on that stream.
            var fan = new double[Pellets];
            SpreadAngles(0.5, 7, 12345, fan);
            ok = Math.Abs(fan[0] - 0.599485442587174510720) < 1e-15
              && Math.Abs(fan[1] - 0.672593814930878552971) < 1e-15;
            log?.Invoke($"  sim: spread    -> {fan[0]:R} {fan[1]:R}");
            if (!ok) failed++;

            // A seed that EXCEEDS 2^31. Both vectors above stay under it, so
            // between them they only exercise the half of the input space where
            // a 32-bit seed still fits a signed int — the Haxe port shipped a
            // collapse in the other half and this canary passed anyway.
            // ShotSeed(50, 3004265928) is 2712337003, and the room salts the
            // server rolls are uniform over the full u32 range, so half of all
            // real shots land here.
            var wide = new double[Pellets];
            SpreadAngles(0.5, 50, 3004265928u, wide);
            ok = ShotSeed(50, 3004265928u) == 2712337003u
              && Math.Abs(wide[0] - 0.558667531493119873254) < 1e-15
              && Math.Abs(wide[5] - 0.613833207678981085387) < 1e-15;
            log?.Invoke($"  sim: wide seed -> shotSeed={ShotSeed(50, 3004265928u)} {wide[0]:R} {wide[5]:R}");
            if (!ok) failed++;

            // Hitscan: a tangent-free hit at t=8, and a clean miss past the radius.
            double tHit = RayCircle(0, 0, 1, 0, 10, 0, 2, 100);
            double tMiss = RayCircle(0, 0, 1, 0, 10, 5, 2, 100);
            ok = tHit == 8.0 && tMiss == -1;
            log?.Invoke($"  sim: hitscan   -> hit t={tHit:R} miss t={tMiss:R}");
            if (!ok) failed++;

            // Puck damping applies BEFORE integration.
            var pk = new Entity { x = 50, y = 30, vx = 20 };
            StepPuck(ref pk, dt);
            ok = Math.Abs(pk.x - 50.985) < 1e-12 && Math.Abs(pk.vx - 19.7) < 1e-12;
            log?.Invoke($"  sim: puck      -> x={pk.x:R} vx={pk.vx:R}");
            if (!ok) failed++;

            // A contact snaps the puck out to the contact circle.
            var contact = new Entity { x = 52, y = 30 };
            bool touched = CollidePaddlePuck(50, 30, 10, 0, ref contact);
            ok = touched && Math.Abs(contact.x - 53.6) < 1e-12 && contact.vx == 17.5;
            log?.Invoke($"  sim: contact   -> hit={touched} x={contact.x:R} vx={contact.vx:R}");
            if (!ok) failed++;

            // A paddle squeezing the puck against a wall keeps it INSIDE the arena.
            var pinch = new Entity { x = 50, y = 59 };
            bool pinched = CollidePaddlePuck(50, 58, 0, 20, ref pinch);
            ok = pinched && Math.Abs(pinch.y - (ArenaH - PuckRadius)) < 1e-12
                && Math.Abs(pinch.vy + 24.84) < 1e-12;
            log?.Invoke($"  sim: wall pinch-> y={pinch.y:R} vy={pinch.vy:R}");
            if (!ok) failed++;

            // The score gate is edge-triggered, then locked out for the cooldown.
            int ticks = 0;
            bool first = StepScoreGate(GoalZoneX + 1, ArenaH / 2, ref ticks);
            bool second = StepScoreGate(GoalZoneX + 1, ArenaH / 2, ref ticks);
            ok = first && !second && ticks == ScoreCooldownTicks - 1;
            log?.Invoke($"  sim: goal gate -> edge={first} repeat={second} ticks={ticks}");
            if (!ok) failed++;

            // Bump: a contact inside the radius knocks back along the normal, and
            // an armed cooldown suppresses it entirely.
            bool bumped = CollideBot(50, 30, 0, 51, 30, out double bvx, out double bvy);
            bool immune = CollideBot(50, 30, 1, 51, 30, out _, out _);
            ok = bumped && !immune && bvx == -BumpSpeed && bvy == 0;
            log?.Invoke($"  sim: bump      -> hit={bumped} immune={immune} vx={bvx:R} vy={bvy:R}");
            if (!ok) failed++;

            return failed;
        }
    }
}
