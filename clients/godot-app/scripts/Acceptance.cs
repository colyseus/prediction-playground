using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using Godot;
using Lab = PredictProbe.LabSchema;

namespace Playground
{
    /// <summary>
    /// The Godot twin of unity-app's PlayMode AcceptanceTest: APPS_PLAN §7's
    /// exit criteria, replayed against the LIVE server with no hands on the
    /// keyboard. Needs `pnpm dev --host 0.0.0.0` running.
    ///
    ///   godot --headless --path clients/godot-app res://Acceptance.tscn
    ///
    /// Same checks, same thresholds, same failure messages as the Unity suite —
    /// NUnit's role is played by <see cref="Check"/>, and PlayMode coroutines by
    /// async methods awaiting <see cref="NextFrame"/> (the Godot sync context
    /// resumes them on the main thread, which is what makes NetDelay's
    /// single-threaded pump contract hold here too). Exits 0 on green.
    /// </summary>
    public partial class Acceptance : Node
    {
        private const string Endpoint = "ws://localhost:5173";
        private const double TestTimeoutMs = 120000;

        /// <summary>Frames driven, so allocation can be measured per FRAME.</summary>
        private long _drivenFrames;

        private TaskCompletionSource _frame = NewFrameSource();
        private double _testStart;
        private bool _watchdogArmed;
        private int _passed, _total;
        private readonly List<string> _failures = new List<string>();

        private sealed class CheckFailed : Exception
        {
            public CheckFailed(string m) : base(m) { }
        }

        private static void Check(bool cond, string msg)
        {
            if (!cond) throw new CheckFailed(msg);
        }

        private static TaskCompletionSource NewFrameSource()
            => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        public override void _Ready() => _ = RunAll();

        public override void _Process(double delta)
        {
            if (_watchdogArmed && RoomClock.GetNow() - _testStart > TestTimeoutMs)
            {
                GD.PrintErr("ACCEPT FAIL: test exceeded the 120 s watchdog");
                GetTree().Quit(1);
                _watchdogArmed = false;
                return;
            }
            var f = _frame;
            _frame = NewFrameSource();
            f.TrySetResult();
        }

        private Task NextFrame() => _frame.Task;

        private static Client MakeClient() => new Client(Endpoint);

        /// <summary>Pump the injector + a lab for `ms`, exactly like _Process does.</summary>
        private async Task Drive(ILab lab, App app, double ms, int autoX = 0, int autoY = 0,
            Action<double> onFrame = null)
        {
            Kb.Autopilot = true;
            Kb.AutoX = autoX;
            Kb.AutoY = autoY;
            double start = RoomClock.GetNow(), last = start;
            while (RoomClock.GetNow() - start < ms)
            {
                NetDelay.PumpAll();
                double now = RoomClock.GetNow();
                lab?.Frame(app, now, now - last);
                last = now;
                _drivenFrames++;
                onFrame?.Invoke(now - start);
                await NextFrame();
            }
        }

        /// <summary>
        /// Spin until `task` completes — pumping the injector every frame. The pump
        /// is load-bearing, not hygiene: a join resolves on the inbound JOIN_ROOM
        /// frame and a leave on the inbound close, and the injector is holding both.
        /// Awaiting without draining deadlocks on any nonzero latency.
        /// </summary>
        private async Task Await(Task task, string what, double timeoutMs = 20000)
        {
            double start = RoomClock.GetNow();
            while (!task.IsCompleted)
            {
                NetDelay.PumpAll();
                Check(RoomClock.GetNow() - start <= timeoutMs,
                    $"{what}: still pending after {timeoutMs:F0} ms " +
                    $"({NetDelay.InFlight()} pkt in the injector)");
                await NextFrame();
            }
            if (task.IsFaulted) throw task.Exception;
        }

