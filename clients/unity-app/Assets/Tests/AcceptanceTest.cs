using System.Collections;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using NUnit.Framework;
using Playground;
using UnityEngine;
using UnityEngine.TestTools;
using Lab = PredictProbe.LabSchema;

/// <summary>
/// The Unity twin of the native app's `--demo` autopilot: APPS_PLAN §7's M1
/// exit criteria, replayed against the LIVE server with no hands on the
/// keyboard. Needs `pnpm dev --host 0.0.0.0` running.
///
/// PlayMode rather than EditMode because the injector drains on a frame loop
/// and the predict stack is driven per frame — both need real time to pass.
/// </summary>
public class AcceptanceTest
{
    private const string Endpoint = "ws://localhost:5173";
    private const int TestTimeoutMs = 120000;

    /// <summary>Frames driven, so allocation can be measured per FRAME.</summary>
    private static long DrivenFrames;

    [SetUp]
    public void SetUp()
    {
        NetDelay.Reset();
        Kb.Autopilot = true;
        Kb.AutoX = Kb.AutoY = 0;
    }

    [TearDown]
    public void TearDown() => Kb.Autopilot = false;

    private static Client MakeClient() => new Client(Endpoint);

    /// <summary>Pump the injector + a lab for `ms`, exactly like Update() does.</summary>
    /// <param name="onFrame">
    ///     Runs after each frame with the elapsed ms — for checks that need the
    ///     shape of a run rather than one end-of-run reading.
    /// </param>
    private static IEnumerator Drive(ILab lab, App app, double ms, int autoX = 0, int autoY = 0,
        System.Action<double> onFrame = null)
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
            DrivenFrames++;
            onFrame?.Invoke(now - start);
            yield return null;
        }
    }

    /// <summary>
    /// Spin until `task` completes — pumping the injector every frame. The pump
    /// is load-bearing, not hygiene: a join resolves on the inbound JOIN_ROOM
    /// frame and a leave on the inbound close, and the injector is holding both.
    /// Awaiting without draining deadlocks on any nonzero latency.
    /// </summary>
    private static IEnumerator Await(Task task, string what, double timeoutMs = 20000)
    {
        double start = RoomClock.GetNow();
        while (!task.IsCompleted)
        {
            NetDelay.PumpAll();
            if (RoomClock.GetNow() - start > timeoutMs)
            {
                Assert.Fail($"{what}: still pending after {timeoutMs:F0} ms " +
                            $"({NetDelay.InFlight()} pkt in the injector)");
            }
            yield return null;
        }
        if (task.IsFaulted) throw task.Exception;
    }

    /// <summary>Join, then wait out the join round trip. Fails loudly on timeout.</summary>
    private static IEnumerator Mount(ILab lab, App app)
    {
        Debug.Log($"[acceptance] mounting {lab.Id}");
        var mount = lab.Mount(app);
        yield return Await(mount, $"{lab.Id} mount");
        Assert.IsTrue(mount.Result, $"{lab.Id} joined but its state never arrived");
        Debug.Log($"[acceptance] mounted {lab.Id}");
    }

    private static IEnumerator Teardown(ILab lab)
    {
        lab.Unmount();
        yield return Await(lab.Room.Leave(true), $"{lab.Id} leave");
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Sim_reproduces_the_reference_numbers()
    {
        // The canary the native app runs as --selfcheck: a constant typo can
        // never ship silently.
        Assert.AreEqual(0, Sim.SelfCheck(), "shared-sim port diverged from the TypeScript original");
        yield return null;
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab01_input_to_motion_tracks_the_round_trip()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(0, 0);
        var lab = new Lab01();
        yield return Mount(lab, app);

        // At rest first: the meter arms on a key press from a standstill.
        yield return Drive(lab, app, 800);
        yield return Drive(lab, app, 1600, autoX: 1);
        double atZero = lab.Measured;
        Assert.Greater(atZero, 0, "meter never armed at 0 injected latency");
        Assert.Less(atZero, 250, $"input->motion {atZero:F0} ms at 0 injected — expected ~one patch interval");

        // Now with a 200 ms round trip; no prediction, so it must track it.
        yield return Drive(lab, app, 900);
        NetDelay.SetLatency(200, 0);
        yield return Drive(lab, app, 1200);
        yield return Drive(lab, app, 2000, autoX: -1);
        double at200 = lab.Measured;
        Assert.Greater(at200, atZero + 150, $"input->motion {at200:F0} ms at 200 ms injected (was {atZero:F0}) — latency not felt");
        Debug.Log($"OK lab01: {atZero:F0} ms at 0 injected, {at200:F0} ms at 200 ms");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab02_clock_readouts_respond_to_injected_latency()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(200, 0);
        var lab = new Lab02();
        yield return Mount(lab, app);

        yield return Drive(lab, app, 4000, autoX: 1);
        var clock = lab.RoomOf<Lab.BotsState>().Clock;
        Assert.Greater(clock.SmoothedRtt(), 350,
            $"smoothed rtt {clock.SmoothedRtt():F0} ms — the injector is not in the path");
        Assert.Greater(clock.LastServerTime(), 0, "no TIMED prefix: the clock never synced");
        Assert.Greater(clock.PatchInterval(), 0, "patch cadence never advertised");
        Debug.Log($"OK lab02: rtt {clock.SmoothedRtt():F0} ms, patch {clock.PatchInterval():F0} ms, " +
                  $"jitter {clock.Jitter():F1} ms");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab03_predicts_instantly_and_absorbs_a_mispredict()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(200, 0);
        var lab = new Lab03();
        yield return Mount(lab, app);

        var recon = lab.Lane.Recon;
        yield return Drive(lab, app, 4000, autoX: -1);

        // Predicted while ~RTT worth of inputs are still unacked, and the shared
        // step reproduces the server's math to wire precision.
        Assert.Greater(recon.PendingCount, 0, "nothing in flight — inputs are not being predicted");
        Assert.AreNotEqual(DriftStatus.Diverging, DriftClassifier.Classify(recon.Drift, 0.01),
            $"drift ema {recon.Drift.Ema:E2} — the client's step disagrees with the server's");
        Debug.Log($"OK lab03 predicted: {recon.PendingCount} in flight, drift ema {recon.Drift.Ema:E2}");

        // A server-side shove the client cannot see coming MUST mispredict...
        lab.RoomOf<Lab.MoveState>().Send("impulse");
        yield return Drive(lab, app, 1500);
        double peak = lab.Lane.MaxCorrectionMag;
        Assert.Greater(peak, 0.05, "the impulse produced no visible correction");

        // ...and then decay back to steady state.
        yield return Drive(lab, app, 5000, autoX: 1);
        Assert.Less(recon.LastCorrectionMag, 0.05,
            $"corrections still {recon.LastCorrectionMag:F3} after 5 s — not converging");
        Debug.Log($"OK lab03 impulse: peak {peak:F3}, settled to {recon.LastCorrectionMag:F4}");

        yield return Teardown(lab);
    }

    [Test]
    public void Connection_seam_allocates_nothing_per_message()
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

        System.GC.Collect();
        System.GC.WaitForPendingFinalizers();
        System.GC.Collect();
        long before = System.GC.GetTotalMemory(false);

        const int N = 20000;
        for (int i = 0; i < N; i++) { conn.Dispatch(ConnectionEvent.Received(payload)); NetDelay.PumpAll(); }

        double perMessage = (System.GC.GetTotalMemory(false) - before) / (double)N;
        Assert.AreEqual(512 + N, delivered, "the seam dropped or duplicated messages");
        Debug.Log($"OK gc seam: {perMessage:F2} B/message over {N} round trips");
        Assert.Less(perMessage, 8,
            $"the injector allocates {perMessage:F1} B per message — a closure or a " +
            "copy crept back into the per-packet path");
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Steady_state_traffic_does_not_churn_the_heap()
    {
        // Lab 03 is the busiest steady state in the suite: 20 inputs/s out and
        // 20 patches/s in, each one crossing the injector twice. If a per-message
        // allocation crept into the Dispatch/Transmit seam this is where it shows.
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(200, 0);
        var lab = new Lab03();
        yield return Mount(lab, app);

        // Warm up first: join, buffer growth and one-time delegate allocation are
        // not what this is measuring.
        yield return Drive(lab, app, 3000, autoX: 1);

        System.GC.Collect();
        System.GC.WaitForPendingFinalizers();
        System.GC.Collect();
        long before = System.GC.GetTotalMemory(false);
        int collectionsBefore = System.GC.CollectionCount(0);
        double start = RoomClock.GetNow();
        DrivenFrames = 0;

        yield return Drive(lab, app, 8000, autoX: -1);

        double seconds = (RoomClock.GetNow() - start) / 1000.0;
        long grew = System.GC.GetTotalMemory(false) - before;
        int collections = System.GC.CollectionCount(0) - collectionsBefore;
        // Per FRAME, not per second: this harness has run anywhere from 200 to
        // 3300 fps, and a per-second budget silently tracks the frame rate rather
        // than the code. Per frame is the number that stays put.
        double perFrame = grew / (double)DrivenFrames;

        Debug.Log($"OK gc: {grew / 1024.0:F1} KiB over {seconds:F1}s / {DrivenFrames} frames " +
                  $"({perFrame:F0} B/frame, {grew / seconds / 1024.0:F1} KiB/s), " +
                  $"{collections} gen0 collection(s)");

        // This is the WHOLE frame, and it is dominated by the SDK's receive and
        // decode path (a byte[] per frame off the socket, per-patch decode
        // garbage), not by the injector — Connection_seam_allocates_nothing_
        // per_message measures that part at ~0. Kept as a coarse regression
        // guard; the closure-per-packet version this replaced was ~4x higher.
        Assert.Less(perFrame, 512,
            $"steady-state traffic allocated {perFrame:F0} B/frame — " +
            "well above the measured baseline, so something new is churning");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab00_predicted_lane_leads_the_server_echo()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab00();
        yield return Mount(lab, app);   // Mount sets its own latency preset

        // Drive one long leg and watch the two lanes separate: the echo lane is
        // the same entity, ~RTT behind. Peak, not instantaneous — the gap
        // collapses at every direction change.
        double peakGap = 0;
        for (int i = 0; i < 40; i++)
        {
            yield return Drive(lab, app, 120, autoX: 1);
            var me = lab.Lane.Me;
            double dx = lab.Lane.X - me.x, dy = lab.Lane.Y - me.y;
            peakGap = System.Math.Max(peakGap, System.Math.Sqrt(dx * dx + dy * dy));
        }
        Assert.Greater(peakGap, 2.0,
            $"lanes never separated (peak {peakGap:F2} u) — the echo lane is not lagging");
        Debug.Log($"OK lab00: peak lane separation {peakGap:F2} u");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab06_lag_comp_hits_what_you_saw()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab06();
        yield return Mount(lab, app);
        NetDelay.SetLatency(200, 0);
        yield return Drive(lab, app, 1500);

        // Lag comp ON: the autopilot aims at the lerp view — exactly what the
        // server rewinds to — so nearly every shot must land.
        lab.SetLagComp(true);
        yield return Drive(lab, app, 800);
        yield return FireVolley(lab, app, lab.Fire, 6);
        Assert.Greater(lab.ShotsOn, 0, "no shots were reported with lag comp on");
        Assert.Greater(lab.HitsOn * 10, lab.ShotsOn * 6,
            $"only {lab.HitsOn}/{lab.ShotsOn} hit with lag comp ON — the rewind is not " +
            $"landing where we drew (rewind error {lab.RewindErrorU():F2} u)");

        // The rewound read must coincide with what we saw. This is the assertion
        // that catches an unbound renderDelay: it lands one render-delay early
        // and nothing else in the lab says so.
        Assert.Less(lab.RewindErrorU(), 3.0,
            $"server rewound to {lab.RewindErrorU():F2} u away from our view — check renderDelay");

        // The ray's click-time colour. The autopilot aims dead-on, so the
        // client must call its own shots hits — a transposed RayCircle
        // argument compiles clean and would paint every ray red instead.
        Assert.Greater(lab.PredictedHits * 10, lab.ShotsOn * 6,
            $"the client previewed only {lab.PredictedHits}/{lab.ShotsOn} of its own shots as " +
            "hits while aiming dead-on — the click-time hit test disagrees with the crosshair");
        Debug.Log($"OK lab06 comp ON: {lab.HitsOn}/{lab.ShotsOn} hits, " +
                  $"rewind error {lab.RewindErrorU():F2} u, view lag {lab.ViewLag():F1} u");

        yield return Teardown(lab);
    }

    /// <summary>Fire n shots, spaced so each gets its own input tick and answer.</summary>
    private static IEnumerator FireVolley(ILab lab, App app, System.Action fire, int n)
    {
        for (int i = 0; i < n; i++)
        {
            fire();
            yield return Drive(lab, app, 700);
        }
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab04_interpolation_modes_differ_as_advertised()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(120, 40);
        var lab = new Lab04();
        yield return Mount(lab, app);

        // Pin the pattern rather than inherit whatever the room defaulted to —
        // a stationary bot scores NaN and the comparison below means nothing.
        lab.SetPattern("patrol");
        yield return Drive(lab, app, 2000);   // let the pattern land
        lab.ResetMeters();                    // then score a clean window
        yield return Drive(lab, app, 6000);

        Assert.Greater(lab.BotTravel, 10,
            $"the bot only travelled {lab.BotTravel:F1} u — nothing to measure smoothness of");
        var cv = lab.SmoothnessByMode();
        foreach (var pair in cv)
            Assert.False(double.IsNaN(pair.Value),
                $"{pair.Key} never scored over {lab.BotTravel:F1} u of bot travel " +
                $"({lab.DescribeMode(pair.Key)})");
        // raw is the decoded snapshot verbatim, so it stutters at the patch rate;
        // lerp walks between two real samples and must be measurably steadier.
        Assert.Greater(cv["raw"], cv["lerp"],
            $"raw CV {cv["raw"]:F3} was not worse than lerp {cv["lerp"]:F3} — " +
            "the modes are not actually rendering differently");
        Debug.Log($"OK lab04: raw {cv["raw"]:F3}, lerp {cv["lerp"]:F3}, " +
                  $"damped {cv["damped"]:F3}, extrapolate {cv["extrapolate"]:F3}");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab05_reckon_leads_the_lerp_view()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        NetDelay.SetLatency(200, 0);
        var lab = new Lab05();
        yield return Mount(lab, app);

        // On the fully-predictable patrol, reckon renders the PRESENT and lerp
        // renders RemoteInterpMs in the past — so they must not coincide.
        lab.SetPattern("patrol");
        yield return Drive(lab, app, 5000);
        Assert.Greater(lab.PeakReckonLerpGap, 1.0,
            $"reckon and lerp never separated (peak {lab.PeakReckonLerpGap:F2} u) — " +
            "the forward simulation is not running");

        // The circle is the check that matters: it is the one pattern whose y
        // moves. If the reckon scratch cannot see `kind` the step falls through
        // to patrol, which pins y to baseY — so a flat y here means the scratch
        // dropped the pattern on the way in.
        lab.SetPattern("circle");
        yield return Drive(lab, app, 2000);
        double minY = double.MaxValue, maxY = double.MinValue;
        for (int i = 0; i < 40; i++)
        {
            yield return Drive(lab, app, 100);
            minY = System.Math.Min(minY, lab.ReckonY);
            maxY = System.Math.Max(maxY, lab.ReckonY);
        }
        Assert.Greater(maxY - minY, 4,
            $"reckoned y only swept {maxY - minY:F2} u on the circle pattern — " +
            "the step is falling back to patrol");
        Debug.Log($"OK lab05: peak reckon↔lerp gap {lab.PeakReckonLerpGap:F2} u, " +
                  $"circle y sweep {maxY - minY:F2} u");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab07_frozen_verdict_matches_the_server()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab07();
        yield return Mount(lab, app);
        NetDelay.SetLatency(200, 0);

        // The autopilot seeks the bot's lane and lets the patrol sweep hit it.
        yield return Drive(lab, app, 14000, autoX: 1);

        Assert.Greater(lab.BumpsPredicted, 0,
            "never bumped the bot — the autopilot did not reach its lane");
        // The server's own counter is the only verdict that settles it: with
        // ValueAt + Memo the client's count must track it, not merely be close.
        int delta = System.Math.Abs(lab.BumpsPredicted - lab.BumpsAuthoritative);
        Assert.LessOrEqual(delta, 1,
            $"predicted {lab.BumpsPredicted} bumps, server counted {lab.BumpsAuthoritative} " +
            $"— the client's verdict disagrees with the server's");
        Debug.Log($"OK lab07: predicted {lab.BumpsPredicted}, authoritative " +
                  $"{lab.BumpsAuthoritative}, mispredict rate {lab.MispredictRate():F0} %");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab08_events_fire_instantly_then_settle()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab08();
        yield return Mount(lab, app);
        NetDelay.SetLatency(200, 0);

        // Deny nothing: every optimistic banner must be confirmed.
        lab.SetDenyRate(0);
        yield return Drive(lab, app, 600);
        yield return Drive(lab, app, 6000, autoX: 1);
        Assert.Greater(lab.PredictedCount, 0, "never entered the goal zone");
        Assert.Greater(lab.ConfirmedCount, 0, "no optimistic goal was ever confirmed");
        Assert.AreEqual(0, lab.RejectedCount,
            $"{lab.RejectedCount} goals rejected at a 0 % deny rate");
        int cleanRun = lab.PredictedCount;

        // Deny everything: the banner still fires instantly, then retracts.
        lab.SetDenyRate(100);
        yield return Drive(lab, app, 600);
        yield return Drive(lab, app, 9000, autoX: 1);
        Assert.Greater(lab.PredictedCount, cleanRun,
            "the optimistic banner stopped firing once the server started denying");
        Assert.Greater(lab.RejectedCount, 0,
            "server denied every goal but nothing was ever rejected — grace-tick auto-reject is not firing");
        Debug.Log($"OK lab08: {lab.ConfirmedCount} confirmed, {lab.RejectedCount} rejected " +
                  $"of {lab.PredictedCount} predicted");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab09_optimistic_spawn_hands_off_to_the_server()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab09();
        yield return Mount(lab, app);
        NetDelay.SetLatency(200, 0);
        yield return Drive(lab, app, 800);

        lab.AimAt(50, 55);
        lab.Fire();
        // Immediately after firing there must be a local to look at — that IS
        // the feature. Half an RTT later it must still not be confirmed.
        yield return Drive(lab, app, 120);
        Assert.Greater(lab.PendingSpawns, 0,
            "fired but nothing was spawned locally — the shot would not appear for a full RTT");

        // ...and by ~2 RTT the server's entity has arrived and correlated.
        yield return Drive(lab, app, 1400);
        Assert.Greater(lab.ConfirmedSpawns, 0, "the server's projectile never correlated");
        Assert.Greater(lab.LastLeadMs, 0,
            "no input lead was measured — SpawnTime is not wired, so the handoff would jump");

        // ...and MEASURING the lead is only half of it: the confirmed entity has
        // to be reckoned by it too. Un-reckoned it renders at the last decoded
        // snapshot, (snapshot age + lead) x 34 u/s behind the prediction — ~8 u
        // at this latency, which is what a player sees as the shot snapping back.
        for (int i = 0; i < 5; i++)
        {
            lab.AimAt(50, 55);
            lab.Fire();
            yield return Drive(lab, app, 700);
        }
        Assert.Less(lab.MaxHandoffJump, 3.0,
            $"the projectile snapped {lab.MaxHandoffJump:F2} u at the handoff — " +
            "the confirmed entity is not being lead-reckoned");
        Debug.Log($"OK lab09: fired {lab.Fired}, lead {lab.LastLeadMs:F0} ms, " +
                  $"{lab.ConfirmedSpawns} confirmed, worst jump {lab.MaxHandoffJump:F2} u");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab10_predicts_the_puck_through_your_own_inputs()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab10();
        yield return Mount(lab, app);      // mount picks its own latency preset
        lab.SetBot(false);                 // isolate OUR step from a contested touch

        // Drive back and forth across the puck. The lead is transient — largest
        // just after a strike — so this tracks the PEAK rather than sampling.
        // The lab steers itself toward the puck under autopilot; a plain
        // left-right sweep never reaches it.
        // Sample every reconcile as it happens, and how far the puck travels late
        // in the run. Reading drift.Ema once at the end measures the wrong thing
        // twice over: it decays toward zero when the world stops moving, so a puck
        // pinned against a wall scores BETTER than honest play.
        var mags = new List<double>();
        int seq = lab.Recon.ReconcileSeq;
        double latePath = 0, px = double.NaN, py = double.NaN;
        yield return Drive(lab, app, 12000, 0, 0, elapsed =>
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
                    latePath += System.Math.Sqrt((puck.x - px) * (puck.x - px)
                                               + (puck.y - py) * (puck.y - py));
                }
                px = puck.x;
                py = puck.y;
            }
        });

        Assert.Greater(lab.Recon.PendingCount, 0,
            "nothing in flight — inputs are not being predicted");
        // The whole point of the composite face: the puck is predicted THROUGH
        // our inputs, so it must run ahead of the authoritative one.
        Assert.Greater(lab.MaxPuckLead, 0.5,
            $"predicted puck never led the server's (peak {lab.MaxPuckLead:F2} u, " +
            $"{lab.Touches} touches, {lab.DescribePuck()}) — " +
            "the puck is not being predicted through our inputs");
        // The MEDIAN reconcile, not the worst or the last. Remote HUMAN paddles
        // enter the prediction at their last snapshot, so a contested human touch
        // mispredicts BY DESIGN — lab 10 exists to show that. 0.5 is a
        // gross-divergence ceiling: a client stepping the puck with the wrong
        // friction (0.900 vs 0.985) lands at 1.7751. Honest play measured
        // 0.0000-0.1527 before the server paced input consumption to one per tick
        // (2026-07-31); with pacing it sits at ~0.0000, so the margin is now much
        // wider. Bit-exactness is Sim.SelfCheck()'s job.
        mags.Sort();
        double median = mags.Count == 0 ? -1 : mags[(mags.Count - 1) / 2];
        Assert.That(median, Is.GreaterThanOrEqualTo(0).And.LessThan(0.5),
            $"median correction {median:F4} over {mags.Count} reconciles — " +
            "the composite step disagrees with the server's");
        // Guards the check above: a frozen world agrees with itself perfectly.
        Assert.Greater(latePath, 5,
            $"puck travelled {latePath:F1} u in the last 3s — the world froze, so the " +
            "median above proves nothing (a pinned puck reads as perfect agreement)");
        Debug.Log($"OK lab10: peak puck lead {lab.MaxPuckLead:F2} u, {lab.Touches} touches, " +
                  $"median correction {median:F4} over {mags.Count} reconciles, " +
                  $"{latePath:F1} u late travel, {lab.Recon.PendingCount} in flight");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab11_client_and_server_roll_identical_pellets()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        var lab = new Lab11();
        yield return Mount(lab, app);
        NetDelay.SetLatency(200, 0);
        yield return Drive(lab, app, 1200);

        // Seeded from (seq, salt): both sides must derive the SAME fan, bit for
        // bit. Nothing about the pellets is on the wire.
        yield return FireVolley(lab, app, lab.Fire, 3);
        Assert.Greater(lab.AnsweredFans, 0, "the server never reported a fan");
        Assert.Less(lab.MaxDivergence, 1e-6,
            $"client and server fans differ by {lab.MaxDivergence:E2} rad — the derivation diverged");
        Debug.Log($"OK lab11 seeded: divergence {lab.MaxDivergence:E2} rad over {lab.AnsweredFans} fans");

        // Swap in an unshared RNG and the same comparison must FAIL — otherwise
        // the test above proves nothing.
        lab.Cheat = true;
        yield return FireVolley(lab, app, lab.Fire, 3);
        Assert.Greater(lab.MaxDivergence, 1e-6,
            "a local unshared RNG still matched the server — the comparison is not measuring anything");
        Debug.Log($"OK lab11 cheating: divergence {lab.MaxDivergence:E2} rad");

        yield return Teardown(lab);
    }
}
