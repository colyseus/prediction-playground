using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// The reconciled `lab-move` lane: join, predict, reconcile, send.
    ///
    /// Labs 00 and 03 are the SAME netcode behind different renderers — the split
    /// screen is a render-layer choice over one entity in one room, not a second
    /// protocol — so the lane lives here and neither lab owns it. Everything a
    /// renderer needs is a property; everything it must do per frame is
    /// <see cref="Drive"/>.
    /// </summary>
    public class MoveLane
    {
        public Room<Lab.MoveState> Room { get; private set; }
        public Predict Predict { get; private set; }
        public Reconciler<Lab.Player, Lab.MoveInput> Recon { get; private set; }
        /// <summary>The raw authoritative pose — it trails by ~RTT.</summary>
        public Lab.Player Me { get; private set; }
        public string Sid { get; private set; }

        /// <summary>Corrections past the noise floor, and the largest seen.</summary>
        public int Corrections { get; private set; }
        public double MaxCorrectionMag { get; private set; }

        /// <summary>Reset() on a teleport-class correction: a cut, not a glide.</summary>
        public bool AutoSnap = true;
        public double Smoothing { get; private set; } = 15;

        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private int _lastReconcileSeq;

        /// <summary>The predicted pose: what the local player should be looking at.</summary>
        public double X => Recon.Value("x");
        public double Y => Recon.Value("y");

        public async Task<bool> Join(App app)
        {
            Room = await Shell.JoinLab<Lab.MoveState>(app, "lab-move",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId));
            Sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(Sid, out var me)) return false;
            Me = me;

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            Predict = Predict.Get(Room);
            // Remote squares: damped toward the latest snapshot. Their inputs are
            // not ours to predict — lab 04 explores the modes.
            Predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });
            Build(Smoothing);
            return true;
        }

        /// <summary>Rebuild the reconciler — smoothing is taken at construction.</summary>
        public void Build(double smoothing)
        {
            Smoothing = smoothing;
            Recon = Predict.Reconciler(Me, new ReconcilerOptions<Lab.Player, Lab.MoveInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy" },
                Smoothing = smoothing,
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

        /// <summary>
        /// One frame of netcode: advance the stack, send the inputs it says are
        /// due, and fold in whatever the latest reconcile reported.
        /// </summary>
        public void Drive(double now, int moveX, int moveY)
        {
            int steps = Predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)moveX;
                _cmd.moveY = (sbyte)moveY;
                _input.Send();
            }

            if (Recon.ReconcileSeq == _lastReconcileSeq) return;
            _lastReconcileSeq = Recon.ReconcileSeq;
            double mag = Recon.LastCorrectionMag;
            if (mag > 0.02)
            {
                Corrections++;
                if (mag > MaxCorrectionMag) MaxCorrectionMag = mag;
            }
            if (AutoSnap && mag > Sim.TeleportSnapDist) Recon.Reset();
        }

        /// <summary>The predicted pose of a remote square (damped, not reconciled).</summary>
        public double RemoteX(Lab.Player p) => Predict.Value(p, "x");
        public double RemoteY(Lab.Player p) => Predict.Value(p, "y");

        /// <summary>
        /// After a reconnect. The reconnected room counts inputs from ZERO, so a
        /// reconciler carrying the pre-drop backlog would replay it on every
        /// reconcile — rebind to the fresh entity and start the buffer over.
        /// </summary>
        public void Rebind()
        {
            if (Room.State.players.TryGetValue(Sid, out var me)) Me = me;
            Build(Smoothing);
        }

        public void Dispose() => Predict?.Dispose();
    }
}
