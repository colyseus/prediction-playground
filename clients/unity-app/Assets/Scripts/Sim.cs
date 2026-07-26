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

            return failed;
        }
    }
}
