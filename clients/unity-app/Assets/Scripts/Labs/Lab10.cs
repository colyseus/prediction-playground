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
        private SimReconciler<Lab.MoveInput> _sim;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Lab.Player _me;
        private string _sid;

        private double _smoothing = 15;
        private bool _showGhosts = true;
        private readonly Trail _puckTrail = new Trail(120);
        private readonly Spark _driftSpark = new Spark();
        private double _sparkGate;
        private int _touches;
        private bool _touchedLastStep;

        /// <summary>
        /// PEAK, not instantaneous. The predicted puck leads the server's by the
        /// unacked inputs, and that lead is largest right after a strike and
        /// collapses between them — a spot reading at an arbitrary instant says
        /// nothing, which is a trap the native port hit first.
        /// </summary>
        public double MaxPuckLead { get; private set; }
        /// <summary>Raw values behind the lead, so a failure can explain itself.</summary>
        public string DescribePuck() =>
            $"predicted=({_sim.Value("puck.x"):F2},{_sim.Value("puck.y"):F2}) " +
            $"server=({Room.State.puck.x:F2},{Room.State.puck.y:F2}) " +
            $"paddle=({_sim.Value("paddle.x"):F2},{_sim.Value("paddle.y"):F2})";
        public int Touches => _touches;
        public SimReconciler<Lab.MoveInput> Recon => _sim;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.HockeyState>(app, "lab-hockey",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId)
                     && r.State.puck != null);
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            if (Room.State.puck == null) return false;

            _predict = Predict.For(Room);
            // Remote paddles: damped toward the latest snapshot. They enter the
            // sim as colliders, not as predicted parts.
            _predict.AttachAll("players", new[] { "x", "y" },
                new PredictFieldOptions { Mode = PredictMode.Damped });

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            Build();
            app.SetLatencyPreset(2);   // a predicted shot says nothing on a 1 ms link
            return true;
        }

        private void Build()
        {
            _sim = _predict.MakeSimReconciler(new SimReconcilerOptions<Lab.MoveInput>
            {
                Input = _input,
                Smoothing = _smoothing,
                Parts = new[]
                {
                    new SimPart { Name = "paddle", Source = _me },
                    new SimPart { Name = "puck", Source = Room.State.puck },
                },
                Step = Step,
            });
        }

        /// <summary>The server's step order, reproduced: my paddle → puck → contacts.</summary>
        private void Step(StepContext ctx, SimWorld world, Lab.MoveInput cmd)
        {
            var paddle = world.Part<Lab.Player>("paddle");
            var puck = world.Part<Lab.Puck>("puck");

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
        private void SeekPuck(out int moveX, out int moveY)
        {
            double dx = _sim.Value("puck.x") - _sim.Value("paddle.x");
            double dy = _sim.Value("puck.y") - _sim.Value("paddle.y");
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
                if (_touchedLastStep) { _touches++; _touchedLastStep = false; }
            }

            // How far the predicted puck leads the authoritative one.
            double dx = _sim.Value("puck.x") - Room.State.puck.x;
            double dy = _sim.Value("puck.y") - Room.State.puck.y;
            double lead = System.Math.Sqrt(dx * dx + dy * dy);
            if (lead > MaxPuckLead) MaxPuckLead = lead;

            _puckTrail.Push(_sim.Value("puck.x"), _sim.Value("puck.y"));
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

            double px = _sim.Value("paddle.x"), py = _sim.Value("paddle.y");
            Draw.Circle(v, px, py, Sim.PaddleRadius, Palette.Hue(_me.hue, 0.5f));
            Draw.CircleOutline(v, px, py, Sim.PaddleRadius, Palette.Text);
            Draw.Label(v, px, py, "you (predicted)", Palette.Text, 11, -v.S(Sim.PaddleRadius) - 16);

            double kx = _sim.Value("puck.x"), ky = _sim.Value("puck.y");
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
