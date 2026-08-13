using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 08 — Optimistic Events.
    ///
    /// The GOAL banner fires the instant your PREDICTED square crosses the line,
    /// then settles against the server:
    ///
    ///   predicted  ctx.Predict() inside the reconciler step. Fires on the LIVE
    ///              step only; rollback replays never re-fire it.
    ///   confirmed  the server's "goal" broadcast → Confirm().
    ///   rejected   no confirmation by the time the server processed past the
    ///              predicting input → grace-tick auto-reject → OnReject.
    ///
    /// The zone gate itself is SHARED deterministic sim over a reconciled tick
    /// field: whether you *entered* is never a misprediction — only the server's
    /// deny roll can reject the event. Port of labs/08-optimistic-events/.
    /// </summary>
    public class Lab08 : LabBase<Lab.GoalState>
    {
        public override string Id => "08-optimistic-events";
        public override int Num => 8;
        public override string Title => "Optimistic Events";
        public override string Blurb => "Instant feedback; confirm or reject.";

        private const int MaxRecords = 30;

        /// <summary>One optimistic event and how it settled.</summary>
        private struct Record
        {
            public double PredictedAt, SettledAt;
            public int Outcome;   // 0 pending, 1 confirmed, -1 rejected
        }

        private Predict _predict;
        private PredictedEventChannel<string> _goals;
        private Reconciler<Lab.GoalPlayer, Lab.MoveInput> _recon;
        private Lab.MoveInput _cmd;
        private InputHandle _input;
        private Lab.GoalPlayer _me;
        private string _sid;

        private readonly List<Record> _records = new List<Record>();
        private string _banner;
        private Color _bannerColor;
        private double _bannerT = double.NegativeInfinity;
        private int _denyRate;

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.GoalState>(app, "lab-goal",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId));
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;
            _denyRate = Room.State.denyRate;

            _predict = Predict.Get(Room);
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            _goals = _predict.DefineEvent(new PredictedEventChannelOptions<string>
            {
                OnPredict = _ =>
                {
                    Push(RoomClock.GetNow());
                    Banner("GOAL!", Palette.Good);
                },
                OnConfirm = _ => Settle(1),
                OnReject = _ => { Settle(-1); Banner("DENIED", Palette.Bad); },
            });

            Room.OnMessage<Dictionary<string, object>>("goal", msg =>
            {
                if (msg.TryGetValue("sid", out var sid) && (string)sid == _sid) _goals.Confirm();
            });

            _cmd = new Lab.MoveInput();
            _input = Room.Input(_cmd);
            Build();
            return true;
        }

        /// <summary>stepEntity + the shared score gate, with the sim-born event.</summary>
        private void Build()
        {
            _recon = _predict.Reconciler(_me, new ReconcilerOptions<Lab.GoalPlayer, Lab.MoveInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy", "scoreTicks" },
                Smoothing = 15,
                Step = (ctx, p, cmd) =>
                {
                    var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
                    Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
                    p.x = (float)e.x; p.y = (float)e.y; p.vx = (float)e.vx; p.vy = (float)e.vy;

                    int ticks = p.scoreTicks;
                    // Live-only: ctx.Predict is a no-op during rollback replay.
                    if (Sim.StepScoreGate(p.x, p.y, ref ticks)) ctx.Predict(_goals, "goal");
                    p.scoreTicks = (byte)ticks;
                },
            });
        }

        private void Banner(string text, Color color)
        {
            _banner = text;
            _bannerColor = color;
            _bannerT = RoomClock.GetNow();
        }

        private void Push(double now)
        {
            if (_records.Count == MaxRecords) _records.RemoveAt(0);
            _records.Add(new Record { PredictedAt = now });
        }

        /// <summary>Settle the oldest still-pending record.</summary>
        private void Settle(int outcome)
        {
            for (int i = 0; i < _records.Count; i++)
            {
                if (_records[i].Outcome != 0) continue;
                var r = _records[i];
                r.Outcome = outcome;
                r.SettledAt = RoomClock.GetNow();
                _records[i] = r;
                return;
            }
        }

        public override void Frame(App app, double now, double dtMs)
        {
            // The deny rate is room-wide, like the web slider.
            int denyStep = Kb.Key(KeyCode.Equals) ? 25 : Kb.Key(KeyCode.Minus) ? -25 : 0;
            if (denyStep != 0)
            {
                _denyRate = Mathf.Clamp(_denyRate + denyStep, 0, 100);
                Room.Send("denyRate", new Dictionary<string, int> { ["rate"] = _denyRate });
            }

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _input.Send();
            }
        }

        public override void Render(App app)
        {
            var v = app.View;
            var zone = new Rect(v.SX(Sim.GoalZoneX), v.SY(Sim.GoalZoneY),
                v.S(Sim.GoalZoneW), v.S(Sim.GoalZoneH));
            Draw.Rect(zone, Palette.A(Palette.Good, 0.12f));
            Draw.Line(new Vector2(zone.x, zone.y), new Vector2(zone.xMax, zone.y),
                Palette.A(Palette.Good, 0.5f), 1.5f);
            Draw.Line(new Vector2(zone.x, zone.yMax), new Vector2(zone.xMax, zone.yMax),
                Palette.A(Palette.Good, 0.5f), 1.5f);
            Draw.Line(new Vector2(zone.x, zone.y), new Vector2(zone.x, zone.yMax),
                Palette.A(Palette.Good, 0.5f), 1.5f);
            Draw.Label(v, Sim.GoalZoneX + Sim.GoalZoneW / 2, Sim.GoalZoneY, "GOAL",
                Palette.A(Palette.Good, 0.7f), 10, -14);

            Room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Square(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PlayerHalf, Palette.Hue(p.hue, 0.4f));
            });

            Draw.GhostSquare(v, _me.x, _me.y, Sim.PlayerHalf, Palette.A(Palette.Text, 0.4f));
            double px = _recon.Value("x"), py = _recon.Value("y");
            Draw.Square(v, px, py, Sim.PlayerHalf, Palette.Hue(_me.hue));
            Draw.SquareOutline(v, px, py, Sim.PlayerHalf, Palette.Text);

            double age = RoomClock.GetNow() - _bannerT;
            if (_banner != null && age < 1400)
            {
                float a = Mathf.Min(1f, (float)(3 * (1 - age / 1400)));
                Draw.Text(app.Stage.x, app.Stage.y + 40, app.Stage.width, _banner,
                    Palette.A(_bannerColor, a), 42, TextAnchor.UpperCenter);
            }

            int confirmed = 0, rejected = 0, pending = 0;
            double settleSum = 0;
            foreach (var r in _records)
            {
                if (r.Outcome == 1) { confirmed++; settleSum += r.SettledAt - r.PredictedAt; }
                else if (r.Outcome == -1) rejected++;
                else pending++;
            }

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("score (authoritative)", _me.score.ToString(), Palette.Text);
            h.Row("events predicted", _records.Count.ToString(), Palette.Text);
            h.Row("confirmed (avg settle)",
                confirmed > 0 ? $"{confirmed} ({settleSum / confirmed:F0} ms)" : "0",
                confirmed > 0 ? Palette.Good : Palette.TextFaint);
            h.Row("rejected", rejected.ToString(), rejected > 0 ? Palette.Bad : Palette.Text);
            h.Row("pending", pending.ToString(), pending > 0 ? Palette.Warn : Palette.Text);

            h.Section("RECENT EVENTS");
            for (int i = 0; i < 5; i++)
            {
                int idx = _records.Count - 1 - i;
                if (idx < 0) { h.Row($"event {i + 1}", "--", Palette.TextFaint); continue; }
                var r = _records[idx];
                if (r.Outcome == 0) h.Row($"event {i + 1}", "pending...", Palette.Warn);
                else h.Row($"event {i + 1}",
                    $"{(r.Outcome == 1 ? "confirmed" : "rejected")} +{r.SettledAt - r.PredictedAt:F0} ms",
                    r.Outcome == 1 ? Palette.Good : Palette.Bad);
            }

            h.Section("CONTROLS");
            h.Key("WASD", "run into the goal zone on the right");
            h.Key("- / =", $"server deny rate  {_denyRate} %");
            h.Note("The banner is optimistic — score is authoritative. Raise the deny rate " +
                   "and the banner goes up instantly, then retracts when the server stays silent.");
        }

        /// <summary>Events predicted so far, for the acceptance harness.</summary>
        public int PredictedCount => _records.Count;
        public int RejectedCount { get { int n = 0; foreach (var r in _records) if (r.Outcome == -1) n++; return n; } }
        public int ConfirmedCount { get { int n = 0; foreach (var r in _records) if (r.Outcome == 1) n++; return n; } }
        public int DenyRate => _denyRate;
        public void SetDenyRate(int rate)
        {
            _denyRate = Mathf.Clamp(rate, 0, 100);
            Room.Send("denyRate", new Dictionary<string, int> { ["rate"] = _denyRate });
        }

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            _goals.Clear();
            Build();
        }
    }
}
