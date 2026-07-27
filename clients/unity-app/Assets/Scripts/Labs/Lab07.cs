using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 07 — WYSIWYG Collision.
    ///
    /// The collision against the moving bot is predicted INSIDE the reconciler
    /// step. Two ingredients make the client's verdict equal the server's:
    ///
    ///  1. ValueAt(bot, "x", ctx.ReckonTime) — read the bot at the instant the
    ///     server will REWIND this input to. Reading anything else (the stale
    ///     snapshot, or the smoothed render pose) tests against a position the
    ///     server never uses.
    ///
    ///  2. ctx.Memo(...) — the verdict is NOT re-derivable on rollback replay
    ///     (the client keeps no bot history; a later replay would read the bot
    ///     reckoned from a NEWER snapshot and could flip the call). Memo runs the
    ///     test once on the live step and replays the outcome verbatim.
    ///
    /// The verdict is a VECTOR (the knockback vx/vy) memoized as one value, so
    /// both components replay together. Encoding it as an angle would round
    /// through atan2/cos and reintroduce the drift this lab exists to eliminate.
    /// Port of labs/07-wysiwyg/.
    /// </summary>
    public class Lab07 : LabBase<Lab.BumpState>
    {
        public override string Id => "07-wysiwyg";
        public override int Num => 7;
        public override string Title => "WYSIWYG Collision";
        public override string Blurb => "ValueAt(reckonTime) + ctx.Memo.";

        /// <summary>The memoized verdict: did we bump, and with what knockback.</summary>
        private struct Knock { public bool Hit; public double Vx, Vy; }

        private Predict _predict;
        private Reconciler<Lab.BumpPlayer, Lab.MoveInput> _recon;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Lab.BumpPlayer _me;
        private Lab.Bot _bot;
        private string _sid;

        private bool _useValueAt = true, _useMemo = true;
        private int _bumpsPredicted;
        private double _lastBumpAt = double.NegativeInfinity;
        private double _bumpFlashT = double.NegativeInfinity;
        private int _mispredicts, _lastReconcileSeq;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.BumpState>(app, "lab-bump",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId)
                     && r.State.bots != null && r.State.bots.ContainsKey("bot1"));
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            if (Room.State.bots == null || !Room.State.bots.TryGetValue("bot1", out _bot)) return false;

            _predict = Predict.For(Room);
            // Bots are DEAD-RECKONED through the shared step — the timeline the
            // collision test below reads at ctx.ReckonTime.
            _predict.AttachAll("bots", new ReckonOptions<Lab.Bot>
            {
                Fields = new[] { "x", "y" },
                Smoothing = 25,
                Step = (b, dt, elapsedMs) =>
                {
                    var s = new Sim.BotState
                    {
                        x = b.x, y = b.y, vx = b.vx, vy = b.vy, kind = b.kind,
                        minX = b.minX, maxX = b.maxX, baseY = b.baseY,
                        phaseMs = b.phaseMs, speed = b.speed, lastTeleport = b.lastTeleport,
                    };
                    Sim.StepBot(ref s, dt, elapsedMs);
                    b.x = (float)s.x; b.y = (float)s.y; b.vx = (float)s.vx; b.vy = (float)s.vy;
                    b.lastTeleport = (float)s.lastTeleport;
                },
            });
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            Build();
            app.SetLatencyPreset(2);   // a knife-edge verdict needs a real RTT
            return true;
        }

        private void Build()
        {
            _recon = _predict.Reconciler(_me, new ReconcilerOptions<Lab.BumpPlayer, Lab.MoveInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy", "bumpTicks" },
                Smoothing = 15,
                Step = Step,
            });
            _lastReconcileSeq = 0;
        }

        private void Step(StepContext ctx, Lab.BumpPlayer p, Lab.MoveInput cmd)
        {
            int ticks = p.bumpTicks;
            Sim.StepBumpGate(ref ticks);          // reconciled tick gate (both sides)
            p.bumpTicks = (byte)ticks;

            var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
            Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
            p.x = (float)e.x; p.y = (float)e.y; p.vx = (float)e.vx; p.vy = (float)e.vy;

            double px = p.x, py = p.y, when = ctx.ReckonTime;
            int gate = p.bumpTicks;
            var knock = _useMemo
                ? ctx.Memo("bump", () => TestBots(px, py, gate, when))
                : TestBots(px, py, gate, when);

            if (!knock.Hit) return;
            p.vx = (float)knock.Vx;
            p.vy = (float)knock.Vy;
            p.bumpTicks = Sim.BumpCooldownTicks;   // immunity rides adopt+replay
            if (ctx.IsReplay) return;              // FX/counters: live step only
            _bumpsPredicted++;
            _lastBumpAt = RoomClock.GetNow();
            _bumpFlashT = _lastBumpAt;
        }

        private Knock TestBots(double px, double py, int gate, double when)
        {
            var result = new Knock();
            Room.State.bots.ForEach((key, bot) =>
            {
                if (result.Hit) return;
                // The server rewinds THIS input to ReckonTime — test there. With
                // the toggle off we read the raw snapshot instead: ~RTT/2 behind
                // where the server tests, which is the whole point of the lab.
                double bx = _useValueAt ? _predict.ValueAt(bot, "x", when) : bot.x;
                double by = _useValueAt ? _predict.ValueAt(bot, "y", when) : bot.y;
                if (Sim.CollideBot(px, py, gate, bx, by, out double vx, out double vy))
                    result = new Knock { Hit = true, Vx = vx, Vy = vy };
            });
            return result;
        }

        public override void Frame(App app, double now, double dtMs)
        {
            // Both toggles rebuild nothing — the step reads them live.
            if (Kb.Key(KeyCode.V)) _useValueAt = !_useValueAt;
            if (Kb.Key(KeyCode.M)) _useMemo = !_useMemo;

            // The acceptance script can't hand-steer into a moving bot; when it
            // drives, seek the bot's lane and let the patrol sweep do the rest.
            int moveX = Kb.MoveX(), moveY = Kb.MoveY();
            if (Kb.Autopilot)
            {
                double dy = _predict.Value(_bot, "y") - _recon.State.y;
                moveX = 0;
                moveY = dy > 1.0 ? 1 : dy < -1.0 ? -1 : 0;
            }

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)moveX;
                _cmd.moveY = (sbyte)moveY;
                _input.Send();
            }

            // Attribute LARGE corrections near a predicted bump to a flipped
            // verdict. Small post-bump corrections (< ~3u) are knockback-direction
            // epsilon; a genuinely flipped verdict diverges by many units — the
            // 48 u/s shove either happened or it didn't.
            if (_recon.ReconcileSeq == _lastReconcileSeq) return;
            _lastReconcileSeq = _recon.ReconcileSeq;
            if (_recon.LastCorrectionMag > 3 && RoomClock.GetNow() - _lastBumpAt < 700)
                _mispredicts++;
        }

        public override void Render(App app)
        {
            var v = app.View;
            Room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Square(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PlayerHalf, Palette.Hue(p.hue, 0.4f));
            });

            double bx = _predict.Value(_bot, "x"), by = _predict.Value(_bot, "y");
            Draw.Circle(v, bx, by, Sim.BotRadius, Palette.A(Palette.Warn, 0.3f));
            Draw.CircleOutline(v, bx, by, Sim.BotRadius, Palette.Warn);
            Draw.Label(v, bx, by, "bot (reckon = hit position)", Palette.Warn, 10,
                -v.S(Sim.BotRadius) - 14);
            Draw.CircleOutline(v, _bot.x, _bot.y, Sim.BotRadius,
                Palette.A(Palette.Text, 0.45f), dashed: true);
            Draw.Label(v, _bot.x, _bot.y, "stale snapshot", Palette.A(Palette.Text, 0.45f), 9,
                v.S(Sim.BotRadius) + 4);

            Draw.GhostSquare(v, _me.x, _me.y, Sim.PlayerHalf, Palette.A(Palette.Text, 0.5f));
            bool flash = RoomClock.GetNow() - _bumpFlashT < 300;
            double px = _recon.Value("x"), py = _recon.Value("y");
            Draw.Square(v, px, py, Sim.PlayerHalf, flash ? Palette.Bad : Palette.Hue(_me.hue));
            Draw.SquareOutline(v, px, py, Sim.PlayerHalf, Palette.Text, flash ? 2.5f : 1f);

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("bumps predicted", _bumpsPredicted.ToString(), Palette.Text);
            h.Row("bumps (authoritative)", _me.bumps.ToString(), Palette.Text);
            h.Row("mispredicts", _mispredicts.ToString(),
                _mispredicts > 0 ? Palette.Warn : Palette.Good);
            double rate = MispredictRate();
            h.Row("mispredict rate", _bumpsPredicted > 0 ? $"{rate:F0} %" : "--",
                _bumpsPredicted == 0 ? Palette.TextFaint
                    : rate < 10 ? Palette.Good : rate < 40 ? Palette.Warn : Palette.Bad);
            h.Row("bump immunity (ticks)", _recon.State.bumpTicks.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "graze the bot's patrol path");
            h.Key("V", _useValueAt ? "read bot at ctx.ReckonTime" : "read the STALE snapshot");
            h.Key("M", _useMemo ? "verdict frozen with Memo" : "verdict RE-DERIVED on replay");
            h.Note("Raise the latency preset and graze the bot repeatedly. V off tests against " +
                   "a position ~RTT/2 behind where the server tests; M off lets replays " +
                   "re-derive the verdict against newer bot data and flip knife-edge calls. " +
                   "Both off is maximally wrong.");
        }

        public double MispredictRate()
            => _bumpsPredicted > 0 ? (double)_mispredicts / _bumpsPredicted * 100 : 0;

        public int BumpsPredicted => _bumpsPredicted;
        /// <summary>The server's own count — the only verdict that settles it.</summary>
        public int BumpsAuthoritative => _me.bumps;
        public bool UseValueAt { get => _useValueAt; set => _useValueAt = value; }
        public bool UseMemo { get => _useMemo; set => _useMemo = value; }

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            Room.State.bots.TryGetValue("bot1", out _bot);
            Build();
        }
    }
}
