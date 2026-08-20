using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Godot;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 11 — Deterministic Randomness.
    ///
    /// The shotgun fan is "random", yet the client predicts every pellet EXACTLY
    /// — because the randomness is a pure function of data both sides already
    /// share:
    ///
    ///   seed = splitmix32(input seq ^ room salt)  →  mulberry32 pellet stream
    ///
    /// The seq is the engine's own input counter (Send() returns it; the server
    /// reads channel.consumedCount). The salt is synced room state. NOTHING
    /// about the pellets rides the wire — the server's broadcast here carries
    /// its angles only so this lab can overlay and compare.
    /// Port of labs/11-deterministic-rng/.
    /// </summary>
    public partial class Lab11 : LabBase<Lab.RangeState>
    {
        public override string Id => "11-deterministic-rng";
        public override int Num => 11;
        public override string Title => "Deterministic Randomness";
        public override string Blurb => "Same seed both sides, nothing on the wire.";

        private const double FanLen = 40.0;
        private const int MaxFans = 4;
        private const double FanFadeMs = 2400;

        /// <summary>One fired fan: what we derived, and what the server did.</summary>
        private class Fan
        {
            public int Seq;
            public double Ox, Oy;
            public readonly double[] Client = new double[Sim.Pellets];
            public readonly double[] Server = new double[Sim.Pellets];
            public bool Answered;
            public int Hits;
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
        private bool _pendingFire, _cheat;
        private Sim.Rng _cheatRng = new Sim.Rng(0x1234567u);

        private readonly List<Fan> _fans = new List<Fan>();
        private double _maxDivergence;
        private bool _hasDivergence;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.RangeState>(app, "lab-range",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId)
                     && r.State.bots != null && r.State.bots.ContainsKey("bot1"));
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            if (Room.State.bots == null || !Room.State.bots.TryGetValue("bot1", out _bot)) return false;

            _predict = Predict.Get(Room);
            // Bots ride the lerp timeline — the one the server rewinds to.
            _predict.AttachAll("bots", new AttachConfig {
                ["x"] = new PredictFieldOptions { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs },
                ["y"] = new PredictFieldOptions { Mode = PredictMode.Lerp, Delay = Sim.RemoteInterpMs },
            });
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            Room.OnMessage<Dictionary<string, object>>("spread", OnSpread);

            _cmd = new Lab.RangeInput();
            _input = Room.Input(_cmd, new InputOptions
            {
                AllowRewind = data => ((Lab.RangeInput)data).fire,
            });
            Build();
            return true;
        }

        private void Build()
        {
            _recon = _predict.Reconciler(_me, new ReconcilerOptions<Lab.RangePlayer, Lab.RangeInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy" },
                SmoothMs = 65,
                Step = (ctx, p, cmd) =>
                {
                    var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
                    Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
                    p.x = (float)e.x; p.y = (float)e.y; p.vx = (float)e.vx; p.vy = (float)e.vy;
                },
            });
        }

        /// <summary>The client's half of the derivation — identical to the server's.</summary>
        private void ClientFan(double baseAngle, int seq, uint salt, double[] outAngles)
        {
            if (!_cheat) { Sim.SpreadAngles(baseAngle, seq, salt, outAngles); return; }
            // The broken version: a local RNG the server cannot reproduce.
            for (int i = 0; i < Sim.Pellets; i++)
                outAngles[i] = baseAngle + (_cheatRng.Next() - 0.5) * Sim.SpreadRad;
        }

        /// <summary>The server's fan for the same (seq, salt) — for overlay only.</summary>
        private void OnSpread(Dictionary<string, object> msg)
        {
            if (!msg.TryGetValue("sid", out var sid) || (string)sid != _sid) return;
            if (!msg.TryGetValue("seq", out var seqRaw)) return;
            int seq = System.Convert.ToInt32(seqRaw);

            Fan fan = _fans.Find(f => f.Seq == seq);
            if (fan == null) return;
            if (!msg.TryGetValue("angles", out var anglesRaw) || !(anglesRaw is IList<object> angles)) return;

            double worst = 0;
            for (int i = 0; i < angles.Count && i < Sim.Pellets; i++)
            {
                fan.Server[i] = System.Convert.ToDouble(angles[i]);
                double d = System.Math.Abs(fan.Client[i] - fan.Server[i]);
                if (d > worst) worst = d;
            }
            if (msg.TryGetValue("hits", out var hits)) fan.Hits = System.Convert.ToInt32(hits);
            fan.Answered = true;
            _maxDivergence = worst;
            _hasDivergence = true;
        }

        public override void Frame(App app, double now, double dtMs)
        {
            var v = app.View;
            Vector2 mouse = Kb.MousePos;
            bool overStage = mouse.X < app.Stage.End.X;
            if (Kb.Autopilot)
            {
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
            if (Kb.Key(Key.X)) _cheat = !_cheat;

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _cmd.aimX = (float)_aimX;
                _cmd.aimY = (float)_aimY;
                _cmd.fire = _pendingFire;
                _cmd.spread = true;
                int seq = _input.Send();
                if (!_pendingFire || seq <= 0) continue;

                double px = _recon.State.x, py = _recon.State.y;
                var fan = new Fan
                {
                    Seq = seq, Ox = px, Oy = py, T = now,
                };
                ClientFan(System.Math.Atan2(_aimY - py, _aimX - px), seq, Room.State.salt, fan.Client);
                if (_fans.Count == MaxFans) _fans.RemoveAt(0);
                _fans.Add(fan);
                _pendingFire = false;
            }
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
            Draw.CircleOutline(v, _aimX, _aimY, 0.9, Palette.A(Palette.Text, 0.7f));

            for (int i = _fans.Count - 1; i >= 0; i--)
            {
                var f = _fans[i];
                double age = now - f.T;
                if (age > FanFadeMs) { _fans.RemoveAt(i); continue; }
                float a = (float)(1 - age / FanFadeMs);
                for (int p = 0; p < Sim.Pellets; p++)
                {
                    double ang = f.Client[p];
                    Draw.Line(new Vector2(v.SX(f.Ox), v.SY(f.Oy)),
                        new Vector2(v.SX(f.Ox + System.Math.Cos(ang) * FanLen),
                                    v.SY(f.Oy + System.Math.Sin(ang) * FanLen)),
                        Palette.A(Palette.Warn, a * 0.75f), 1.2f);
                }
                if (!f.Answered) continue;
                for (int p = 0; p < Sim.Pellets; p++)
                {
                    double ang = f.Server[p];
                    Draw.DashedWorld(v, f.Ox, f.Oy,
                        f.Ox + System.Math.Cos(ang) * FanLen, f.Oy + System.Math.Sin(ang) * FanLen,
                        Palette.A(Palette.Text, a * 0.9f), 0.8f);
                }
            }
            if (_fans.Count > 0)
            {
                var last = _fans[_fans.Count - 1];
                Draw.Label(v, last.Ox, last.Oy, "amber = client — white = server",
                    Palette.A(Palette.Text, 0.5f), 9, v.S(Sim.PlayerHalf) + 4);
            }

            int lastHits = -1;
            for (int i = _fans.Count - 1; i >= 0; i--)
                if (_fans[i].Answered) { lastHits = _fans[i].Hits; break; }

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("fan divergence (last shot)",
                _hasDivergence ? $"{_maxDivergence:F5} rad" : "--",
                !_hasDivergence ? Palette.TextFaint
                    : _maxDivergence < 1e-6 ? Palette.Good : Palette.Bad);
            h.Row("pellets hit (last shot)",
                lastHits >= 0 ? $"{lastHits} / {Sim.Pellets}" : "--",
                lastHits >= 0 ? Palette.Text : Palette.TextFaint);
            h.Row("room salt", Room.State.salt.ToString(), Palette.Text);
            h.Row("shots (authoritative)", _me.shots.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Key("mouse", "aim");
            h.Key("click / SPACE", "fire a 6-pellet fan");
            h.Key("X", _cheat ? "CHEATING with a local RNG" : "seeded from (seq, salt)");
            h.Note("Amber = the fan your client derived at the click. White dashes = the fan " +
                   "the server derived from the same (seq, salt). They should be identical to " +
                   "the pixel. Press X to swap in an unshared RNG and watch them disagree.");
        }

        /// <summary>Fire from the acceptance harness, exactly as a click would.</summary>
        public void Fire() => _pendingFire = true;
        public bool Cheat { get => _cheat; set => _cheat = value; }
        /// <summary>Worst client↔server pellet disagreement, in radians. NaN until answered.</summary>
        public double MaxDivergence => _hasDivergence ? _maxDivergence : double.NaN;
        public int AnsweredFans { get { int n = 0; foreach (var f in _fans) if (f.Answered) n++; return n; } }

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            Room.State.bots.TryGetValue("bot1", out _bot);
            Build();
        }
    }
}
