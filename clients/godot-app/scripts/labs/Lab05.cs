using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Godot;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 05 — Dead Reckoning.
    ///
    /// Instead of drawing the PAST (lerp), forward-simulate the latest snapshot
    /// to the PRESENT with the same step function the server runs. The reckon
    /// horizon is exactly the snapshot age.
    ///
    ///   smoothing  glide applied to each snapshot REBASE (the small correction
    ///              when a patch lands mid-glide).
    ///   snap       rebases beyond this distance POP instead of gliding: a
    ///              teleport is a cut, and smoothing across it looks like flying.
    ///
    /// Port of labs/05-dead-reckoning/.
    /// </summary>
    public partial class Lab05 : LabBase<Lab.BotsState>
    {
        public override string Id => "05-dead-reckoning";
        public override int Num => 5;
        public override string Title => "Dead Reckoning";
        public override string Blurb => "Forward-simulate remotes to the present with the shared step.";

        private static readonly string[] Patterns = { "teleport", "patrol", "wander", "circle" };
        private const int MaxDots = 40;

        private Predict _lerp, _reckon;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Pacer _pacer;
        private string _sid;
        private Lab.Bot _bot;

        private double _smoothing = 25, _snap = 8;
        private int _pattern;

        private readonly (double x, double y, double t)[] _dots =
            new (double, double, double)[MaxDots];
        private int _dotCount;
        private double _lastRawX = double.NaN, _lastRawY = double.NaN;
        private double _lastReckonX = double.NaN;
        private int _warps;
        private double _peakGap;
        private double _warpFlashT = double.NegativeInfinity;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.BotsState>(app, "lab-bots",
                r => r.State.bots != null && r.State.bots.ContainsKey("bot1"));
            _sid = Room.SessionId;
            if (Room.State.bots == null || !Room.State.bots.TryGetValue("bot1", out _bot)) return false;

            // The delayed baseline to compare against.
            _lerp = Predict.For(Room);
            var lerpOpts = new PredictFieldOptions { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs };
            _lerp.Attach(_bot, new AttachConfig { ["x"] = lerpOpts, ["y"] = lerpOpts });

            AttachReckon();

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            _pacer = new Pacer(1000.0 / Sim.TickHz);

            SendPattern();   // the teleporter is the most legible default
            return true;
        }

        /// <summary>
        /// The reckon step, called by the SDK with a scratch COPY of the bot.
        /// `elapsedMs` is absolute server-time at the end of the substep, which
        /// is what makes the circle's closed form and the teleport schedule
        /// evaluable at any instant — the same property the server relies on.
        /// </summary>
        private void AttachReckon()
        {
            _reckon = Predict.For(Room);
            _reckon.Attach(_bot, new ReckonOptions<Lab.Bot>
            {
                Fields = new[] { "x", "y" },
                Smoothing = _smoothing,
                Snap = _snap,
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
                    // Scratch mutation only persists within one forward pass —
                    // exactly right: periods chain, nothing leaks into the snapshot.
                    b.lastTeleport = (float)s.lastTeleport;
                },
            });
        }

        private void Rebuild()
        {
            _reckon.Dispose();
            AttachReckon();
        }

        private void SendPattern() => Room.Send("pattern", new Dictionary<string, string> { ["kind"] = Patterns[_pattern] });

        public override void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(Key.B))
            {
                _pattern = (_pattern + 1) % Patterns.Length;
                SendPattern();
                _warps = 0;
            }
            int smoothStep = Kb.Key(Key.Equal) ? 5 : Kb.Key(Key.Minus) ? -5 : 0;
            if (smoothStep != 0)
            {
                _smoothing = Mathf.Clamp((float)(_smoothing + smoothStep), 0, 50);
                Rebuild();
            }
            int snapStep = Kb.Key(Key.Period) ? 6 : Kb.Key(Key.Comma) ? -6 : 0;
            if (snapStep != 0)
            {
                _snap = Mathf.Clamp((float)(_snap + snapStep), 1, 60);
                Rebuild();
            }

            int steps = _pacer.Steps(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }
            _lerp.Tick(now);
            _reckon.Tick(now);

            if (_bot.x != _lastRawX || _bot.y != _lastRawY)
            {
                _lastRawX = _bot.x;
                _lastRawY = _bot.y;
                if (_dotCount == MaxDots)
                {
                    System.Array.Copy(_dots, 1, _dots, 0, MaxDots - 1);
                    _dotCount--;
                }
                _dots[_dotCount++] = (_bot.x, _bot.y, now);
            }

            double rx = _reckon.Value(_bot, "x");
            if (!double.IsNaN(_lastReckonX) && Mathf.Abs((float)(rx - _lastReckonX)) > 15)
            {
                _warps++;
                _warpFlashT = now;
            }
            _lastReckonX = rx;

            double gx = rx - _lerp.Value(_bot, "x"), gy = _reckon.Value(_bot, "y") - _lerp.Value(_bot, "y");
            double gap = System.Math.Sqrt(gx * gx + gy * gy);
            if (gap > _peakGap) _peakGap = gap;
        }

        public override void Render(App app)
        {
            var v = app.View;
            double now = RoomClock.GetNow();
            double sNow = Room.Clock.ServerNow();
            double age = System.Math.Max(0, sNow - Room.Clock.LastServerTime());

            Room.State.players.ForEach((key, p) =>
                Draw.Square(v, p.x, p.y, Sim.PlayerHalf, Palette.Hue(p.hue, key == _sid ? 0.9f : 0.4f)));

            // Raw snapshot dots, fading over 1.5 s — the samples reckon starts from.
            for (int i = 0; i < _dotCount; i++)
            {
                double a = 1 - (now - _dots[i].t) / 1500.0;
                if (a <= 0) continue;
                Draw.Circle(v, _dots[i].x, _dots[i].y, 0.4, Palette.A(Palette.Text, (float)a * 0.5f));
            }

            double lx = _lerp.Value(_bot, "x"), ly = _lerp.Value(_bot, "y");
            double rx = _reckon.Value(_bot, "x"), ry = _reckon.Value(_bot, "y");

            // The reckon horizon: newest snapshot → forward-simulated present.
            Draw.DashedWorld(v, _bot.x, _bot.y, rx, ry, Palette.A(Palette.Warn, 0.8f), 1.2f);
            Draw.Circle(v, _bot.x, _bot.y, 0.7, Palette.A(Palette.Text, 0.9f));

            Draw.CircleOutline(v, lx, ly, Sim.BotRadius, Palette.Blue);
            Draw.Label(v, lx, ly, "lerp (past)", Palette.Blue, 10, v.S(Sim.BotRadius) + 4);
            Draw.Circle(v, rx, ry, Sim.BotRadius, Palette.A(Palette.Warn, 0.25f));
            Draw.CircleOutline(v, rx, ry, Sim.BotRadius, Palette.Warn);
            Draw.Label(v, rx, ry, "reckon (present)", Palette.Warn, 10, -v.S(Sim.BotRadius) - 14);

            if (now - _warpFlashT < 500)
                Draw.Label(v, rx, ry, "WARP", Palette.Bad, 13, -v.S(Sim.BotRadius) - 30);

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("reckon horizon (snapshot age)", $"{age:F0} ms", Palette.Text);
            h.Row("reckon vs lerp gap",
                $"{System.Math.Sqrt((rx - lx) * (rx - lx) + (ry - ly) * (ry - ly)):F1} u", Palette.Text);
            h.Row("warps seen", _warps.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive your own square");
            h.Key("B", $"bot pattern: {Patterns[_pattern]}");
            h.Key("- / =", $"rebase smoothing  {_smoothing:F0} /s");
            h.Key(", / .", $"snap threshold  {_snap:F0} u");
            h.Note("patrol = fully predictable — wander = server-secret turns, so reckon " +
                   "extrapolates straight through every one and gets corrected — teleport = a " +
                   "scheduled discontinuity. Raise the snap threshold above the warp distance " +
                   "and watch the teleport smear across the arena.");
        }

        /// <summary>The reckoned pose, for the acceptance harness.</summary>
        public double ReckonY => _reckon.Value(_bot, "y");

        /// <summary>Largest reckon↔lerp separation seen, for the acceptance harness.</summary>
        public double PeakReckonLerpGap => _peakGap;

        /// <summary>Drive the bot pattern from the harness, as the B key would.</summary>
        public void SetPattern(string kind)
        {
            int i = System.Array.IndexOf(Patterns, kind);
            if (i < 0) return;
            _pattern = i;
            SendPattern();
            _warps = 0;
            _peakGap = 0;
        }

        public override void Unmount()
        {
            _reckon?.Dispose();
            _lerp?.Dispose();
        }

        public override void OnReconnect()
        {
            _pacer.Reset();
            Room.State.bots.TryGetValue("bot1", out _bot);
            _dotCount = 0;
        }
    }
}