        /// <summary>Join, then wait out the join round trip. Fails loudly on timeout.</summary>
        private async Task Mount(ILab lab, App app)
        {
            GD.Print($"[acceptance] mounting {lab.Id}");
            var mount = lab.Mount(app);
            await Await(mount, $"{lab.Id} mount");
            Check(mount.Result, $"{lab.Id} joined but its state never arrived");
            GD.Print($"[acceptance] mounted {lab.Id}");
        }

        private async Task Teardown(ILab lab)
        {
            lab.Unmount();
            await Await(lab.Room.Leave(true), $"{lab.Id} leave");
        }

        private async Task RunAll()
        {
            await NextFrame();   // let the tree settle before the first join

            var tests = new (string name, Func<Task> run)[]
            {
                ("sim_reproduces_the_reference_numbers", SimSelfCheck),
                ("connection_seam_allocates_nothing_per_message", ConnectionSeam),
                ("lab01_input_to_motion_tracks_the_round_trip", Lab01Meter),
                ("lab02_clock_readouts_respond_to_injected_latency", Lab02Clocks),
                ("lab03_predicts_instantly_and_absorbs_a_mispredict", Lab03Reconcile),
                ("steady_state_traffic_does_not_churn_the_heap", SteadyStateGc),
                ("lab00_predicted_lane_leads_the_server_echo", Lab00Split),
                ("lab04_interpolation_modes_differ_as_advertised", Lab04Modes),
                ("lab05_reckon_leads_the_lerp_view", Lab05Reckon),
                ("lab06_lag_comp_hits_what_you_saw", Lab06LagComp),
                ("lab07_frozen_verdict_matches_the_server", Lab07Wysiwyg),
                ("lab08_events_fire_instantly_then_settle", Lab08Events),
                ("lab09_optimistic_spawn_hands_off_to_the_server", Lab09Spawns),
                ("lab10_predicts_the_puck_through_your_own_inputs", Lab10Composite),
                ("lab11_client_and_server_roll_identical_pellets", Lab11Rng),
            };
            _total = tests.Length;

            foreach (var (name, run) in tests)
            {
                NetDelay.Reset();
                Kb.Autopilot = true;
                Kb.AutoX = Kb.AutoY = 0;
                _testStart = RoomClock.GetNow();
                _watchdogArmed = true;
                try
                {
                    await run();
                    _passed++;
                    GD.Print($"PASS {name}");
                }
                catch (Exception e)
                {
                    string msg = (e as AggregateException)?.InnerException?.Message ?? e.Message;
                    _failures.Add($"{name}: {msg}");
                    GD.PrintErr($"FAIL {name}: {msg}");
                }
                _watchdogArmed = false;
            }

            Kb.Autopilot = false;
            GD.Print(_failures.Count == 0
                ? $"ACCEPT OK {_passed}/{_total}"
                : $"ACCEPT FAIL {_passed}/{_total}");
            foreach (var f in _failures) GD.Print("  " + f);
            GetTree().Quit(_failures.Count == 0 ? 0 : 1);
        }

        // ------------------------------------------------------------- tests

        private Task SimSelfCheck()
        {
            // The canary the native app runs as --selfcheck: a constant typo can
            // never ship silently.
            Check(Sim.SelfCheck() == 0, "shared-sim port diverged from the TypeScript original");
            return Task.CompletedTask;
        }

        private Task ConnectionSeam()
        {
            // The precise question: does putting the injector in front of
            // Connection.Dispatch cost a heap object per message? No server needed —
            // drive synthetic events straight through the seam and weigh the heap.
            var conn = new Connection("ws://localhost:1", null);
            int delivered = 0;
            conn.OnMessage += _ => delivered++;
            NetDelay.Reset();
            NetDelay.SetLatency(0, 0);
            NetDelay.Wrap(conn);

            var payload = new byte[64];
            for (int i = 0; i < 512; i++) { conn.Dispatch(ConnectionEvent.Received(payload)); NetDelay.PumpAll(); }

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            long before = GC.GetTotalMemory(false);

            const int N = 20000;
            for (int i = 0; i < N; i++) { conn.Dispatch(ConnectionEvent.Received(payload)); NetDelay.PumpAll(); }

            double perMessage = (GC.GetTotalMemory(false) - before) / (double)N;
            Check(delivered == 512 + N, "the seam dropped or duplicated messages");
            GD.Print($"OK gc seam: {perMessage:F2} B/message over {N} round trips");
            Check(perMessage < 8,
                $"the injector allocates {perMessage:F1} B per message — a closure or a " +
                "copy crept back into the per-packet path");
            NetDelay.Reset();
            return Task.CompletedTask;
        }

