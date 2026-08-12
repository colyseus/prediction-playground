using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Godot;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 06 — Lag Compensation.
    ///
    /// The client's job is only to be HONEST about its display timeline:
    ///  - bots are DRAWN with lerp, RemoteInterpMs in the past;
    ///  - the server records bot history and, on a fire input, rewinds every
    ///    target to this client's render time — the instant the shooter aimed at;
    ///  - AllowRewind stamps the render time ONLY on fire frames (movement
    ///    inputs don't need the extra wire bytes).
    ///
    /// Markers: blue = what you saw · green = the server's rewound read · red =
    /// the server's live position. With lag comp on they coincide; with it off,
    /// the red↔blue gap is exactly how far you must lead.
    /// Port of labs/06-lag-comp/.
    /// </summary>
    public partial class Lab06 : LabBase<Lab.RangeState>
    {
        public override string Id => "06-lag-comp";
        public override int Num => 6;
        public override string Title => "Lag Compensation";
        public override string Blurb => "The server rewinds targets to what you saw.";

        private const int MaxShots = 6;
        private const double ShotFadeMs = 2600;

        /// <summary>One fired ray and the three answers it gets back.</summary>
        private class Shot
        {
            public double Ox, Oy, Tx, Ty;        // ray origin + drawn endpoint
            public double BlueX, BlueY;          // what the shooter saw at click time
            public bool PredictedHit;            // this screen's own verdict, at click time
            public double GreenX, GreenY;        // server's rewound read
            public double RedX, RedY;            // server's live position
            public bool Answered, Hit;
            public double T;
        }

        private Predict _predict;
        private Reconciler<Lab.RangePlayer, Lab.RangeInput> _recon;
        private Lab.RangeInput _cmd;
        private InputHandle _input;
        private Lab.RangePlayer _me;
        private Lab.Bot _bot;
        private string _sid;

        private double _aimX = 50, _aimY = 20;
        private bool _pendingFire;
        private readonly List<Shot> _shots = new List<Shot>();
        private int _hitsOn, _shotsOn, _hitsOff, _shotsOff;
        private int _predictedHits;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.RangeState>(app, "lab-range",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId)
                     && r.State.bots != null && r.State.bots.ContainsKey("bot1"));
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            if (Room.State.bots == null || !Room.State.bots.TryGetValue("bot1", out _bot)) return false;

            _predict = Predict.For(Room);
            // Bots ride the lerp timeline — the one the server rewinds to.
            _predict.AttachAll("bots", new AttachConfig {
                ["x"] = new PredictFieldOptions { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs },
                ["y"] = new PredictFieldOptions { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs },
            });
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            Room.OnMessage<Dictionary<string, object>>("shot", OnShot);

            // RenderDelay is bound for us: Reconciler(...) pushes this Predict's
            // lerp delay onto the handle, so the server rewinds to exactly the
            // instant we drew. Passing it here would only override that.
            _cmd = new Lab.RangeInput();
            _input = Room.Input(_cmd, new InputOptions
            {
                AllowRewind = data => ((Lab.RangeInput)data).fire,   // fire frames only
            });
            Build();
            app.SetLatencyPreset(2);   // lag comp says nothing on a 1 ms link
            return true;
        }

        private void Build()
        {
            _recon = _predict.Reconciler(_me, new ReconcilerOptions<Lab.RangePlayer, Lab.RangeInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy" },
                Smoothing = 15,
                Step = (ctx, p, cmd) =>
                {
                    var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
                    Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
                    p.x = (float)e.x; p.y = (float)e.y; p.vx = (float)e.vx; p.vy = (float)e.vy;
                },
            });
        }

        /// <summary>The server's shot report completes the oldest unanswered record.</summary>
        private void OnShot(Dictionary<string, object> msg)
        {
            if (!msg.TryGetValue("sid", out var sid) || (string)sid != _sid) return;
            bool hit = Flag(msg, "hit"), lagComp = Flag(msg, "lagComp");

            foreach (var s in _shots)
            {
                if (s.Answered) continue;
                s.Answered = true;
                s.Hit = hit;
                s.GreenX = Coord(msg, "seenX"); s.GreenY = Coord(msg, "seenY");
                s.RedX = Coord(msg, "liveX"); s.RedY = Coord(msg, "liveY");
                break;
            }
            if (lagComp) { _shotsOn++; if (hit) _hitsOn++; }
            else { _shotsOff++; if (hit) _hitsOff++; }
        }

        private static bool Flag(Dictionary<string, object> m, string k)
            => m.TryGetValue(k, out var v) && v is bool b && b;

        private static double Coord(Dictionary<string, object> m, string k)
            => m.TryGetValue(k, out var v) ? System.Convert.ToDouble(v) : 0;

        public override void Frame(App app, double now, double dtMs)
        {
            var v = app.View;
            Vector2 mouse = Kb.MousePos;
            bool overStage = mouse.X < app.Stage.End.X;
            if (Kb.Autopilot)
            {
                // The acceptance script has no cursor — track the target it fires at.
                _aimX = _predict.Value(_bot, "x");
                _aimY = _predict.Value(_bot, "y");
            }
            else if (overStage)
            {
                _aimX = v.WX(mouse.X);
                _aimY = v.WY(mouse.Y);
            }
            if (overStage && Kb.MouseDown()) _pendingFire = true;
            if (Kb.Key(Key.Space)) _pendingFire = true;
            if (Kb.Key(Key.C))
                Room.Send("lagcomp", new Dictionary<string, bool> { ["on"] = !Room.State.lagComp });

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _cmd.aimX = (float)_aimX;
                _cmd.aimY = (float)_aimY;
                _cmd.fire = _pendingFire;
                _input.Send();
                if (!_pendingFire) continue;
                RecordShot(now);
                _pendingFire = false;
            }
        }

        /// <summary>Record what THIS screen showed at the moment of the shot.</summary>
        private void RecordShot(double now)
        {
            double px = _recon.State.x, py = _recon.State.y;
            double dx = _aimX - px, dy = _aimY - py;
            double len = System.Math.Sqrt(dx * dx + dy * dy);
            if (len < 1e-9) len = 1;
            dx /= len; dy /= len;
            double bx = _predict.Value(_bot, "x"), by = _predict.Value(_bot, "y");
            // The server's own hit test, run against the pose THIS screen was
            // showing. Available immediately, and it agrees with the server
            // whenever the rewind lands where it should.
            bool predictedHit = Sim.RayCircle(px, py, dx, dy, bx, by, Sim.BotRadius, Sim.ShotRange) >= 0;
            if (predictedHit) _predictedHits++;
            if (_shots.Count == MaxShots) _shots.RemoveAt(0);
            _shots.Add(new Shot
            {
                Ox = px, Oy = py, Tx = px + dx * 120, Ty = py + dy * 120,
                BlueX = bx, BlueY = by,
                PredictedHit = predictedHit,
                T = now,
            });
        }

        public override void Render(App app)
        {
            var v = app.View;
            double now = RoomClock.GetNow();

            Room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Square(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PlayerHalf, Palette.Hue(p.hue, 0.4f));
            });

            double px = _recon.Value("x"), py = _recon.Value("y");
            Draw.Square(v, px, py, Sim.PlayerHalf, Palette.Hue(_me.hue));
            Draw.SquareOutline(v, px, py, Sim.PlayerHalf, Palette.Text);

            double bx = _predict.Value(_bot, "x"), by = _predict.Value(_bot, "y");
            Draw.Circle(v, bx, by, Sim.BotRadius, Palette.A(Palette.Blue, 0.25f));
            Draw.CircleOutline(v, bx, by, Sim.BotRadius, Palette.Blue);
            Draw.Label(v, bx, by, "target (lerp view)", Palette.Blue, 10, -v.S(Sim.BotRadius) - 14);

            Draw.DashedWorld(v, px, py, _aimX, _aimY, Palette.A(Palette.Text, 0.18f));
            Draw.CircleOutline(v, _aimX, _aimY, 0.9, Palette.A(Palette.Text, 0.7f));

            for (int i = _shots.Count - 1; i >= 0; i--)
            {
                var s = _shots[i];
                double age = now - s.T;
                if (age > ShotFadeMs) { _shots.RemoveAt(i); continue; }
                float a = (float)(1 - age / ShotFadeMs);
                // Until the report lands the ray wears this screen's own
                // verdict, faint; the server's answer replaces it at full
                // strength. A ray that flips colour is the rewind disagreeing.
                var ray = Palette.A(
                    (s.Answered ? s.Hit : s.PredictedHit) ? Palette.Good : Palette.Bad,
                    a * (s.Answered ? 0.7f : 0.3f));
                Draw.Line(new Vector2(v.SX(s.Ox), v.SY(s.Oy)), new Vector2(v.SX(s.Tx), v.SY(s.Ty)),
                    ray, 1.2f);
                Draw.CircleOutline(v, s.BlueX, s.BlueY, Sim.BotRadius * 0.7, Palette.A(Palette.Blue, a));
                if (!s.Answered) continue;
                Draw.CircleOutline(v, s.GreenX, s.GreenY, Sim.BotRadius * 0.85, Palette.A(Palette.Good, a));
                Draw.CircleOutline(v, s.RedX, s.RedY, Sim.BotRadius, Palette.A(Palette.Bad, a));
            }

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("hits (lag comp ON)", $"{_hitsOn} / {_shotsOn}",
                _shotsOn > 0 && _hitsOn * 10 > _shotsOn * 7 ? Palette.Good : Palette.Text);
            h.Row("hits (lag comp OFF)", $"{_hitsOff} / {_shotsOff}",
                _shotsOff > 0 && _hitsOff * 2 < _shotsOff ? Palette.Bad : Palette.Text);
            double gap = ViewLag();
            h.Row("view lag (red<->blue gap)", gap >= 0 ? $"{gap:F1} u" : "--",
                gap >= 0 ? Palette.Text : Palette.TextFaint);

            h.Section("CONTROLS");
            h.Key("WASD", "drive (predicted)");
            h.Key("mouse", "aim");
            h.Key("click / SPACE", "fire");
            h.Key("C", Room.State.lagComp ? "lag comp: ON (room-wide)" : "lag comp: OFF (room-wide)");
            h.Note("blue = what you saw — green = the server's rewound read — red = the " +
                   "server live. The ray shows your own verdict faintly at the click, then " +
                   "the server's at full strength. Turn lag comp off at 200 ms and you have " +
                   "to lead the target by exactly the red-to-blue gap.");
        }

        /// <summary>Newest answered shot's red↔blue distance; −1 if none yet.</summary>
        public double ViewLag()
        {
            for (int i = _shots.Count - 1; i >= 0; i--)
            {
                var s = _shots[i];
                if (!s.Answered) continue;
                double dx = s.RedX - s.BlueX, dy = s.RedY - s.BlueY;
                return System.Math.Sqrt(dx * dx + dy * dy);
            }
            return -1;
        }

        /// <summary>Fire from the acceptance harness, exactly as a click would.</summary>
        public void Fire() => _pendingFire = true;
        public void SetLagComp(bool on)
            => Room.Send("lagcomp", new Dictionary<string, bool> { ["on"] = on });
        public bool LagComp => Room.State.lagComp;
        public int HitsOn => _hitsOn;
        public int ShotsOn => _shotsOn;
        public int HitsOff => _hitsOff;
        public int ShotsOff => _shotsOff;
        /// <summary>Shots this screen called a hit at the click, before any report.</summary>
        public int PredictedHits => _predictedHits;
        /// <summary>The rewind error the server actually made, in ms of bot travel.</summary>
        public double RewindErrorU()
        {
            for (int i = _shots.Count - 1; i >= 0; i--)
            {
                var s = _shots[i];
                if (!s.Answered) continue;
                double dx = s.GreenX - s.BlueX, dy = s.GreenY - s.BlueY;
                return System.Math.Sqrt(dx * dx + dy * dy);
            }
            return -1;
        }

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            Room.State.bots.TryGetValue("bot1", out _bot);
            Build();
        }
    }
}
