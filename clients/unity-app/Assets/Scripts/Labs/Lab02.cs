using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 02 — Clocks &amp; Timelines. There is no clock "API call" to make: the
    /// moment the server declares defineInput(), every input round-trip carries a
    /// TIMED prefix and the SDK maintains room.Clock. This lab just reads it —
    /// Now / ServerNow / RenderNow / Rtt / SmoothedRtt / Jitter / LastServerTime.
    /// Port of labs/02-clocks/.
    /// </summary>
    public class Lab02 : ILab
    {
        private const double StripSpanMs = 3000;

        public string Id => "02-clocks";
        public int Num => 2;
        public string Title => "Clocks & Timelines";
        public string Blurb => "serverNow / renderNow / RTT / jitter.";

        private Room<Lab.BotsState> _room;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Pacer _pacer;
        private string _sid;
        private Lab.Bot _bot;

        private readonly List<double> _arrivals = new List<double>();
        private double _lastPatchStamp, _sparkGate;
        private readonly Spark _rtt = new Spark(), _age = new Spark(), _slew = new Spark();

        public Room<T> RoomOf<T>() where T : ColyseusSchema => _room as Room<T>;

        public async Task<bool> Mount(App app)
        {
            _room = await Shell.JoinLab<Lab.BotsState>(app, "lab-bots");
            _sid = _room.SessionId;
            if (!_room.State.bots.TryGetValue("bot1", out _bot)) return false;
            _cmd = new Lab.MoveInput();
            // Inputs feed the clock: one send per fixed tick = one RTT/offset sample.
            _input = _room.Input(_cmd);
            _pacer = new Pacer(1000.0 / Sim.TickHz);
            return true;
        }

        public void Frame(App app, double now, double dtMs)
        {
            int steps = _pacer.Steps(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }

            // A patch arrival = the server stamp changing.
            double stamp = _room.Clock.LastServerTime();
            if (stamp != _lastPatchStamp)
            {
                _lastPatchStamp = stamp;
                _arrivals.Add(now);
                if (_arrivals.Count > 128) _arrivals.RemoveAt(0);
            }

            _age.Push(System.Math.Max(0, _room.Clock.ServerNow() - stamp));
            _sparkGate += dtMs;
            if (_sparkGate >= 200)
            {
                _sparkGate = 0;
                _rtt.Push(_room.Clock.Rtt());
                _slew.Push(System.Math.Abs(_room.Clock.ServerNow() - _room.Clock.RenderNow()));
            }
        }

        public void Render(App app)
        {
            var v = app.View;
            _room.State.players.ForEach((key, p) =>
                Draw.Square(v, p.x, p.y, Sim.PlayerHalf, Palette.Hue(p.hue, key == _sid ? 0.9f : 0.4f)));

            Draw.CircleOutline(v, _bot.x, _bot.y, Sim.BotRadius, Palette.Text, dashed: true);
            Draw.Label(v, _bot.x, _bot.y, "raw snapshots (patch rate)",
                Palette.A(Palette.Text, 0.6f), 10, -v.S(Sim.BotRadius) - 18);

            // Patch-arrival strip along the bottom of the stage.
            float x0 = app.Stage.x + 24, x1 = app.Stage.xMax - 20, y = app.Stage.yMax - 34;
            if (x1 - x0 > 200)
            {
                Draw.Line(new Vector2(x0, y), new Vector2(x1, y), Palette.A(Palette.TextDim, 0.3f));
                double now = RoomClock.GetNow();
                foreach (double t in _arrivals)
                {
                    double age = now - t;
                    if (age > StripSpanMs) continue;
                    float px = x1 - (float)(age / StripSpanMs) * (x1 - x0);
                    Draw.Rect(new Rect(px - 2, y - 2, 4, 4), Palette.Good);
                }
                var s = new GUIStyle(GUI.skin.label) { fontSize = 10, normal = { textColor = Palette.A(Palette.Text, 0.55f) } };
                GUI.Label(new Rect(x0, y - 18, 420, 14), "patch arrivals (local clock, last 3 s) ->", s);
            }

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Spark(_rtt, "rtt", $"{_rtt.Last:F0} ms", Palette.Blue);
            h.Spark(_age, "patch age (sawtooth)", $"{_age.Last:F0} ms", Palette.Good);
            h.Spark(_slew, "|serverNow - renderNow| (slew)", $"{_slew.Last:F1} ms", Palette.Warn);
            h.Row("serverNow", $"{_room.Clock.ServerNow():F0} ms", Palette.Text);
            h.Row("renderNow (slewed)", $"{_room.Clock.RenderNow():F0} ms", Palette.Text);
            h.Row("jitter (interarrival)", $"{_room.Clock.Jitter():F1} ms", Palette.Text);
            h.Row("smoothed rtt", $"{_room.Clock.SmoothedRtt():F0} ms", Palette.Text);
            h.Row("patch interval", $"{_room.Clock.PatchInterval():F0} ms", Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Note("Nothing to configure here — yank the latency preset with L and watch every " +
                   "readout respond. The offset re-converges; the slew spike decays over ~250 ms. " +
                   "The dot row marks each PATCH ARRIVAL on the local clock: add jitter and watch " +
                   "the spacing get ragged.");
        }

        public void Unmount() { _arrivals.Clear(); }

        public void OnReconnect()
        {
            _pacer.Reset();
            _arrivals.Clear();
            _lastPatchStamp = 0;
            _room.State.bots.TryGetValue("bot1", out _bot);
        }
    }
}
