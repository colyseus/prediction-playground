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
    private const int TickMs = 16;

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

    private static IEnumerator Await(Task task)
    {
        while (!task.IsCompleted) yield return null;
        if (task.IsFaulted) throw task.Exception;
    }

    [UnityTest]
    public IEnumerator Sim_reproduces_the_reference_numbers()
    {
        // The canary the native app runs as --selfcheck: a constant typo can
        // never ship silently.
        Assert.AreEqual(0, Sim.SelfCheck(), "shared-sim port diverged from the TypeScript original");
        yield return null;
    }

    [UnityTest]
    public IEnumerator Lab01_input_to_motion_tracks_the_round_trip()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        DelayedConnection.SetLatency(0, 0);
        var lab = new Lab01();
        var mount = lab.Mount(app);
        yield return Await(mount);
        Assert.IsTrue(mount.Result, "lab 01 failed to mount");

        // At rest first: the meter arms on a key press from a standstill.
        yield return Drive(lab, app, 800);
        yield return Drive(lab, app, 1600, autoX: 1);
        double atZero = Measured(lab);
        Assert.Greater(atZero, 0, "meter never armed at 0 injected latency");
        Assert.Less(atZero, 250, $"input->motion {atZero:F0} ms at 0 injected — expected ~one patch interval");

        // Now with 200 ms each way; no prediction, so it must track the round trip.
        yield return Drive(lab, app, 900);
        DelayedConnection.SetLatency(200, 0);
        yield return Drive(lab, app, 1200);
        yield return Drive(lab, app, 2000, autoX: -1);
        double at200 = Measured(lab);
        Assert.Greater(at200, 300, $"input->motion {at200:F0} ms at 200 ms injected — latency not felt");
        Debug.Log($"OK lab01: {atZero:F0} ms at 0 injected, {at200:F0} ms at 200 ms");

        lab.Unmount();
        yield return Await(lab.RoomOf<Colyseus.Schema.Schema>().Leave());
    }

    private static double Measured(Lab01 lab)
    {
        var f = typeof(Lab01).GetField("_measured",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        return (double)f.GetValue(lab);
    }

    [UnityTest]
    public IEnumerator Lab02_clock_readouts_respond_to_injected_latency()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        DelayedConnection.SetLatency(200, 0);
        var lab = new Lab02();
        var mount = lab.Mount(app);
        yield return Await(mount);
        Assert.IsTrue(mount.Result, "lab 02 failed to mount");

        yield return Drive(lab, app, 4000, autoX: 1);
        var clock = lab.RoomOf<Lab.BotsState>().Clock;
        Assert.Greater(clock.SmoothedRtt(), 350,
            $"smoothed rtt {clock.SmoothedRtt():F0} ms — the injector is not in the path");
        Assert.Greater(clock.LastServerTime(), 0, "no TIMED prefix: the clock never synced");
        Assert.Greater(clock.PatchInterval(), 0, "patch cadence never advertised");
        Debug.Log($"OK lab02: rtt {clock.SmoothedRtt():F0} ms, patch {clock.PatchInterval():F0} ms, " +
                  $"jitter {clock.Jitter():F1} ms");

        lab.Unmount();
        yield return Await(lab.RoomOf<Colyseus.Schema.Schema>().Leave());
    }

    [UnityTest]
    public IEnumerator Lab03_predicts_instantly_and_absorbs_a_mispredict()
    {
        var app = new App { Client = MakeClient(), PrivateRoom = true };
        DelayedConnection.SetLatency(200, 0);
        var lab = new Lab03();
        var mount = lab.Mount(app);
        yield return Await(mount);
        Assert.IsTrue(mount.Result, "lab 03 failed to mount");

        var recon = Recon(lab);
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
        double peak = MaxCorr(lab);
        Assert.Greater(peak, 0.05, "the impulse produced no visible correction");

        // ...and then decay back to steady state.
        yield return Drive(lab, app, 5000, autoX: 1);
        Assert.Less(recon.LastCorrectionMag, 0.05,
            $"corrections still {recon.LastCorrectionMag:F3} after 5 s — not converging");
        Debug.Log($"OK lab03 impulse: peak {peak:F3}, settled to {recon.LastCorrectionMag:F4}");

        lab.Unmount();
        yield return Await(lab.RoomOf<Colyseus.Schema.Schema>().Leave());
    }

    private static Reconciler<Lab.Player, Lab.MoveInput> Recon(Lab03 lab)
    {
        var f = typeof(Lab03).GetField("_recon",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        return (Reconciler<Lab.Player, Lab.MoveInput>)f.GetValue(lab);
    }

    private static double MaxCorr(Lab03 lab)
    {
        var f = typeof(Lab03).GetField("_maxCorrMag",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        return (double)f.GetValue(lab);
    }
}
