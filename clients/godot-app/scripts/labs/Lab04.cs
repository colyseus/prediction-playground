using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Godot;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 04 — Remote Interpolation.
    ///
    /// The SAME bot rendered through four Predict instances, one per mode:
    ///
    ///   raw          the decoded snapshot verbatim: stutters at patch rate.
    ///   lerp         render `delay` ms in the PAST, between two real samples.
    ///                Never wrong, always late.
    ///   damped       exponential chase of the newest sample: lags by
    ///                construction and rounds corners.
    ///   extrapolate  project the trend FORWARD. Present-time, but overshoots
    ///                whenever the bot turns.
    ///
    /// The strip along the bottom plots the bot's x over time: white dots are
    /// received samples, the coloured traces are what each mode rendered.
    /// Port of labs/04-interp-modes/.
    /// </summary>
    public partial class Lab04 : LabBase<Lab.BotsState>
    {
        public override string Id => "04-interp-modes";
        public override int Num => 4;
        public override string Title => "Remote Interpolation";
        public override string Blurb => "lerp / damped / extrapolate / raw, side by side.";

        private const int TraceCap = 400;
        private const double StripSpanMs = 2500;

        private static readonly string[] Patterns = { "patrol", "circle", "wander" };

        /// <summary>One render mode: its Predict (null = raw), trace, and metric.</summary>
        private class Mode
        {
            public string Name;
            public Color Color;
            public Predict Predict;      // null for "raw" — read the instance
            public bool Visible = true;
            public readonly Series Trace = new Series(TraceCap);
            public readonly Smoothness Smooth = new Smoothness();
        }

        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Pacer _pacer;
        private string _sid;
        private Lab.Bot _bot;

        private Mode[] _modes;
        private readonly Series _samples = new Series(TraceCap);
        private double _lastRawX = double.NaN, _lastRawY = double.NaN;
        private int _pattern;
        private double _botTravel;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.BotsState>(app, "lab-bots",
                r => r.State.bots != null && r.State.bots.ContainsKey("bot1"));
            _sid = Room.SessionId;
            if (Room.State.bots == null || !Room.State.bots.TryGetValue("bot1", out _bot)) return false;

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            _pacer = new Pacer(1000.0 / Sim.TickHz);

            _modes = new[]
            {
                new Mode { Name = "raw", Color = Palette.Text },
                Attach("lerp", Palette.Blue, new PredictFieldOptions
                    { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs }),
                Attach("damped", Palette.Good, new PredictFieldOptions
                    { Mode = PredictMode.Damped, SmoothMs = 83 }),
                Attach("extrapolate", Palette.Warn, new PredictFieldOptions
                    { Mode = PredictMode.Extrapolate, MaxExtrapolate = 250 }),
            };
            return true;
        }

        /// <summary>One Predict per mode — same entity, same fields, different smoothing.</summary>
        private Mode Attach(string name, Color color, PredictFieldOptions opts)
        {
            var predict = Predict.Get(Room);
            predict.Attach(_bot, new AttachConfig { ["x"] = opts, ["y"] = opts });
            return new Mode { Name = name, Color = color, Predict = predict };
        }

        private double Value(Mode m, string field)
            => m.Predict == null
                ? (field == "x" ? _bot.x : _bot.y)
                : m.Predict.Value(_bot, field);

        public override void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(Key.B))
            {
                _pattern = (_pattern + 1) % Patterns.Length;
                Room.Send("pattern", new Dictionary<string, string> { ["kind"] = Patterns[_pattern] });
            }
            for (int i = 0; i < _modes.Length; i++)
                if (Kb.Key(Key.F1 + i)) _modes[i].Visible = !_modes[i].Visible;

            int steps = _pacer.Steps(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }
            foreach (var m in _modes) m.Predict?.Tick(now);

            // A received sample = the decoded value changing, once per patch.
            if (_bot.x != _lastRawX || _bot.y != _lastRawY)
            {
                if (!double.IsNaN(_lastRawX))
                {
                    double bdx = _bot.x - _lastRawX, bdy = _bot.y - _lastRawY;
                    _botTravel += System.Math.Sqrt(bdx * bdx + bdy * bdy);
                }
                _lastRawX = _bot.x;
                _lastRawY = _bot.y;
                _samples.Push(Room.Clock.LastServerTime(), _bot.x);
            }

            double sNow = Room.Clock.ServerNow();
            foreach (var m in _modes)
            {
                double x = Value(m, "x"), y = Value(m, "y");
                m.Trace.Push(sNow, x);
                m.Smooth.Sample(x, y, dtMs);
            }
        }

        public override void Render(App app)
        {
            var v = app.View;
            Room.State.players.ForEach((key, p) =>
                Draw.Square(v, p.x, p.y, Sim.PlayerHalf, Palette.Hue(p.hue, key == _sid ? 0.9f : 0.4f)));

            for (int i = 0; i < _modes.Length; i++)
            {
                var m = _modes[i];
                if (!m.Visible) continue;
                double x = Value(m, "x"), y = Value(m, "y");
                Draw.CircleOutline(v, x, y, Sim.BotRadius, m.Color, dashed: i == 0);
                // Stagger the labels: the four modes sit within a bot radius of
                // each other most of the time, so a shared baseline is unreadable.
                Draw.Label(v, x, y, m.Name, m.Color, 10, -v.S(Sim.BotRadius) - 14 - i * 11);
            }

            DrawStrip(app);

            var h = app.Hud;
            h.Section("SMOOTHNESS (speed CV)");
            foreach (var m in _modes)
            {
                double cv = m.Smooth.Cv();
                if (double.IsNaN(cv)) h.Row(m.Name, "--", Palette.TextFaint);
                else h.Row(m.Name, $"{cv * 100:F0} %",
                    cv < 0.15 ? Palette.Good : cv < 0.5 ? Palette.Warn : Palette.Bad);
            }
            h.Row("samples buffered", _samples.Count.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive your own square");
            h.Key("B", $"bot pattern: {Patterns[_pattern]}");
            for (int i = 0; i < _modes.Length; i++)
                h.Key($"F{i + 1}", $"{(_modes[i].Visible ? "hide" : "show")} {_modes[i].Name}");
            h.Note("Lower CV = smoother render. raw stutters at the patch rate; lerp is " +
                   "smooth but late; damped rounds corners; extrapolate is present-time but " +
                   "overshoots every turn — press B and watch it on circle.");
        }

        /// <summary>The buffer timeline: received samples vs per-mode rendered traces.</summary>
        private void DrawStrip(App app)
        {
            const float h = 118, pad = 10;
            float x0 = app.Stage.Position.X + 24, x1 = app.Stage.End.X - 16;
            float y0 = app.Stage.End.Y - h - 10, y1 = y0 + h;
            if (x1 - x0 < 200) return;

            Draw.Rect(new Rect2(x0, y0, x1 - x0, h), Palette.A(Palette.Panel, 0.9f));

            double sNow = Room.Clock.ServerNow(), lastPatch = Room.Clock.LastServerTime();
            double tMin = sNow - StripSpanMs, tMax = sNow + 150;
            // Value axis: bot x spans ~[20,80]; leave headroom for overshoot.
            const double vMin = 12, vMax = 88;
            float TX(double t) => x0 + pad + (float)((t - tMin) / (tMax - tMin)) * (x1 - x0 - pad * 2);
            float TY(double val) => y1 - pad - (float)((val - vMin) / (vMax - vMin)) * (h - pad * 2 - 14);

            foreach (var (t, label) in new[] { (lastPatch, "newest patch"), (sNow, "now") })
            {
                float x = TX(t);
                if (x < x0 || x > x1) continue;
                Draw.Dashed(new Vector2(x, y0 + 4), new Vector2(x, y1 - 4),
                    Palette.A(Palette.Text, 0.25f), 1f, 3f, 3f);
                Draw.Text(x - 40, y0 + 6, 80, label, Palette.A(Palette.Text, 0.5f), 9,
                    HorizontalAlignment.Center);
            }

            _samples.ForEach((t, val) =>
            {
                if (t < tMin || t > tMax) return;
                Draw.Rect(new Rect2(TX(t) - 1.5f, TY(val) - 1.5f, 3, 3), Palette.A(Palette.Text, 0.85f));
            });

            foreach (var m in _modes)
            {
                if (!m.Visible || m.Predict == null) continue;
                bool started = false;
                Vector2 prev = default;
                m.Trace.ForEach((t, val) =>
                {
                    if (t < tMin || t > tMax) { started = false; return; }
                    var pt = new Vector2(TX(t), TY(val));
                    if (started) Draw.Line(prev, pt, Palette.A(m.Color, 0.9f), 1.2f);
                    prev = pt;
                    started = true;
                });
            }
        }

        /// <summary>Drive the bot pattern from the harness, as the B key would.</summary>
        public void SetPattern(string kind)
        {
            int i = System.Array.IndexOf(Patterns, kind);
            if (i < 0) return;
            _pattern = i;
            Room.Send("pattern", new Dictionary<string, string> { ["kind"] = kind });
        }

        /// <summary>How far the raw bot has travelled — a stationary bot scores NaN.</summary>
        public double BotTravel => _botTravel;

        /// <summary>Start a clean measurement window once the pattern has landed.</summary>
        public void ResetMeters()
        {
            foreach (var m in _modes) m.Smooth.Clear();
            _botTravel = 0;
        }

        /// <summary>Per-mode speed CV, for the acceptance harness.</summary>
        public Dictionary<string, double> SmoothnessByMode()
        {
            var r = new Dictionary<string, double>();
            foreach (var m in _modes) r[m.Name] = m.Smooth.Cv();
            return r;
        }

        /// <summary>Per-mode meter state, so a NaN can explain itself.</summary>
        public string DescribeMode(string name)
        {
            foreach (var m in _modes) if (m.Name == name) return m.Smooth.Describe();
            return "?";
        }

        public override void Unmount()
        {
            foreach (var m in _modes) m.Predict?.Dispose();
        }

        public override void OnReconnect()
        {
            _pacer.Reset();
            Room.State.bots.TryGetValue("bot1", out _bot);
        }
    }
}
