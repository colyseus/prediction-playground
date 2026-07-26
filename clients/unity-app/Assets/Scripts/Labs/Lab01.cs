using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 01 — Feel the Lag. No prediction at all: send one input per fixed
    /// server tick, render the player straight from decoded state. Every key
    /// press waits a full round trip, so the L latency presets are what make
    /// this lab say anything. Port of labs/01-feel-the-lag/.
    /// </summary>
    public class Lab01 : ILab
    {
        public string Id => "01-feel-the-lag";
        public int Num => 1;
        public string Title => "Feel the Lag";
        public string Blurb => "No prediction: every key press waits a full round trip.";

        private Room<Lab.MoveState> _room;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Pacer _pacer;
        private string _sid;

        private bool _damped;
        private double _damping = 12;
        private readonly System.Collections.Generic.Dictionary<string, Vector2> _smooth =
            new System.Collections.Generic.Dictionary<string, Vector2>();

        private enum Phase { Idle, Armed, Shown }
        private Phase _phase;
        private double _armT, _armX, _armY, _measured;

        public Room<T> RoomOf<T>() where T : ColyseusSchema => _room as Room<T>;

        public async Task<bool> Mount(App app)
        {
            _room = await Shell.JoinLab<Lab.MoveState>(app, "lab-move");
            _sid = _room.SessionId;
            _cmd = new Lab.MoveInput();
            _input = _room.Input(_cmd);
            _pacer = new Pacer(1000.0 / Sim.TickHz);
            return _room.State.players.ContainsKey(_sid);
        }

        public void Frame(App app, double now, double dtMs)
        {
            if (Kb.Key(KeyCode.R)) _damped = !_damped;
            if (Kb.Key(KeyCode.Minus) && _damping > 4) _damping -= 2;
            if (Kb.Key(KeyCode.Equals) && _damping < 30) _damping += 2;

            // One input per fixed server tick — no reconciler here, so a local
            // accumulator paces the sends.
            int steps = _pacer.Steps(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }

            double dt = System.Math.Min(0.1, dtMs / 1000.0);
            _room.State.players.ForEach((key, p) =>
            {
                if (!_smooth.TryGetValue(key, out var s)) s = new Vector2(p.x, p.y);
                float k = (float)(1 - System.Math.Exp(-_damping * dt));
                _smooth[key] = new Vector2(s.x + (p.x - s.x) * k, s.y + (p.y - s.y) * k);
            });

            // input->photon meter: arm on a key press while at rest, measure when
            // the RENDERED position first moves.
            if (_room.State.players.TryGetValue(_sid, out var me))
            {
                double speed = System.Math.Abs(me.vx) + System.Math.Abs(me.vy);
                if (_phase != Phase.Armed && Kb.AnyMove() && speed < 0.01)
                {
                    _phase = Phase.Armed; _armT = now; _armX = me.x; _armY = me.y;
                }
                else if (_phase == Phase.Armed)
                {
                    if (System.Math.Abs(me.x - _armX) > 0.03 || System.Math.Abs(me.y - _armY) > 0.03)
                    {
                        _measured = now - _armT;
                        _phase = Phase.Shown;
                    }
                    else if (!Kb.AnyMove() && now - _armT > 2000) _phase = Phase.Idle;
                }
                else if (_phase == Phase.Shown && !Kb.AnyMove() && speed < 0.01) _phase = Phase.Idle;
            }
        }

        public void Render(App app)
        {
            var v = app.View;
            _room.State.players.ForEach((key, p) =>
            {
                bool isMe = key == _sid;
                double rx = p.x, ry = p.y;
                if (_damped && _smooth.TryGetValue(key, out var s)) { rx = s.x; ry = s.y; }
                Draw.Square(v, rx, ry, Sim.PlayerHalf, Palette.Hue(p.hue, isMe ? 1f : 0.45f));
                if (isMe)
                {
                    Draw.SquareOutline(v, rx, ry, Sim.PlayerHalf, Palette.Text);
                    Draw.Label(v, rx, ry, "you", Palette.Text, 11, -v.S(Sim.PlayerHalf) - 18);
                }
            });

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("input -> motion", _measured > 0 ? $"{_measured:F0} ms" : "--",
                _measured > 0 ? Palette.Bad : Palette.TextFaint);
            h.Row("meter state", _phase == Phase.Armed ? "armed..." : _phase == Phase.Shown ? "measured" : "idle",
                _phase == Phase.Armed ? Palette.Warn : _phase == Phase.Shown ? Palette.Good : Palette.TextDim);
            h.Row("render strategy", _damped ? "damped" : "raw", Palette.Text);
            h.Row("damping", $"{_damping:F0} /s", Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Key("R", "raw <-> damped");
            h.Key("- / =", "damping");
            h.Note("raw = decoded server state verbatim. damped = smooth toward it (even laggier). " +
                   "predicted = Lab 03. Raise the latency preset with L and feel the difference.");
        }

        public void Unmount() { _smooth.Clear(); }

        public void OnReconnect() { _pacer.Reset(); _phase = Phase.Idle; }
    }
}
