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
    public class Lab03 : ILab
    {
        public string Id => "03-reconcile";
        public int Num => 3;
        public string Title => "Predict & Reconcile";
        public string Blurb => "Rollback to the ack, replay pending inputs, smooth the error.";

        private Room<Lab.MoveState> _room;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Predict _predict;
        private Reconciler<Lab.Player, Lab.MoveInput> _recon;
        private Lab.Player _me;
        private string _sid;

        private double _smoothing = 15;
        private bool _renderSmoothed = true, _showGhost = true, _autoSnap = true;
        private int _lastReconcileSeq, _corrections;
        private double _maxCorrMag;
        private readonly Spark _driftSpark = new Spark();
        private double _sparkGate;

        public Room<T> RoomOf<T>() where T : ColyseusSchema => _room as Room<T>;

        public async Task<bool> Mount(App app)
        {
            _room = await Shell.JoinLab<Lab.MoveState>(app, "lab-move");
            _sid = _room.SessionId;
            if (!_room.State.players.TryGetValue(_sid, out _me)) return false;

            _cmd = new Lab.MoveInput();
            _input = _room.Input(_cmd);
            _predict = new Predict(new PredictCallbacks<Lab.MoveState>(Colyseus.Schema.Callbacks.Get(_room)), _room.Clock);
            // Remote squares: damped toward the latest snapshot (their inputs are
            // not ours to predict — lab 04 explores these modes).
            _predict.AttachAll("players", new[] { "x", "y" },
                new PredictFieldOptions { Mode = PredictMode.Damped });
            MakeReconciler();
            return true;
        }

        private void MakeReconciler()
        {
            _recon = _predict.MakeReconciler(_me, new ReconcilerOptions<Lab.Player, Lab.MoveInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy" },
                Smoothing = _smoothing,
                // The SAME function the server runs — determinism is the contract.
                Step = (ctx, s, cmd) =>
                {
                    var e = new Sim.Entity { x = s.x, y = s.y, vx = s.vx, vy = s.vy };
                    Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
                    s.x = (float)e.x; s.y = (float)e.y; s.vx = (float)e.vx; s.vy = (float)e.vy;
                },
            });
            _lastReconcileSeq = 0;
        }

        public void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(KeyCode.I)) _room.Send("impulse");
            if (Kb.Key(KeyCode.T)) _room.Send("teleport");
            if (Kb.Key(KeyCode.V)) _renderSmoothed = !_renderSmoothed;
            if (Kb.Key(KeyCode.G)) _showGhost = !_showGhost;
            if (Kb.Key(KeyCode.N)) _autoSnap = !_autoSnap;
            int smoothStep = Kb.Key(KeyCode.Equals) ? 5 : Kb.Key(KeyCode.Minus) ? -5 : 0;
            if (smoothStep != 0)
            {
                _smoothing = Mathf.Clamp((float)(_smoothing + smoothStep), 0, 40);
                MakeReconciler();   // smoothing is taken at construction
            }

            // One call advances the whole stack and reports the input steps due.
            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }

            if (_recon.ReconcileSeq != _lastReconcileSeq)
            {
                _lastReconcileSeq = _recon.ReconcileSeq;
                double mag = _recon.LastCorrectionMag;
                if (mag > 0.02) { _corrections++; if (mag > _maxCorrMag) _maxCorrMag = mag; }
                if (_autoSnap && mag > Sim.TeleportSnapDist) _recon.Reset();
            }

            _sparkGate += dtMs;
            if (_sparkGate >= 100) { _sparkGate = 0; _driftSpark.Push(_recon.Drift.Ema); }
        }

        public void Render(App app)
        {
            var v = app.View;
            _room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Square(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PlayerHalf, Palette.Hue(p.hue, 0.45f));
            });

            // Server ghost: the raw authoritative pose — it trails by ~RTT.
            if (_showGhost)
            {
                Draw.GhostSquare(v, _me.x, _me.y, Sim.PlayerHalf, Palette.A(Palette.Text, 0.75f));
                Draw.Label(v, _me.x, _me.y, "server", Palette.A(Palette.Text, 0.55f), 11,
                    v.S(Sim.PlayerHalf) + 4);
            }

            double px = _renderSmoothed ? _recon.Value("x") : _recon.State.x;
            double py = _renderSmoothed ? _recon.Value("y") : _recon.State.y;
            Draw.Square(v, px, py, Sim.PlayerHalf, Palette.Hue(_me.hue));
            Draw.SquareOutline(v, px, py, Sim.PlayerHalf, Palette.Text);
            Draw.Label(v, px, py, "you (predicted)", Palette.Text, 11, -v.S(Sim.PlayerHalf) - 18);

            var status = DriftClassifier.Classify(_recon.Drift, 0);
            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Chips("pending inputs (unacked)", _recon.PendingCount);
            h.Row("drift status", status.ToString().ToLower(),
                status == DriftStatus.Matched ? Palette.Good :
                status == DriftStatus.Jitter ? Palette.Warn : Palette.Bad);
            h.Spark(_driftSpark, "drift ema", $"{_recon.Drift.Ema:F4}", Palette.Accent);
            h.Row("last correction", $"{_recon.LastCorrectionMag:F3}", Palette.Text);
            h.Row("corrections seen", _corrections.ToString(), Palette.Text);
            h.Row("reconciles", _recon.ReconcileSeq.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Key("I", "force mispredict (impulse)");
            h.Key("T", "teleport");
            h.Key("- / =", $"smoothing {_smoothing:F0} /s");
            h.Key("V", _renderSmoothed ? "render: Value() smoothed" : "render: State (exact)");
            h.Key("G", _showGhost ? "server ghost: on" : "server ghost: off");
            h.Key("N", _autoSnap ? "snap on teleport: on" : "snap on teleport: off");
            h.Note("Corrections beyond 8u call Reset() — a cut, not a cross-arena glide. " +
                   "Turn it off with N and teleport to see why.");
        }

        public void Unmount() { _recon?.Dispose(); }

        public void OnReconnect()
        {
            // Fresh connection = fresh input counter: drop the stale prediction
            // backlog and re-seed from authoritative state.
            if (_room.State.players.TryGetValue(_sid, out var me)) _me = me;
            _recon?.Dispose();
            MakeReconciler();
        }
    }
}