        private async Task Lab01Meter()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(0, 0);
            var lab = new Lab01();
            await Mount(lab, app);

            // At rest first: the meter arms on a key press from a standstill.
            await Drive(lab, app, 800);
            await Drive(lab, app, 1600, autoX: 1);
            double atZero = lab.Measured;
            Check(atZero > 0, "meter never armed at 0 injected latency");
            Check(atZero < 250, $"input->motion {atZero:F0} ms at 0 injected — expected ~one patch interval");

            // Now with 200 ms each way; no prediction, so it must track the round trip.
            await Drive(lab, app, 900);
            NetDelay.SetLatency(200, 0);
            await Drive(lab, app, 1200);
            await Drive(lab, app, 2000, autoX: -1);
            double at200 = lab.Measured;
            Check(at200 > 300, $"input->motion {at200:F0} ms at 200 ms injected — latency not felt");
            GD.Print($"OK lab01: {atZero:F0} ms at 0 injected, {at200:F0} ms at 200 ms");

            await Teardown(lab);
        }

        private async Task Lab02Clocks()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(200, 0);
            var lab = new Lab02();
            await Mount(lab, app);

            await Drive(lab, app, 4000, autoX: 1);
            var clock = lab.RoomOf<Lab.BotsState>().Clock;
            Check(clock.SmoothedRtt() > 350,
                $"smoothed rtt {clock.SmoothedRtt():F0} ms — the injector is not in the path");
            Check(clock.LastServerTime() > 0, "no TIMED prefix: the clock never synced");
            Check(clock.PatchInterval() > 0, "patch cadence never advertised");
            GD.Print($"OK lab02: rtt {clock.SmoothedRtt():F0} ms, patch {clock.PatchInterval():F0} ms, " +
                     $"jitter {clock.Jitter():F1} ms");

