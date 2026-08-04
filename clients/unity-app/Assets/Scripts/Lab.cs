using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;

namespace Playground
{
    /// <summary>
    /// Shell contract. Port of framework/lab.ts: the shell owns the room and
    /// hands it to the lab; labs never join and never leave.
    /// </summary>
    public interface ILab
    {
        string Id { get; }
        int Num { get; }
        string Title { get; }
        string Blurb { get; }

        /// <summary>
        /// The lab paints its own background, so the shell skips the shared arena.
        /// Only the split-screen hero needs this.
        /// </summary>
        bool OwnArena { get; }

        /// <summary>Join and wire up. The shell awaits this on lab switch.</summary>
        Task<bool> Mount(App app);

        /// <summary>Called from Update() — send inputs, advance prediction.</summary>
        void Frame(App app, double now, double dtMs);

        /// <summary>Called from OnGUI() — draw the arena overlay and the HUD.</summary>
        void Render(App app);

        /// <summary>Dispose predicts/reconcilers. Do NOT leave the room (shell does).</summary>
        void Unmount();

        /// <summary>
        /// After the SDK auto-reconnects a dropped transport. The reconnected
        /// room counts inputs from ZERO — reconcilers MUST reset here, or every
        /// reconcile replays the stale pre-drop backlog.
        /// </summary>
        void OnReconnect();

        /// <summary>
        /// Subscribe <see cref="OnReconnect"/> to the room's reconnect event —
        /// what main.ts does with `room.onReconnect(...)` after mount. The
        /// shell calls this once per successful Mount; it cannot wire the event
        /// itself because IRoom doesn't carry it (only the concrete
        /// Room&lt;T&gt; does, and LabBase is who knows T).
        /// </summary>
        void BindReconnect();

        /// <summary>
        /// The joined room, type-erased. Room&lt;T&gt; is invariant, so a generic
        /// accessor can only ever hand back the lab's own exact state type —
        /// `room as Room&lt;Schema&gt;` is null. The shell needs these two to leave
        /// the room and to draw the status bar without knowing that type.
        /// </summary>
        IRoom Room { get; }

        RoomClock Clock { get; }

        /// <summary>Typed access, for a caller that knows the lab's state type.</summary>
        Room<T> RoomOf<T>() where T : ColyseusSchema;
    }

    /// <summary>
    /// The boilerplate every lab would otherwise repeat: the four identity
    /// strings stay abstract (they ARE the lab), and everything mechanical —
    /// type-erasing the room, the clock, the no-op hooks — is settled once.
    /// Set <see cref="Room"/> in Mount; the rest follows from it.
    /// </summary>
    public abstract class LabBase<TState> : ILab where TState : ColyseusSchema
    {
        public abstract string Id { get; }
        public abstract int Num { get; }
        public abstract string Title { get; }
        public abstract string Blurb { get; }
        public virtual bool OwnArena => false;

        /// <summary>The joined room. Subclasses assign this in Mount.</summary>
        protected Room<TState> Room;

        IRoom ILab.Room => Room;
        public RoomClock Clock => Room?.Clock;
        public Room<T> RoomOf<T>() where T : ColyseusSchema => Room as Room<T>;

        public void BindReconnect()
        {
            if (Room == null) return;
            Room.OnReconnect -= OnReconnect;   // idempotent across re-mounts
            Room.OnReconnect += OnReconnect;
        }

        public abstract Task<bool> Mount(App app);
        public abstract void Frame(App app, double now, double dtMs);
        public abstract void Render(App app);
        public virtual void Unmount() { }
        public virtual void OnReconnect() { }
    }

    /// <summary>Everything the shell hands a lab.</summary>
    public class App
    {
        public Client Client;
        public WorldView View = new WorldView();
        public Hud Hud = new Hud();
        public Rect Stage;
        public bool PrivateRoom;

        /// <summary>
        /// Ask the shell for a latency preset on mount. Labs 00/01/03 make no
        /// point at all on a 1 ms localhost link, so they set one themselves.
        /// </summary>
        public void SetLatencyPreset(int index) => NetDelay.UsePreset(index);
    }

    /// <summary>
    /// WASD / arrows -> tri-state axes, exactly like framework/input.ts.
    /// The acceptance harness feeds the same accessors, so a lab never learns
    /// whether a human or a script is playing.
    /// </summary>
    public static class Kb
    {
        public static bool Autopilot;
        public static int AutoX, AutoY;
        public static KeyCode SynthKey = KeyCode.None;

        public static bool Key(KeyCode k)
        {
            if (SynthKey == k) { SynthKey = KeyCode.None; return true; }
            return Input.GetKeyDown(k);
        }

        public static int MoveX()
        {
            if (Autopilot) return AutoX;
            bool l = Input.GetKey(KeyCode.A) || Input.GetKey(KeyCode.LeftArrow);
            bool r = Input.GetKey(KeyCode.D) || Input.GetKey(KeyCode.RightArrow);
            return r != l ? (r ? 1 : -1) : 0;
        }

        public static int MoveY()
        {
            if (Autopilot) return AutoY;
            bool u = Input.GetKey(KeyCode.W) || Input.GetKey(KeyCode.UpArrow);
            bool d = Input.GetKey(KeyCode.S) || Input.GetKey(KeyCode.DownArrow);
            return d != u ? (d ? 1 : -1) : 0;
        }

        public static bool AnyMove() => MoveX() != 0 || MoveY() != 0;
    }

    /// <summary>
    /// Fixed-step accumulator for labs WITHOUT a reconciler: Predict.Tick() only
    /// paces once a reconciler adopts the fixed step, but a prediction-free
    /// client still has to send one input per server tick.
    /// </summary>
    public class Pacer
    {
        private double _acc, _last;
        private bool _started;
        private readonly double _stepMs;

        public Pacer(double stepMs) { _stepMs = stepMs; }

        public void Reset() { _acc = 0; _started = false; }

        public int Steps(double now)
        {
            if (!_started) { _started = true; _last = now; return 0; }
            _acc += now - _last;
            _last = now;
            int n = (int)(_acc / _stepMs);
            if (n > 5) { n = 5; _acc = 0; }   // hitch: drop the backlog
            else _acc -= n * _stepMs;
            return n;
        }
    }
}
