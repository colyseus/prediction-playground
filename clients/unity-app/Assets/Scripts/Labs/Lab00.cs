using System.Threading.Tasks;
using Colyseus;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 00 — Lag vs Prediction (the hero).
    ///
    /// Runs lab 03's netcode VERBATIM — same room, same reconciler, same entity,
    /// via the shared <see cref="MoveLane"/>. The split screen is a RENDER-layer
    /// choice, not a different protocol: the top lane draws the raw decoded server
    /// state (what lab 01 draws), the bottom lane draws the reconciler's predicted
    /// pose (what lab 03 draws). Prediction is a client-side choice over the same
    /// authority. Port of labs/00-split/.
    /// </summary>
    public class Lab00 : LabBase<Lab.MoveState>
    {
        public override string Id => "00-split";
        public override int Num => 0;
        public override string Title => "Lag vs Prediction";
        public override string Blurb => "Same input, same server — the top lane waits, the bottom predicts.";

        /// <summary>The shell skips the shared arena: this lab paints two.</summary>
        public override bool OwnArena => true;

        /// <summary>
        /// Reversal-heavy autopilot legs — reversals are where the echo lane
        /// visibly keeps going the wrong way for a full round trip.
        /// </summary>
        private static readonly (int dx, int dy, double ms)[] Script =
        {
            (1, 0, 850), (-1, 0, 700), (1, 0, 550), (0, 1, 650), (0, -1, 700),
            (1, 1, 600), (-1, -1, 750), (-1, 0, 550), (1, 0, 800), (0, -1, 500),
        };

        private readonly MoveLane _lane = new MoveLane();
        private readonly Trail _topTrail = new Trail(120), _botTrail = new Trail(120);
        private readonly WorldView _top = new WorldView(), _bot = new WorldView();

        private bool _userDrove;
        private int _legIndex, _legX = 1, _legY;
        private double _legUntil;

        public MoveLane Lane => _lane;

        public override async Task<bool> Mount(App app)
        {
            if (!await _lane.Join(app)) return false;
            Room = _lane.Room;
            // The point of this lab is invisible on a 1 ms localhost link.
            app.SetLatencyPreset(3);
            return true;
        }

        /// <summary>Scripted strides, steered away from a wall when a leg would hug one.</summary>
        private void Autopilot(double now, double x, double y)
        {
            if (now < _legUntil) return;
            var leg = Script[_legIndex++ % Script.Length];
            _legX = leg.dx;
            _legY = leg.dy;
            if (x > Sim.ArenaW * 0.72 && _legX > 0) _legX = -1;
            else if (x < Sim.ArenaW * 0.28 && _legX < 0) _legX = 1;
            if (y > Sim.ArenaH * 0.72 && _legY > 0) _legY = -1;
            else if (y < Sim.ArenaH * 0.28 && _legY < 0) _legY = 1;
            _legUntil = now + leg.ms;
        }

        public override void Frame(App app, double now, double dtMs)
        {
            if (!_userDrove && Kb.AnyMove()) _userDrove = true;
            if (!_userDrove) Autopilot(now, _lane.X, _lane.Y);

            _lane.Drive(now,
                _userDrove ? Kb.MoveX() : _legX,
                _userDrove ? Kb.MoveY() : _legY);

            _topTrail.Push(_lane.Me.x, _lane.Me.y);
            _botTrail.Push(_lane.X, _lane.Y);
        }

        public override void Render(App app)
        {
            // Two lanes stacked in the stage rect.
            float laneH = app.Stage.height / 2, lanePad = 22;
            _top.Fit(new Rect(app.Stage.x, app.Stage.y + lanePad, app.Stage.width, laneH - lanePad), 26);
            _bot.Fit(new Rect(app.Stage.x, app.Stage.y + laneH, app.Stage.width, laneH - lanePad), 26);

            var me = _lane.Me;
            double px = _lane.X, py = _lane.Y;

            Draw.Arena(_top);
            LaneTitle(_top, "SERVER ECHO", "every move waits the full round trip",
                Palette.A(Palette.Text, 0.85f));
            DrawRemotes(_top, predicted: false);
            _topTrail.Render(_top, Palette.A(Palette.Text, 1f), 1.5f, 0.35f);
            Draw.Square(_top, me.x, me.y, Sim.PlayerHalf, Palette.Hue(me.hue, 0.8f));
            Draw.SquareOutline(_top, me.x, me.y, Sim.PlayerHalf, Palette.A(Palette.Text, 0.5f));
            Draw.Label(_top, me.x, me.y, "you (server)", Palette.A(Palette.Text, 0.6f), 11,
                -_top.S(Sim.PlayerHalf) - 15);

            Draw.Arena(_bot);
            LaneTitle(_bot, "PREDICTED", "instant — reconciled against the same server", Palette.Good);
            DrawRemotes(_bot, predicted: true);
            _botTrail.Render(_bot, Palette.Hue(me.hue), 1.5f, 0.45f);
            Draw.Square(_bot, px, py, Sim.PlayerHalf, Palette.Hue(me.hue));
            Draw.SquareOutline(_bot, px, py, Sim.PlayerHalf, Palette.Text);
            Draw.Label(_bot, px, py, "you (predicted)", Palette.Text, 11,
                -_bot.S(Sim.PlayerHalf) - 15);

            // Divider readout, with the rule broken around the text.
            double rtt = Room.Clock.SmoothedRtt();
            string readout = $"ROUND TRIP ~ {rtt:F0} ms";
            float dividerY = app.Stage.y + laneH;
            float cx = app.Stage.x + app.Stage.width / 2;
            var rule = Palette.A(Palette.TextDim, 0.25f);
            Draw.Line(new Vector2(app.Stage.x + 24, dividerY), new Vector2(cx - 90, dividerY), rule);
            Draw.Line(new Vector2(cx + 90, dividerY),
                new Vector2(app.Stage.xMax - 24, dividerY), rule);
            Draw.Text(cx - 90, dividerY - 9, 180, readout, Palette.Accent, 13, TextAnchor.MiddleCenter);

            string caption = _userDrove
                ? "Same keys, same server — the top lane waits, the bottom predicts."
                : "› autopilot — press WASD / arrows to take over";
            Draw.Text(app.Stage.x, app.Stage.yMax - 20, app.Stage.width, caption,
                Palette.A(Palette.TextDim, 0.85f), 12, TextAnchor.MiddleCenter);

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("round trip", $"{rtt:F0} ms",
                rtt > 300 ? Palette.Bad : rtt > 120 ? Palette.Warn : Palette.Good);
            double gap = Vector2.Distance(new Vector2((float)px, (float)py), new Vector2(me.x, me.y));
            h.Row("echo trails you by", $"{gap:F1} units", Palette.Text);
            h.Chips("pending inputs (unacked)", _lane.Recon.PendingCount);

            h.Section("CONTROLS");
            h.Key("WASD", _userDrove ? "drive (autopilot off)" : "take over from the autopilot");
            h.Key("L", "injected latency");
            h.Note("Render-only split: both lanes are the same entity in the same room, " +
                   "running lab 03's netcode verbatim.");
        }

        /// <summary>Titles sit INSIDE the arena — the lane above it is only padding.</summary>
        private static void LaneTitle(WorldView v, string main, string sub, Color c)
        {
            Draw.Text(v.SX(0) + 10, v.SY(0) + 6, 200, main, c, 12);
            Draw.Text(v.SX(0) + 10 + 110, v.SY(0) + 7, 340, sub, Palette.A(Palette.TextDim, 0.75f), 11);
        }

        private void DrawRemotes(WorldView v, bool predicted)
        {
            Room.State.players.ForEach((key, p) =>
            {
                if (key == _lane.Sid) return;
                double x = predicted ? _lane.RemoteX(p) : p.x;
                double y = predicted ? _lane.RemoteY(p) : p.y;
                Draw.Square(v, x, y, Sim.PlayerHalf, Palette.Hue(p.hue, 0.4f));
            });
        }

        public override void Unmount() => _lane.Dispose();

        public override void OnReconnect()
        {
            _lane.Rebind();
            _topTrail.Clear();
            _botTrail.Clear();
        }
    }
}