            await Teardown(lab);
        }

        private async Task Lab03Reconcile()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(200, 0);
            var lab = new Lab03();
            await Mount(lab, app);

            var recon = lab.Lane.Recon;
            await Drive(lab, app, 4000, autoX: -1);

            // Predicted while ~RTT worth of inputs are still unacked, and the shared
            // step reproduces the server's math to wire precision.
            Check(recon.PendingCount > 0, "nothing in flight — inputs are not being predicted");
            Check(DriftClassifier.Classify(recon.Drift, 0.01) != DriftStatus.Diverging,
                $"drift ema {recon.Drift.Ema:E2} — the client's step disagrees with the server's");
            GD.Print($"OK lab03 predicted: {recon.PendingCount} in flight, drift ema {recon.Drift.Ema:E2}");

            // A server-side shove the client cannot see coming MUST mispredict...
            lab.RoomOf<Lab.MoveState>().Send("impulse");
            await Drive(lab, app, 1500);
            double peak = lab.Lane.MaxCorrectionMag;
            Check(peak > 0.05, "the impulse produced no visible correction");

            // ...and then decay back to steady state.
            await Drive(lab, app, 5000, autoX: 1);
            Check(recon.LastCorrectionMag < 0.05,
                $"corrections still {recon.LastCorrectionMag:F3} after 5 s — not converging");
            GD.Print($"OK lab03 impulse: peak {peak:F3}, settled to {recon.LastCorrectionMag:F4}");

            await Teardown(lab);
        }

        private async Task SteadyStateGc()
        {
            // Lab 03 is the busiest steady state in the suite: 20 inputs/s out and
            // 20 patches/s in, each one crossing the injector twice. If a per-message
            // allocation crept into the Dispatch/Transmit seam this is where it shows.
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(200, 0);
            var lab = new Lab03();
            await Mount(lab, app);

            // Warm up first: join, buffer growth and one-time delegate allocation are
            // not what this is measuring.
            await Drive(lab, app, 3000, autoX: 1);

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            long before = GC.GetTotalMemory(false);
            int collectionsBefore = GC.CollectionCount(0);
            double start = RoomClock.GetNow();
            _drivenFrames = 0;

            await Drive(lab, app, 8000, autoX: -1);

            double seconds = (RoomClock.GetNow() - start) / 1000.0;
            long grew = GC.GetTotalMemory(false) - before;
            int collections = GC.CollectionCount(0) - collectionsBefore;
            // Per FRAME, not per second — the frame rate here is whatever headless
            // Godot manages, and a per-second budget would silently track it.
            double perFrame = grew / (double)_drivenFrames;

            GD.Print($"OK gc: {grew / 1024.0:F1} KiB over {seconds:F1}s / {_drivenFrames} frames " +
                     $"({perFrame:F0} B/frame, {grew / seconds / 1024.0:F1} KiB/s), " +
                     $"{collections} gen0 collection(s)");

            Check(perFrame < 512,
                $"steady-state traffic allocated {perFrame:F0} B/frame — " +
                "well above the measured baseline, so something new is churning");

            await Teardown(lab);
        }

        private async Task Lab00Split()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab00();
            await Mount(lab, app);   // Mount sets its own latency preset

            // Drive one long leg and watch the two lanes separate: the echo lane is
            // the same entity, ~RTT behind. Peak, not instantaneous — the gap
            // collapses at every direction change.
            double peakGap = 0;
            for (int i = 0; i < 40; i++)
            {
                await Drive(lab, app, 120, autoX: 1);
                var me = lab.Lane.Me;
                double dx = lab.Lane.X - me.x, dy = lab.Lane.Y - me.y;
                peakGap = Math.Max(peakGap, Math.Sqrt(dx * dx + dy * dy));
            }
            Check(peakGap > 2.0,
                $"lanes never separated (peak {peakGap:F2} u) — the echo lane is not lagging");
            GD.Print($"OK lab00: peak lane separation {peakGap:F2} u");

            await Teardown(lab);
        }

        private async Task Lab04Modes()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(120, 40);
            var lab = new Lab04();
            await Mount(lab, app);

            // Pin the pattern rather than inherit whatever the room defaulted to —
            // a stationary bot scores NaN and the comparison below means nothing.
            lab.SetPattern("patrol");
            await Drive(lab, app, 2000);   // let the pattern land
            lab.ResetMeters();             // then score a clean window
            await Drive(lab, app, 6000);

            Check(lab.BotTravel > 10,
                $"the bot only travelled {lab.BotTravel:F1} u — nothing to measure smoothness of");
            var cv = lab.SmoothnessByMode();
            foreach (var pair in cv)
                Check(!double.IsNaN(pair.Value),
                    $"{pair.Key} never scored over {lab.BotTravel:F1} u of bot travel " +
                    $"({lab.DescribeMode(pair.Key)})");
            // raw is the decoded snapshot verbatim, so it stutters at the patch rate;
            // lerp walks between two real samples and must be measurably steadier.
            Check(cv["raw"] > cv["lerp"],
                $"raw CV {cv["raw"]:F3} was not worse than lerp {cv["lerp"]:F3} — " +
                "the modes are not actually rendering differently");
            GD.Print($"OK lab04: raw {cv["raw"]:F3}, lerp {cv["lerp"]:F3}, " +
                     $"damped {cv["damped"]:F3}, extrapolate {cv["extrapolate"]:F3}");

            await Teardown(lab);
        }

        private async Task Lab05Reckon()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            NetDelay.SetLatency(200, 0);
            var lab = new Lab05();
            await Mount(lab, app);

            // On the fully-predictable patrol, reckon renders the PRESENT and lerp
            // renders RemoteInterpMs in the past — so they must not coincide.
            lab.SetPattern("patrol");
            await Drive(lab, app, 5000);
            Check(lab.PeakReckonLerpGap > 1.0,
                $"reckon and lerp never separated (peak {lab.PeakReckonLerpGap:F2} u) — " +
                "the forward simulation is not running");

            // The circle is the check that matters: it is the one pattern whose y
            // moves. If the reckon scratch cannot see `kind` the step falls through
            // to patrol, which pins y to baseY — so a flat y here means the scratch
            // dropped the pattern on the way in.
            lab.SetPattern("circle");
            await Drive(lab, app, 2000);
            double minY = double.MaxValue, maxY = double.MinValue;
            for (int i = 0; i < 40; i++)
            {
                await Drive(lab, app, 100);
                minY = Math.Min(minY, lab.ReckonY);
                maxY = Math.Max(maxY, lab.ReckonY);
            }
            Check(maxY - minY > 4,
                $"reckoned y only swept {maxY - minY:F2} u on the circle pattern — " +
                "the step is falling back to patrol");
            GD.Print($"OK lab05: peak reckon↔lerp gap {lab.PeakReckonLerpGap:F2} u, " +
                     $"circle y sweep {maxY - minY:F2} u");

            await Teardown(lab);
        }

        /// <summary>Fire n shots, spaced so each gets its own input tick and answer.</summary>
        private async Task FireVolley(ILab lab, App app, Action fire, int n)
        {
            for (int i = 0; i < n; i++)
            {
                fire();
                await Drive(lab, app, 700);
            }
        }

        private async Task Lab06LagComp()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab06();
            await Mount(lab, app);
            NetDelay.SetLatency(200, 0);
            await Drive(lab, app, 1500);

            // Lag comp ON: the autopilot aims at the lerp view — exactly what the
            // server rewinds to — so nearly every shot must land.
            lab.SetLagComp(true);
            await Drive(lab, app, 800);
            await FireVolley(lab, app, lab.Fire, 6);
            Check(lab.ShotsOn > 0, "no shots were reported with lag comp on");
            Check(lab.HitsOn * 10 > lab.ShotsOn * 6,
                $"only {lab.HitsOn}/{lab.ShotsOn} hit with lag comp ON — the rewind is not " +
                $"landing where we drew (rewind error {lab.RewindErrorU():F2} u)");

            // The rewound read must coincide with what we saw. This is the assertion
            // that catches an unbound renderDelay: it lands one render-delay early
            // and nothing else in the lab says so.
            Check(lab.RewindErrorU() < 3.0,
                $"server rewound to {lab.RewindErrorU():F2} u away from our view — check renderDelay");

            // The ray's click-time colour. The autopilot aims dead-on, so the
            // client must call its own shots hits — a transposed RayCircle
            // argument compiles clean and would paint every ray red instead.
            Check(lab.PredictedHits * 10 > lab.ShotsOn * 6,
                $"the client previewed only {lab.PredictedHits}/{lab.ShotsOn} of its own shots as " +
                "hits while aiming dead-on — the click-time hit test disagrees with the crosshair");
            GD.Print($"OK lab06 comp ON: {lab.HitsOn}/{lab.ShotsOn} hits, " +
                     $"rewind error {lab.RewindErrorU():F2} u, view lag {lab.ViewLag():F1} u");

            await Teardown(lab);
        }

        private async Task Lab07Wysiwyg()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab07();
            await Mount(lab, app);
            NetDelay.SetLatency(200, 0);

            // The autopilot seeks the bot's lane and lets the patrol sweep hit it.
            await Drive(lab, app, 14000, autoX: 1);

            Check(lab.BumpsPredicted > 0,
                "never bumped the bot — the autopilot did not reach its lane");
            // The server's own counter is the only verdict that settles it: with
            // ValueAt + Memo the client's count must track it, not merely be close.
            int delta = Math.Abs(lab.BumpsPredicted - lab.BumpsAuthoritative);
            Check(delta <= 1,
                $"predicted {lab.BumpsPredicted} bumps, server counted {lab.BumpsAuthoritative} " +
                $"— the client's verdict disagrees with the server's");
            GD.Print($"OK lab07: predicted {lab.BumpsPredicted}, authoritative " +
                     $"{lab.BumpsAuthoritative}, mispredict rate {lab.MispredictRate():F0} %");

            await Teardown(lab);
        }

        private async Task Lab08Events()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab08();
            await Mount(lab, app);
            NetDelay.SetLatency(200, 0);

            // Deny nothing: every optimistic banner must be confirmed.
            lab.SetDenyRate(0);
            await Drive(lab, app, 600);
            await Drive(lab, app, 6000, autoX: 1);
            Check(lab.PredictedCount > 0, "never entered the goal zone");
            Check(lab.ConfirmedCount > 0, "no optimistic goal was ever confirmed");
            Check(lab.RejectedCount == 0,
                $"{lab.RejectedCount} goals rejected at a 0 % deny rate");
            int cleanRun = lab.PredictedCount;

            // Deny everything: the banner still fires instantly, then retracts.
            lab.SetDenyRate(100);
            await Drive(lab, app, 600);
            await Drive(lab, app, 9000, autoX: 1);
            Check(lab.PredictedCount > cleanRun,
                "the optimistic banner stopped firing once the server started denying");
            Check(lab.RejectedCount > 0,
                "server denied every goal but nothing was ever rejected — grace-tick auto-reject is not firing");
            GD.Print($"OK lab08: {lab.ConfirmedCount} confirmed, {lab.RejectedCount} rejected " +
                     $"of {lab.PredictedCount} predicted");

            await Teardown(lab);
        }

        private async Task Lab09Spawns()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab09();
            await Mount(lab, app);
            NetDelay.SetLatency(200, 0);
            await Drive(lab, app, 800);

            lab.AimAt(50, 55);
            lab.Fire();
            // Immediately after firing there must be a local to look at — that IS
            // the feature. Half an RTT later it must still not be confirmed.
            await Drive(lab, app, 120);
            Check(lab.PendingSpawns > 0,
                "fired but nothing was spawned locally — the shot would not appear for a full RTT");

            // ...and by ~2 RTT the server's entity has arrived and correlated.
            await Drive(lab, app, 1400);
            Check(lab.ConfirmedSpawns > 0, "the server's projectile never correlated");
            Check(lab.LastLeadMs > 0,
                "no input lead was measured — SpawnTime is not wired, so the handoff would jump");

            // ...and MEASURING the lead is only half of it: the confirmed entity has
            // to be reckoned by it too. Un-reckoned it renders at the last decoded
            // snapshot, (snapshot age + lead) x 34 u/s behind the prediction — ~8 u
            // at this latency, which is what a player sees as the shot snapping back.
            for (int i = 0; i < 5; i++)
            {
                lab.AimAt(50, 55);
                lab.Fire();
                await Drive(lab, app, 700);
            }
            Check(lab.MaxHandoffJump < 3.0,
                $"the projectile snapped {lab.MaxHandoffJump:F2} u at the handoff — " +
                "the confirmed entity is not being lead-reckoned");
            GD.Print($"OK lab09: fired {lab.Fired}, lead {lab.LastLeadMs:F0} ms, " +
                     $"{lab.ConfirmedSpawns} confirmed, worst jump {lab.MaxHandoffJump:F2} u");

            await Teardown(lab);
        }

        private async Task Lab10Composite()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab10();
            await Mount(lab, app);      // mount picks its own latency preset
            lab.SetBot(false);          // isolate OUR step from a contested touch

            // Drive back and forth across the puck. The lead is transient — largest
            // just after a strike — so this tracks the PEAK rather than sampling.
            // Sample every reconcile as it happens, and how far the puck travels late
            // in the run. Reading drift.Ema once at the end measures the wrong thing
            // twice over: it decays toward zero when the world stops moving, so a puck
            // pinned against a wall scores BETTER than honest play.
            var mags = new List<double>();
            int seq = lab.Recon.ReconcileSeq;
            double latePath = 0, px = double.NaN, py = double.NaN;
            await Drive(lab, app, 12000, 0, 0, elapsed =>
            {
                if (lab.Recon.ReconcileSeq != seq)
                {
                    seq = lab.Recon.ReconcileSeq;
                    mags.Add(lab.Recon.LastCorrectionMag);
                }
                if (elapsed > 9000)
                {
                    var puck = lab.ServerPuck();
                    if (!double.IsNaN(px))
                    {
                        latePath += Math.Sqrt((puck.x - px) * (puck.x - px)
                                            + (puck.y - py) * (puck.y - py));
                    }
                    px = puck.x;
                    py = puck.y;
                }
            });

            Check(lab.Recon.PendingCount > 0,
                "nothing in flight — inputs are not being predicted");
            // The whole point of the composite face: the puck is predicted THROUGH
            // our inputs, so it must run ahead of the authoritative one.
            Check(lab.MaxPuckLead > 0.5,
                $"predicted puck never led the server's (peak {lab.MaxPuckLead:F2} u, " +
                $"{lab.Touches} touches, {lab.DescribePuck()}) — " +
                "the puck is not being predicted through our inputs");
            // The MEDIAN reconcile, not the worst or the last — see the unity twin
            // for why (contested human touches mispredict by design).
            mags.Sort();
            double median = mags.Count == 0 ? -1 : mags[(mags.Count - 1) / 2];
            Check(median >= 0 && median < 0.5,
                $"median correction {median:F4} over {mags.Count} reconciles — " +
                "the composite step disagrees with the server's");
            // Guards the check above: a frozen world agrees with itself perfectly.
            Check(latePath > 5,
                $"puck travelled {latePath:F1} u in the last 3s — the world froze, so the " +
                "median above proves nothing (a pinned puck reads as perfect agreement)");
            GD.Print($"OK lab10: peak puck lead {lab.MaxPuckLead:F2} u, {lab.Touches} touches, " +
                     $"median correction {median:F4} over {mags.Count} reconciles, " +
                     $"{latePath:F1} u late travel, {lab.Recon.PendingCount} in flight");

            await Teardown(lab);
        }

        private async Task Lab11Rng()
        {
            var app = new App { Client = MakeClient(), PrivateRoom = true };
            var lab = new Lab11();
            await Mount(lab, app);
            NetDelay.SetLatency(200, 0);
            await Drive(lab, app, 1200);

            // Seeded from (seq, salt): both sides must derive the SAME fan, bit for
            // bit. Nothing about the pellets is on the wire.
            await FireVolley(lab, app, lab.Fire, 3);
            Check(lab.AnsweredFans > 0, "the server never reported a fan");
            Check(lab.MaxDivergence < 1e-6,
                $"client and server fans differ by {lab.MaxDivergence:E2} rad — the derivation diverged");
            GD.Print($"OK lab11 seeded: divergence {lab.MaxDivergence:E2} rad over {lab.AnsweredFans} fans");

            // Swap in an unshared RNG and the same comparison must FAIL — otherwise
            // the test above proves nothing.
            lab.Cheat = true;
            await FireVolley(lab, app, lab.Fire, 3);
            Check(lab.MaxDivergence > 1e-6,
                "a local unshared RNG still matched the server — the comparison is not measuring anything");
            GD.Print($"OK lab11 cheating: divergence {lab.MaxDivergence:E2} rad");

            await Teardown(lab);
        }
    }
}
