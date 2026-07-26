using System.Collections;
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

    [SetUp]
    public void SetUp()
    {
        DelayedConnection.Reset();
        Kb.Autopilot = true;
        Kb.AutoX = Kb.AutoY = 0;
    }

    [TearDown]
    public void TearDown() => Kb.Autopilot = false;

    private static Client MakeClient()
    {
        DelayedConnection.Install();
        return new Client(Endpoint);
    }

    /// <summary>Pump the injector + a lab for `ms`, exactly like Update() does.</summary>
    private static IEnumerator Drive(ILab lab, App app, double ms, int autoX = 0, int autoY = 0)
    {
        Kb.Autopilot = true;
        Kb.AutoX = autoX;
        Kb.AutoY = autoY;
        double start = RoomClock.GetNow(), last = start;
        while (RoomClock.GetNow() - start < ms)
        {
            DelayedConnection.PumpAll();
            double now = RoomClock.GetNow();
            lab?.Frame(app, now, now - last);
            last = now;
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
            DelayedConnection.PumpAll();
            if (RoomClock.GetNow() - start > timeoutMs)
            {
                Assert.Fail($"{what}: still pending after {timeoutMs:F0} ms " +
                            $"({DelayedConnection.InFlight()} pkt in the injector)");
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
        DelayedConnection.SetLatency(0, 0);
        var lab = new Lab01();
        yield return Mount(lab, app);

        // At rest first: the meter arms on a key press from a standstill.
        yield return Drive(lab, app, 800);
        yield return Drive(lab, app, 1600, autoX: 1);
        double atZero = lab.Measured;
        Assert.Greater(atZero, 0, "meter never armed at 0 injected latency");
        Assert.Less(atZero, 250, $"input->motion {atZero:F0} ms at 0 injected — expected ~one patch interval");

        // Now with 200 ms each way; no prediction, so it must track the round trip.
        yield return Drive(lab, app, 900);
        DelayedConnection.SetLatency(200, 0);
        yield return Drive(lab, app, 1200);
        yield return Drive(lab, app, 2000, autoX: -1);
        double at200 = lab.Measured;
        Assert.Greater(at200, 300, $"input->motion {at200:F0} ms at 200 ms injected — latency not felt");
        Debug.Log($"OK lab01: {atZero:F0} ms at 0 injected, {at200:F0} ms at 200 ms");

        yield return Teardown(lab);
    }

    [UnityTest, Timeout(TestTimeoutMs)]
    public IEnumerator Lab02_clock_readouts_respond_to_injected_latency()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        DelayedConnection.SetLatency(200, 0);
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
        DelayedConnection.SetLatency(200, 0);
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

}
