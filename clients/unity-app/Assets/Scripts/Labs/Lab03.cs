using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 03 — Predict &amp; Reconcile. The reconciler OBSERVES the input handle:
    /// every Send() is predicted locally the same instant and buffered. When the
    /// server's next patch acks input N, it rewinds to the authoritative state
    /// and REPLAYS inputs N+1.. through the same shared StepEntity — so the
    /// predicted pose stays consistent with everything the server hasn't seen.
    /// Port of labs/03-reconcile/.
    /// </summary>
    public class Lab03 : LabBase<Lab.MoveState>
    {
        public override string Id => "03-reconcile";
        public override int Num => 3;
        public override string Title => "Predict & Reconcile";
        public override string Blurb => "Rollback to the ack, replay pending inputs, smooth the error.";

        private readonly MoveLane _lane = new MoveLane();
        private bool _renderSmoothed = true, _showGhost = true;
        private readonly Spark _driftSpark = new Spark();
        private double _sparkGate;


        /// <summary>The lane, for the acceptance harness to read telemetry off.</summary>
        public MoveLane Lane => _lane;

        public override async Task<bool> Mount(App app)
        {
            if (!await _lane.Join(app)) return false;
            Room = _lane.Room;
            return true;
        }

        public override void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(KeyCode.I)) Room.Send("impulse");
            if (Kb.Key(KeyCode.T)) Room.Send("teleport");
            if (Kb.Key(KeyCode.V)) _renderSmoothed = !_renderSmoothed;
            if (Kb.Key(KeyCode.G)) _showGhost = !_showGhost;
            if (Kb.Key(KeyCode.N)) _lane.AutoSnap = !_lane.AutoSnap;
            int smoothStep = Kb.Key(KeyCode.Equals) ? 10 : Kb.Key(KeyCode.Minus) ? -10 : 0;
            if (smoothStep != 0)
                _lane.Build(Mathf.Clamp((float)(_lane.SmoothMs + smoothStep), 0, 200));

            _lane.Drive(now, Kb.MoveX(), Kb.MoveY());

            _sparkGate += dtMs;
            if (_sparkGate >= 100) { _sparkGate = 0; _driftSpark.Push(_lane.Recon.Drift.Ema); }
        }

        public override void Render(App app)
        {
            var v = app.View;
            var me = _lane.Me;
            Room.State.players.ForEach((key, p) =>
            {
                if (key == _lane.Sid) return;
                Draw.Square(v, _lane.RemoteX(p), _lane.RemoteY(p), Sim.PlayerHalf, Palette.Hue(p.hue, 0.45f));
            });

            // Server ghost: the raw authoritative pose — it trails by ~RTT.
            if (_showGhost)
            {
                Draw.GhostSquare(v, me.x, me.y, Sim.PlayerHalf, Palette.A(Palette.Text, 0.75f));
                Draw.Label(v, me.x, me.y, "server", Palette.A(Palette.Text, 0.55f), 11,
                    v.S(Sim.PlayerHalf) + 4);
            }

            double px = _renderSmoothed ? _lane.X : _lane.Recon.State.x;
            double py = _renderSmoothed ? _lane.Y : _lane.Recon.State.y;
            Draw.Square(v, px, py, Sim.PlayerHalf, Palette.Hue(me.hue));
            Draw.SquareOutline(v, px, py, Sim.PlayerHalf, Palette.Text);
            Draw.Label(v, px, py, "you (predicted)", Palette.Text, 11, -v.S(Sim.PlayerHalf) - 18);

            var recon = _lane.Recon;
            var status = DriftClassifier.Classify(recon.Drift, 0);
            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Chips("pending inputs (unacked)", recon.PendingCount);
            h.Row("drift status", status.ToString().ToLower(),
                status == DriftStatus.Matched ? Palette.Good :
                status == DriftStatus.Jitter ? Palette.Warn : Palette.Bad);
            h.Spark(_driftSpark, "drift ema", $"{recon.Drift.Ema:F4}", Palette.Accent);
            h.Row("last correction", $"{recon.LastCorrectionMag:F3}", Palette.Text);
            h.Row("corrections seen", _lane.Corrections.ToString(), Palette.Text);
            h.Row("reconciles", recon.ReconcileSeq.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Key("I", "force mispredict (impulse)");
            h.Key("T", "teleport");
            h.Key("- / =", $"smoothing {_lane.SmoothMs:F0} ms");
            h.Key("V", _renderSmoothed ? "render: Value() smoothed" : "render: State (exact)");
            h.Key("G", _showGhost ? "server ghost: on" : "server ghost: off");
            h.Key("N", _lane.AutoSnap ? "snap on teleport: on" : "snap on teleport: off");
            h.Note("Corrections beyond 8u call Reset() — a cut, not a cross-arena glide. " +
                   "Turn it off with N and teleport to see why.");
        }

        public override void Unmount() => _lane.Dispose();

        public override void OnReconnect() => _lane.Rebind();
    }
}
