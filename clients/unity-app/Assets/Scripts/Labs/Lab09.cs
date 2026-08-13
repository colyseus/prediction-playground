using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using UnityEngine;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// Lab 09 — Predicted Spawns.
    ///
    /// Click-to-fire feels instant because the client spawns an OPTIMISTIC local
    /// projectile the same frame; when the server's authoritative entity arrives
    /// (~RTT later) the store CORRELATES the two into one logical entry — same
    /// id, same sprite, no visual seam.
    ///
    ///   Owned      which server entities are mine to correlate (owner == me).
    ///              Foreign ones (the turret's) surface as server-only entries.
    ///   SpawnTime  measures each shot's exact input lead (bornMs − predictedAt),
    ///              so MY projectile keeps flying the shooter's timeline through
    ///              the handoff instead of snapping back by lead × velocity.
    ///   Step       the SAME shared flight function the server integrates.
    ///
    /// Port of labs/09-predicted-spawns/.
    /// </summary>
    public class Lab09 : LabBase<Lab.ProjectileState>
    {
        public override string Id => "09-predicted-spawns";
        public override int Num => 9;
        public override string Title => "Predicted Spawns";
        public override string Blurb => "Optimistic projectile → authoritative handoff.";

        /// <summary>A local projectile: the shared flight state, nothing more.</summary>
        private class Shot { public Sim.Entity E; }

        private Predict _predict;
        private PredictedSpawns<Lab.Projectile, Shot> _spawns;
        private Reconciler<Lab.Player, Lab.RangeInput> _recon;
        private Lab.RangeInput _cmd;
        private InputHandle _input;
        private Lab.Player _me;
        private string _sid;

        // Per-entry presentation state, keyed on the STABLE entry id.
        private readonly Dictionary<int, (bool wasPending, double flashT, double x, double y)> _slots
            = new Dictionary<int, (bool, double, double, double)>();

        /// <summary>Worst distance the sprite teleported across a handoff — see Sweep.</summary>
        public double MaxHandoffJump { get; private set; }

        private double _aimX = 50, _aimY = 20;
        private bool _pendingFire;
        private bool _optimistic = true;
        private double _lastLeadMs = double.NaN;
        private int _fired;
        private int _pending, _confirmed, _foreign;
        private readonly HashSet<int> _live = new HashSet<int>();

        public override async Task<bool> Mount(App app)
        {
            Room = await Shell.JoinLab<Lab.ProjectileState>(app, "lab-projectile",
                r => r.State.players != null && r.State.players.ContainsKey(r.SessionId));
            _sid = Room.SessionId;
            if (Room.State.players == null || !Room.State.players.TryGetValue(_sid, out _me)) return false;

            _predict = Predict.Get(Room);
            _predict.AttachAll("players", new AttachConfig {
                ["x"] = PredictMode.Damped, ["y"] = PredictMode.Damped,
            });

            _spawns = _predict.Spawns<Lab.Projectile, Shot>("projectiles",
                new PredictedSpawnsOptions<Lab.Projectile, Shot>
                {
                    Owned = p => p.owner == _sid,
                    SpawnTime = p => p.bornMs,
                    Step = (shot, dt) => Sim.StepProjectile(ref shot.E, dt),
                    // Also reckon the CONFIRMED entities. ReckonStep is the
                    // schema-typed twin of Step — same motion, other type.
                    Fields = new[] { "x", "y" },
                    ReckonStep = (p, dt, _) =>
                    {
                        var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
                        Sim.StepProjectile(ref e, dt);
                        p.x = (float)e.x; p.y = (float)e.y;
                        p.vx = (float)e.vx; p.vy = (float)e.vy;
                    },
                    ReadLocal = (shot, f) => f == "x" ? shot.E.x : shot.E.y,
                });

            _cmd = new Lab.RangeInput();
            _input = Room.Input(_cmd);
            Build();
            return true;
        }

        private void Build()
        {
            _recon = _predict.Reconciler(_me, new ReconcilerOptions<Lab.Player, Lab.RangeInput>
            {
                Input = _input,
                Fields = new[] { "x", "y", "vx", "vy" },
                Smoothing = 15,
                Step = (ctx, p, cmd) =>
                {
                    var e = new Sim.Entity { x = p.x, y = p.y, vx = p.vx, vy = p.vy };
                    Sim.StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
                    p.x = (float)e.x; p.y = (float)e.y; p.vx = (float)e.vx; p.vy = (float)e.vy;
                },
            });
        }

        public override void Frame(App app, double now, double dtMs)
        {
            var v = app.View;
            Vector2 mouse = new Vector2(UnityEngine.Input.mousePosition.x, Screen.height - UnityEngine.Input.mousePosition.y);
            bool overStage = mouse.x < app.Stage.xMax;
            if (overStage && !Kb.Autopilot)   // the acceptance script aims for itself
            {
                _aimX = v.WX(mouse.x);
                _aimY = v.WY(mouse.y);
            }
            if (overStage && UnityEngine.Input.GetMouseButtonDown(0)) _pendingFire = true;
            if (Kb.Key(KeyCode.Space)) _pendingFire = true;
            if (Kb.Key(KeyCode.O)) _optimistic = !_optimistic;

            int steps = _predict.Tick(now);
            for (int i = 0; i < steps; i++)
            {
                _cmd.moveX = (sbyte)Kb.MoveX();
                _cmd.moveY = (sbyte)Kb.MoveY();
                _cmd.aimX = (float)_aimX;
                _cmd.aimY = (float)_aimY;
                _cmd.fire = _pendingFire;
                _input.Send();
                if (!_pendingFire) continue;

                _fired++;
                if (_optimistic) FireOptimistic();
                _pendingFire = false;
            }

            Sweep(now);
        }

        /// <summary>
        /// Fold the store's entries into presentation state: which are pending,
        /// which just crossed the handoff, and what lead the crossing measured.
        /// This lives in Frame, not Render — a headless run has the same numbers.
        /// </summary>
        private void Sweep(double now)
        {
            _pending = _confirmed = _foreign = 0;
            _live.Clear();
            foreach (var e in _spawns.Entries())
            {
                _live.Add(e.Id);
                bool known = _slots.TryGetValue(e.Id, out var slot);
                double x = _spawns.Value(e, "x"), y = _spawns.Value(e, "y");

                if (!e.Confirmed)
                {
                    if (e.Local == null) continue;
                    _pending++;
                    _slots[e.Id] = (true, slot.flashT, x, y);
                    continue;
                }

                _confirmed++;
                if (e.Server != null && e.Server.owner != _sid) _foreign++;
                if (slot.wasPending)
                {
                    slot = (false, now, slot.x, slot.y);
                    if (e.LeadMs > 0) _lastLeadMs = e.LeadMs;
                    // How far the sprite TELEPORTED across the handoff.
                    // Un-reckoned, the confirmed entity renders at the last
                    // decoded snapshot — (age + lead) x speed behind the
                    // prediction, which is the visible snap-back.
                    if (known && !double.IsNaN(slot.x) && !double.IsNaN(x))
                    {
                        double dx = x - slot.x, dy = y - slot.y;
                        double d = System.Math.Sqrt(dx * dx + dy * dy);
                        if (d > MaxHandoffJump) MaxHandoffJump = d;
                    }
                }
                _slots[e.Id] = (slot.wasPending, slot.flashT, x, y);
            }
            PruneSlots(_live);
        }

        /// <summary>
        /// Spawn the optimistic local at the PREDICTED pose — the same origin the
        /// server will use once this input arrives.
        /// </summary>
        private void FireOptimistic()
        {
            double px = _recon.State.x, py = _recon.State.y;
            double dx = _aimX - px, dy = _aimY - py;
            double len = System.Math.Sqrt(dx * dx + dy * dy);
            if (len < 1e-9) len = 1;
            _spawns.Spawn(new Shot
            {
                E = new Sim.Entity
                {
                    x = px, y = py,
                    vx = dx / len * Sim.ProjectileSpeed,
                    vy = dy / len * Sim.ProjectileSpeed,
                },
            });
        }

        public override void Render(App app)
        {
            var v = app.View;
            double now = RoomClock.GetNow();

            Draw.Square(v, 50, 8, 2, Palette.A(Palette.Bad, 0.3f));
            Draw.SquareOutline(v, 50, 8, 2, Palette.Bad, 1.5f);
            Draw.Label(v, 50, 8, "turret (foreign shots)", Palette.Bad, 10, -v.S(2) - 16);

            Room.State.players.ForEach((key, p) =>
            {
                if (key == _sid) return;
                Draw.Square(v, _predict.Value(p, "x"), _predict.Value(p, "y"),
                    Sim.PlayerHalf, Palette.Hue(p.hue, 0.4f));
            });

            double mx = _recon.Value("x"), my = _recon.Value("y");
            Draw.Square(v, mx, my, Sim.PlayerHalf, Palette.Hue(_me.hue));
            Draw.SquareOutline(v, mx, my, Sim.PlayerHalf, Palette.Text);
            Draw.CircleOutline(v, _aimX, _aimY, 0.8, Palette.A(Palette.Text, 0.6f));

            // One render path across the handoff, keyed on the stable entry id:
            // Value() reads the stepped local while pending and the lead-aware
            // reckon once confirmed, so the same call covers both sides.
            foreach (var e in _spawns.Entries())
            {
                double x = _spawns.Value(e, "x"), y = _spawns.Value(e, "y");
                if (double.IsNaN(x) || double.IsNaN(y)) continue;
                if (!e.Confirmed)
                {
                    Draw.Circle(v, x, y, Sim.ProjectileRadius, Palette.A(Palette.Warn, 0.9f));
                    continue;
                }
                _slots.TryGetValue(e.Id, out var slot);
                bool flashing = now - slot.flashT < 350;
                Draw.Circle(v, x, y, Sim.ProjectileRadius * (flashing ? 1.8 : 1.0),
                    e.Server.owner == _sid ? Palette.A(Palette.Text, 0.95f) : Palette.A(Palette.Bad, 0.9f));
            }

            var h = app.Hud;
            h.Section("TELEMETRY");
            h.Row("pending (mine, unconfirmed)", _pending.ToString(),
                _pending > 0 ? Palette.Warn : Palette.Text);
            h.Row("confirmed entities", _confirmed.ToString(), Palette.Text);
            h.Row("of those, foreign", _foreign.ToString(), Palette.Text);
            h.Row("last measured input lead",
                double.IsNaN(_lastLeadMs) ? "--" : $"{_lastLeadMs:F0} ms",
                double.IsNaN(_lastLeadMs) ? Palette.TextFaint : Palette.Good);
            h.Row("shots fired", _fired.ToString(), Palette.Text);

            h.Section("CONTROLS");
            h.Key("WASD", "drive");
            h.Key("mouse", "aim");
            h.Key("click / SPACE", "fire");
            h.Key("O", _optimistic ? "optimistic spawn: on" : "optimistic spawn: OFF");
            h.Note("Amber = predicted local (pending) — white = confirmed (correlated) — " +
                   "red = foreign (the turret's; nobody predicted them). Turn optimistic off " +
                   "with O and your own shot only appears when the server's entity arrives, " +
                   "~RTT late.");
        }

        private void PruneSlots(HashSet<int> live)
        {
            if (_slots.Count == live.Count) return;
            var gone = new List<int>();
            foreach (var id in _slots.Keys) if (!live.Contains(id)) gone.Add(id);
            foreach (var id in gone) _slots.Remove(id);
        }

        /// <summary>Aim and fire from the acceptance harness, exactly as a click would.</summary>
        public void AimAt(double x, double y) { _aimX = x; _aimY = y; }
        public void Fire() => _pendingFire = true;
        public bool Optimistic { get => _optimistic; set => _optimistic = value; }
        public int Fired => _fired;
        public double LastLeadMs => _lastLeadMs;
        public int PendingSpawns => _pending;
        public int ConfirmedSpawns => _confirmed;

        public override void Unmount() => _predict?.Dispose();

        public override void OnReconnect()
        {
            if (!Room.State.players.TryGetValue(_sid, out _me)) return;
            _spawns.Clear();
            _slots.Clear();
            Build();
        }
    }
}
