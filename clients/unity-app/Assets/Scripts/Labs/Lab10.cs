using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 10 — Composite Sim (SimReconciler).
    ///
    /// The flat reconciler (lab 03) mirrors fields of ONE instance. Here the puck
    /// is a separate entity — yet your shots must feel instant, so the puck is
    /// predicted THROUGH your own inputs: every predicted paddle step also steps
    /// the puck and resolves the contact, in the server's exact order. On each
    /// ack both bound mirrors are re-seeded from authoritative state and the
    /// unacked inputs replay on top, so a predicted shot is re-derived from truth
    /// every reconcile.
    ///
    /// Remote paddles enter the prediction as COLLIDERS at their latest snapshot
    /// (their inputs aren't ours to predict), so a contested touch is the honest
    /// misprediction to watch for.
    ///
    /// Port of labs/10-composite-sim/. Both parts are BOUND to their decoded
    /// instances, so the store mirrors them and derives "paddle.x" / "puck.x"
    /// pose keys itself — the auto-binding path the fixture pins.
    /// </summary>
    public class Lab10 : LabBase<Lab.HockeyState>
    {
        public override string Id => "10-composite-sim";
        public override int Num => 10;
        public override string Title => "Composite Sim";
        public override string Blurb => "One rollback over a world of parts: paddle and puck together.";

        private Predict _predict;
        /// <summary>
        /// The simulated world. Both fields hold decoded instances at
        /// construction and are replaced in place by mirrors, so the step writes
        /// `w.paddle.x` against a real typed instance and the poses come out as
        /// "paddle.x" / "puck.x" — the same keys the JS reference and the
        /// fixtures use.
        /// </summary>
        public class HockeyWorld
        {
            public Lab.Player paddle;
            public Lab.Puck puck;
        }

        private SimReconciler<HockeyWorld, Lab.MoveInput> _sim;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Lab.Player _me;
        /// <summary>
        /// The DECODED puck, kept as the read handle. The sim swaps a mirror into
        /// the world, but this stays the SOURCE — which is what the bound overlay
        /// keys on, so Value(_puck, "x") resolves without anyone naming "puck.x".
        /// </summary>
        private Lab.Puck _puck;
        private string _sid;

        private double _smoothing = 15;
        private bool _showGhosts = true;
        private readonly Trail _puckTrail = new Trail(120);
        private readonly Spark _driftSpark = new Spark();
        private double _sparkGate;
        private int _touches;
        private bool _touchedLastStep;
        private int _retreatTicks;

        /// <summary>Fixed steps the autopilot spends heading home after a strike (20Hz -> ~0.6s).</summary>
        private const int RetreatTicks = 12;

        /// <summary>
        /// PEAK, not instantaneous. The predicted puck leads the server's by the
        /// unacked inputs, and that lead is largest right after a strike and
        /// collapses between them — a spot reading at an arbitrary instant says
        /// nothing, which is a trap the native port hit first.
        /// </summary>
        public double MaxPuckLead { get; private set; }
        /// <summary>Raw values behind the lead, so a failure can explain itself.</summary>
        public string DescribePuck() =>
            $"predicted=({_predict.Value(_puck, "x"):F2},{_predict.Value(_puck, "y"):F2}) " +
            $"server=({Room.State.puck.x:F2},{Room.State.puck.y:F2}) " +
            $"paddle=({_predict.Value(_me, "x"):F2},{_predict.Value(_me, "y"):F2})";
        public int Touches => _touches;
        public SimReconciler<HockeyWorld, Lab.MoveInput> Recon => _sim;
        /// <summary>
        /// Server-authoritative puck position — the harness's liveness probe.
        /// Exposed here because <c>Room</c> is protected on <see cref="LabBase{T}" />.
        /// </summary>
        public (double x, double y) ServerPuck() => (Room.State.puck.x, Room.State.puck.y);
        /// <summary>
        /// Switch the server's AI paddle on/off. The acceptance run turns it OFF:
        /// a contested touch mispredicts BY DESIGN (remote paddles enter the
        /// prediction at their last snapshot), so leaving the AI in makes the
        /// determinism check measure how often the bot happened to engage — the
        /// haxe port read 0.0013 to 0.72 across five runs, straddling the
        /// threshold. The native demo has always done this; the interactive
        /// build keeps its AI.
        /// </summary>
        public void SetBot(bool on) => Room.Send("bot", new { on });

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.HockeyState>(app, "lab-hockey",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId)
                     && r.State.puck != null);
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            _puck = Room.State.puck;
            if (_puck == null) return false;

            _predict = Predict.For(Room);
            // Remote paddles: damped toward the latest snapshot. They enter the
            // sim as colliders, not as predicted parts.
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            Build();
            app.SetLatencyPreset(2);   // a predicted shot says nothing on a 1 ms link
            return true;
        }

        private void Build()
        {
            // Dispose BEFORE respawning, like the reference: the old controller
            // would otherwise keep ticking against the same input handle.
            _sim?.Dispose();
            _sim = _predict.Sim(new SimReconcilerOptions<HockeyWorld, Lab.MoveInput>
            {
                Input = _input,
                Smoothing = _smoothing,
                World = new HockeyWorld { paddle = _me, puck = _puck },
                Step = Step,
            });
        }

        /// <summary>The server's step order, reproduced: my paddle → puck → contacts.</summary>
        private void Step(StepContext ctx, HockeyWorld w, Lab.MoveInput cmd)
        {
            var paddle = w.paddle;
            var puck = w.puck;

            var pad = new Sim.Entity { x = paddle.x, y = paddle.y, vx = paddle.vx, vy = paddle.vy };
            Sim.StepEntity(ref pad, cmd.moveX, cmd.moveY, ctx.Dt);
            paddle.x = (float)pad.x; paddle.y = (float)pad.y;
            paddle.vx = (float)pad.vx; paddle.vy = (float)pad.vy;

            var pk = new Sim.Entity { x = puck.x, y = puck.y, vx = puck.vx, vy = puck.vy };
            Sim.StepPuck(ref pk, ctx.Dt);

            bool touched = Sim.CollidePaddlePuck(pad.x, pad.y, pad.vx, pad.vy, ref pk);
            // Remote paddles (and the AI) are colliders at their last-known pose;
            // my own paddle is resolved from the PREDICTED mirror above. The order
            // is the players-map iteration order, which the server shares.
            Room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                if (Sim.CollidePaddlePuck(p.x, p.y, p.vx, p.vy, ref pk)) touched = true;
            });

            puck.x = (float)pk.x; puck.y = (float)pk.y;
            puck.vx = (float)pk.vx; puck.vy = (float)pk.vy;
            if (touched && !ctx.IsReplay) _touchedLastStep = true;
        }

        /// <summary>
        /// Where the predicted puck is relative to the predicted paddle — the
        /// harness steers by this. A lab-10 autopilot that just sweeps left and
        /// right never reaches the puck, and a puck nobody touches makes the
        /// whole lab look broken while proving nothing (the native port hit this
        /// first).
        /// </summary>
        /// <remarks>
        /// Backs off to its own half for a beat after each strike. Chasing without
        /// release traps the puck against a wall and holds it there: contacts
        /// re-eject it out of bounds every tick (StepPuck clamps, then the contact
        /// pushes it back out), so the world freezes with both sides in perfect
        /// agreement — and a drift check reads that as success.
        /// </remarks>
        private void SeekPuck(out int moveX, out int moveY)
        {
            double tx = _predict.Value(_puck, "x"), ty = _predict.Value(_puck, "y");
            if (_retreatTicks > 0) { tx = Sim.ArenaW / 2; ty = Sim.ArenaH * 0.75; }
            double dx = tx - _predict.Value(_me, "x");
            double dy = ty - _predict.Value(_me, "y");
            moveX = dx > 0.4 ? 1 : dx < -0.4 ? -1 : 0;
            moveY = dy > 0.4 ? 1 : dy < -0.4 ? -1 : 0;
        }

        public override void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(KeyCode.G)) _showGhosts = !_showGhosts;
            int smoothStep = Kb.Key(KeyCode.Equals) ? 5 : Kb.Key(KeyCode.Minus) ? -5 : 0;
            if (smoothStep != 0)
            {
                _smoothing = Mathf.Clamp((float)(_smoothing + smoothStep), 0, 40);
                Build();
            }

            int moveX = Kb.MoveX(), moveY = Kb.MoveY();
            if (Kb.Autopilot) SeekPuck(out moveX, out moveY);

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)moveX;
                _cmd.moveY = (sbyte)moveY;
                _input.Send();
                if (_retreatTicks > 0) _retreatTicks--;
                if (_touchedLastStep) { _touches++; _touchedLastStep = false; _retreatTicks = RetreatTicks; }
            }

            // How far the predicted puck leads the authoritative one.
            double dx = _predict.Value(_puck, "x") - Room.State.puck.x;
            double dy = _predict.Value(_puck, "y") - Room.State.puck.y;
            double lead = System.Math.Sqrt(dx * dx + dy * dy);
            if (lead > MaxPuckLead) MaxPuckLead = lead;

            _puckTrail.Push(_predict.Value(_puck, "x"), _predict.Value(_puck, "y"));
            _sparkGate += dtMs;
            if (_sparkGate >= 100) { _sparkGate = 0; _driftSpark.Push(_sim.Drift.Ema); }
        }

        public override void Render(App app)
        {
            var v = app.View;
            var state = Room.State;

            // Remote paddles, smoothed.
            state.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Circle(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PaddleRadius, Palette.Hue(p.hue, 0.35f));
                Draw.CircleOutline(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PaddleRadius, Palette.Hue(p.hue, 0.8f));
            });

            // The authoritative pair, for comparison.
            if (_showGhosts)
            {
                Draw.CircleOutline(v, _me.x, _me.y, Sim.PaddleRadius,
                    Palette.A(Palette.Text, 0.35f), dashed: true);
                Draw.CircleOutline(v, state.puck.x, state.puck.y, Sim.PuckRadius,
                    Palette.A(Palette.Text, 0.45f), dashed: true);
                Draw.Label(v, state.puck.x, state.puck.y, "server puck",
                    Palette.A(Palette.Text, 0.45f), 9, v.S(Sim.PuckRadius) + 4);
            }

            _puckTrail.Render(v, Palette.Accent, 1.5f, 0.4f);

            double px = _predict.Value(_me, "x"), py = _predict.Value(_me, "y");
            Draw.Circle(v, px, py, Sim.PaddleRadius, Palette.Hue(_me.hue, 0.5f));
            Draw.CircleOutline(v, px, py, Sim.PaddleRadius, Palette.Text);
            Draw.Label(v, px, py, "you (predicted)", Palette.Text, 11, -v.S(Sim.PaddleRadius) - 16);

            double kx = _predict.Value(_puck, "x"), ky = _predict.Value(_puck, "y");
            Draw.Circle(v, kx, ky, Sim.PuckRadius, Palette.A(Palette.Accent, 0.9f));
            Draw.CircleOutline(v, kx, ky, Sim.PuckRadius, Palette.Accent);
            Draw.Label(v, kx, ky, "puck (predicted)", Palette.Accent, 10, -v.S(Sim.PuckRadius) - 14);

            var status = DriftClassifier.Classify(_sim.Drift, 0);
            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Chips("pending inputs (unacked)", _sim.PendingCount);
            h.Row("drift status", status.ToString().ToLower(),
                status == DriftStatus.Matched ? Palette.Good :
                status == DriftStatus.Jitter ? Palette.Warn : Palette.Bad);
            h.Spark(_driftSpark, "drift ema", $"{_sim.Drift.Ema:F4}", Palette.Accent);
            h.Row("puck lead (peak)", $"{MaxPuckLead:F2} u", Palette.Text);
            h.Row("last correction", $"{_sim.LastCorrectionMag:F3}", Palette.Text);
            h.Row("touches predicted", _touches.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive your paddle into the puck");
            h.Key("- / =", $"smoothing {_smoothing:F0} /s");
            h.Key("G", _showGhosts ? "server ghosts: on" : "server ghosts: off");
            h.Note("One rollback over TWO parts. Your paddle and the puck are " +
                   "predicted together, in the server's order, so a strike is " +
                   "instant — and re-derived from truth on every ack. Remote " +
                   "paddles are colliders at their last snapshot, so a contested " +
                   "touch is the honest misprediction.");
        }

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            Build();
            _puckTrail.Clear();
        }
    }
}
