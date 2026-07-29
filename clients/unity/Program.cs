// Unity/C#-SDK validation client for the Colyseus Prediction Playground.
//
// Headless probe against the demo server (pnpm dev, port 5173) exercising the
// predict layer end-to-end against live rooms — the C# twin of
// scripts/probe-*.mjs and clients/native/predict_probe.c:
//
//   A  lab-move        join, TIMED clock sync, reconciler over the ported
//                      stepEntity, impulse -> correction -> recovery
//   B  lab-bots        passive smoothing (lerp) over the patrol bot
//   C  lab-goal        sim-born optimistic event (ctx.Predict) -> server
//                      "goal" broadcast -> confirm
//   D  lab-projectile  predicted spawn -> in-place authoritative handoff
//
// NOTE on determinism: C# schema "number" fields are float32, so the predicted
// mirror steps in f32 while the server steps in f64 — corrections are asserted
// SMALL (wire precision), not exactly zero like the f64 ports.
//
// Run: dotnet run --project clients/unity [-- port]
using Colyseus;
using Colyseus.Predict;
using Colyseus.Schema;
using System;
using System.Threading.Tasks;
// The referenced Colyseus test assembly ships fixture types in the GLOBAL
// namespace (e.g. a Lab.Player with only x/y) that shadow using-imports, so lab
// types are referenced through an explicit namespace alias.
using Lab = PredictProbe.LabSchema;

namespace PredictProbe;

public static class Program
{
	private static int checksFailed;

	private static void Check(string name, bool ok, string detail = null)
	{
		Console.WriteLine($"{(ok ? "OK  " : "FAIL")} {name}{(detail != null ? $" — {detail}" : "")}");
		if (!ok) { checksFailed++; }
	}

	// --- shared sim (ported bit-faithful from src/shared) -------------------

	private const double TickHz = 20;
	private const double ArenaW = 100, ArenaH = 60, PlayerHalf = 1.6;
	private const double PlayerAccel = 220, PlayerMaxSpeed = 34, PlayerFrictionK = 0.72;
	private const double GoalZoneX = ArenaW - 8, GoalZoneY = ArenaH / 2 - 9, GoalZoneH = 18;
	private const int ScoreCooldownTicks = 50;
	private const double ProjectileSpeed = 34;

	private struct Entity { public double X, Y, Vx, Vy; }

	/// <summary>shared/movement.ts stepEntity — same op order, same constants.</summary>
	private static void StepEntity(ref Entity e, double moveX, double moveY, double dt)
	{
		double ax = moveX, ay = moveY;
		if (ax != 0 && ay != 0) { ax *= Math.Sqrt(0.5); ay *= Math.Sqrt(0.5); }

		if (ax != 0 || ay != 0)
		{
			e.Vx += ax * PlayerAccel * dt;
			e.Vy += ay * PlayerAccel * dt;
		}
		else
		{
			e.Vx *= PlayerFrictionK;
			e.Vy *= PlayerFrictionK;
			if (e.Vx > -0.05 && e.Vx < 0.05) { e.Vx = 0; }
			if (e.Vy > -0.05 && e.Vy < 0.05) { e.Vy = 0; }
		}

		double sq = e.Vx * e.Vx + e.Vy * e.Vy;
		if (sq > PlayerMaxSpeed * PlayerMaxSpeed)
		{
			double s = PlayerMaxSpeed / Math.Sqrt(sq);
			e.Vx *= s;
			e.Vy *= s;
		}

		e.X += e.Vx * dt;
		e.Y += e.Vy * dt;

		double minX = PlayerHalf, maxX = ArenaW - PlayerHalf;
		double minY = PlayerHalf, maxY = ArenaH - PlayerHalf;
		if (e.X < minX) { e.X = minX; if (e.Vx < 0) { e.Vx = 0; } }
		else if (e.X > maxX) { e.X = maxX; if (e.Vx > 0) { e.Vx = 0; } }
		if (e.Y < minY) { e.Y = minY; if (e.Vy < 0) { e.Vy = 0; } }
		else if (e.Y > maxY) { e.Y = maxY; if (e.Vy > 0) { e.Vy = 0; } }
	}

	// --- harness ------------------------------------------------------------

	private static async Task<Room<T>> JoinLab<T>(Client client, string name) where T : Schema, new()
	{
		var room = await client.JoinOrCreate<T>(name);
		var stateReceived = new TaskCompletionSource<bool>();
		room.OnStateChange += (_, first) =>
		{
			if (first) { stateReceived.TrySetResult(true); }
		};
		await Task.WhenAny(stateReceived.Task, Task.Delay(5000));
		await Task.Delay(300);   // one patch interval so the first TIMED sample lands
		return room;
	}

	public static async Task<int> Main(string[] args)
	{
		string port = args.Length > 0 ? args[0] : "5173";
		var client = new Client($"ws://127.0.0.1:{port}");
		Console.WriteLine($"predict_probe (C#) -> ws://127.0.0.1:{port}");

		await ScenarioMove(client);
		await ScenarioBots(client);
		await ScenarioGoal(client);
		await ScenarioProjectile(client);

		Console.WriteLine($"\n{(checksFailed == 0 ? "PROBE OK" : "PROBE FAILED")}");
		return checksFailed == 0 ? 0 : 1;
	}

	// --- A. lab-move --------------------------------------------------------

	private static async Task ScenarioMove(Client client)
	{
		Console.WriteLine("\n=== A. lab-move: join, clock, reconcile, impulse ===");
		var room = await JoinLab<Lab.MoveState>(client, "lab-move");
		Check("join lab-move", room != null);

		var me = room.State.players[room.SessionId];
		Check("own player spawned", me != null, $"session {room.SessionId}");
		Console.WriteLine($"     spawn at {me.x:F1} {me.y:F1} hue {me.hue}");

		Check("clock synced (TIMED prefix flowing)", room.Clock.LastServerTime() > 0,
			$"lastServerTime={room.Clock.LastServerTime():F0}");

		var command = new Lab.MoveInput();
		var input = room.Input(command);
		Check("input handle created", input != null);

		var predict = new Predict(new PredictCallbacks<Lab.MoveState>(Callbacks.Get(room)), room.Clock);
		var recon = predict.Reconciler(me, new ReconcilerOptions<Lab.Player, Lab.MoveInput>
		{
			Input = input,
			Fields = new[] { "x", "y", "vx", "vy" },
			Smoothing = 15,
			Step = (ctx, s, cmd) =>
			{
				var e = new Entity { X = s.x, Y = s.y, Vx = s.vx, Vy = s.vy };
				StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
				s.x = (float)e.X; s.y = (float)e.Y; s.vx = (float)e.Vx; s.vy = (float)e.Vy;
			},
		});
		Check("reconciler created (step 50ms adopted)", recon.StepMs == 50.0);
		var predicted = recon.State;

		double startX = predicted.x, earlyX = startX;
		double maxCorrSteady = 0;
		int maxPending = 0;

		// drive left for 2s at the fixed step, ticking at ~60fps
		double sendAcc = 0, last = RoomClock.GetNow();
		for (int frame = 0; frame < 125; frame++)
		{
			await Task.Delay(16);
			double now = RoomClock.GetNow();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50.0)
			{
				sendAcc -= 50.0;
				command.moveX = -1;
				command.moveY = 0;
				input.Send();
			}
			predict.Tick(now);
			if (frame == 9) { earlyX = predicted.x; }
			if (frame > 30)
			{
				maxCorrSteady = Math.Max(maxCorrSteady, recon.LastCorrectionMag);
				maxPending = Math.Max(maxPending, recon.PendingCount);
			}
			if (frame % 25 == 0)
			{
				Console.WriteLine($"     t={frame * 16,4}ms truth {me.x,6:F2},{me.y,6:F2} v {me.vx,6:F2},{me.vy,6:F2}"
					+ $" | pred {predicted.x,6:F2},{predicted.y,6:F2} | corr={recon.LastCorrectionMag:F3}");
			}
		}

		Check("predicted pose moves before RTT elapses", startX - earlyX > 0.3,
			$"dx={startX - earlyX:F2} in ~150ms");
		Check("steady-state corrections ~0 (f32 mirror vs f64 server)", maxCorrSteady < 0.05,
			$"max |correction| = {maxCorrSteady:E2}");
		double rtt = room.Clock.SmoothedRtt();
		Check("pending tracks RTT", maxPending <= (int)(rtt * TickHz / 1000.0 + 3),
			$"max pending={maxPending} rtt={rtt:F0}ms");
		Check("drift matched while driving",
			DriftClassifier.Classify(recon.Drift, 0.01) == DriftStatus.Matched,
			$"ema={recon.Drift.Ema:E2}");

		// server-side shove the client can't see coming — MUST mispredict
		await room.Send("impulse");
		double impulseCorr = 0;
		sendAcc = 0;
		last = RoomClock.GetNow();
		for (int frame = 0; frame < 220; frame++)
		{
			await Task.Delay(16);
			double now = RoomClock.GetNow();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50.0)
			{
				sendAcc -= 50.0;
				command.moveX = 0;
				command.moveY = 0;
				input.Send();   // keep acks flowing
			}
			predict.Tick(now);
			impulseCorr = Math.Max(impulseCorr, recon.LastCorrectionMag);
		}
		Check("impulse produces a visible correction", impulseCorr > 0.05,
			$"max |correction| = {impulseCorr:F3}");
		Check("drift recovers after impulse (not diverging)",
			DriftClassifier.Classify(recon.Drift, 0.01) != DriftStatus.Diverging,
			$"ema={recon.Drift.Ema:F4} peak={recon.Drift.Peak:F4}");

		double read = recon.Value("x");
		Check("Value(x) render read sane", !double.IsNaN(read) && Math.Abs(read - predicted.x) < 5.0,
			$"value={read:F2} state={predicted.x:F2}");

		await room.Leave();
	}

	// --- B. lab-bots --------------------------------------------------------

	private static async Task ScenarioBots(Client client)
	{
		Console.WriteLine("\n=== B. lab-bots: passive smoothing over a server-driven bot ===");
		var room = await JoinLab<Lab.BotsState>(client, "lab-bots");
		Check("join lab-bots", room != null);

		var bot = room.State.bots["bot1"];
		Check("bot1 present", bot != null);

		var predict = new Predict(new PredictCallbacks<Lab.BotsState>(Callbacks.Get(room)), room.Clock);
		predict.Attach(bot, new AttachConfig { ["x"] = PredictMode.Lerp, ["y"] = PredictMode.Lerp });
		Check("track bot1.x/y (lerp)", true);

		double first = double.NaN, lastV = double.NaN, minV = 1e9, maxV = -1e9;
		double maxFrameJump = 0, maxRawJump = 0, prevRaw = bot.x;
		for (int frame = 0; frame < 100; frame++)
		{
			await Task.Delay(16);
			double now = RoomClock.GetNow();
			predict.Tick(now);
			double v = predict.Value(bot, "x");
			if (double.IsNaN(first)) { first = v; }
			if (!double.IsNaN(lastV)) { maxFrameJump = Math.Max(maxFrameJump, Math.Abs(v - lastV)); }
			maxRawJump = Math.Max(maxRawJump, Math.Abs(bot.x - prevRaw));
			prevRaw = bot.x;
			lastV = v;
			minV = Math.Min(minV, v);
			maxV = Math.Max(maxV, v);
		}
		Check("lerped value follows the bot", Math.Abs(lastV - first) > 5.0,
			$"moved {Math.Abs(lastV - first):F1} units over 1.6s");
		Check("lerp output smoother than snapshots", maxFrameJump < maxRawJump,
			$"max frame jump {maxFrameJump:F2} < max snapshot jump {maxRawJump:F2}");
		Check("lerped value stays in the patrol band", minV > 20.0 && maxV < 80.0,
			$"range [{minV:F1}, {maxV:F1}]");

		await room.Leave();
	}

	// --- C. lab-goal --------------------------------------------------------

	private class GoalMsg { public string sid; }

	private static async Task ScenarioGoal(Client client)
	{
		Console.WriteLine("\n=== C. lab-goal: sim-born optimistic event -> server confirm ===");
		var room = await JoinLab<Lab.GoalState>(client, "lab-goal");
		Check("join lab-goal", room != null);

		var me = room.State.players[room.SessionId];
		Check("own player spawned", me != null);

		int predictedCount = 0, confirmedCount = 0, rejectedCount = 0;
		var predict = new Predict(new PredictCallbacks<Lab.GoalState>(Callbacks.Get(room)), room.Clock);
		var goals = predict.DefineEvent(new PredictedEventChannelOptions<int>
		{
			OnPredict = _ => predictedCount++,
			OnConfirm = _ => confirmedCount++,
			OnReject = _ => rejectedCount++,
		});

		room.OnMessage<GoalMsg>("goal", msg =>
		{
			if (msg.sid == room.SessionId) { goals.Confirm(); }
		});

		var command = new Lab.MoveInput();
		var input = room.Input(command);

		int n = 0;
		var recon = predict.Reconciler(me, new ReconcilerOptions<Lab.GoalPlayer, Lab.MoveInput>
		{
			Input = input,
			Fields = new[] { "x", "y", "vx", "vy", "scoreTicks" },
			Smoothing = 15,
			Step = (ctx, s, cmd) =>
			{
				var e = new Entity { X = s.x, Y = s.y, Vx = s.vx, Vy = s.vy };
				StepEntity(ref e, cmd.moveX, cmd.moveY, ctx.Dt);
				s.x = (float)e.X; s.y = (float)e.Y; s.vx = (float)e.Vx; s.vy = (float)e.Vy;

				// shared/goal.ts stepScoreGate — reconciled tick state
				if (s.scoreTicks > 0) { s.scoreTicks--; }
				else if (s.x >= GoalZoneX && s.y >= GoalZoneY && s.y <= GoalZoneY + GoalZoneH)
				{
					s.scoreTicks = ScoreCooldownTicks;
					ctx.Predict(goals, n++);   // live-only, replay-safe
				}
			},
		});
		Check("reconciler created (scoreTicks reconciled)", recon != null);
		var predicted = recon.State;

		double maxCorr = 0;
		double sendAcc = 0, last = RoomClock.GetNow();
		int frames = 0;
		for (; frames < 500 && confirmedCount == 0; frames++)
		{
			await Task.Delay(16);
			double now = RoomClock.GetNow();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50.0)
			{
				sendAcc -= 50.0;
				command.moveX = 1;
				command.moveY = (sbyte)(predicted.y < ArenaH / 2 - 2 ? 1 : predicted.y > ArenaH / 2 + 2 ? -1 : 0);
				input.Send();
			}
			predict.Tick(now);
			if (frames > 30) { maxCorr = Math.Max(maxCorr, recon.LastCorrectionMag); }
		}

		Check("optimistic goal predicted (sim-born, live step)", predictedCount >= 1,
			$"predicted={predictedCount} after {frames} frames");
		Check("server confirmed the goal", confirmedCount >= 1, $"confirmed={confirmedCount}");
		Check("no rejections (denyRate 0)", rejectedCount == 0);
		Check("gate deterministic through reconciles (corrections small)", maxCorr < 0.05,
			$"max |correction| = {maxCorr:E2}");

		await room.Leave();
	}

	// --- D. lab-projectile --------------------------------------------------

	private class LocalProjectile { public double X, Y, Vx, Vy; }

	private static async Task ScenarioProjectile(Client client)
	{
		Console.WriteLine("\n=== D. lab-projectile: predicted spawn -> authoritative handoff ===");
		var room = await JoinLab<Lab.ProjectileState>(client, "lab-projectile");
		Check("join lab-projectile", room != null);

		var me = room.State.players[room.SessionId];
		Check("own player spawned", me != null);

		int rejected = 0;
		bool foreignSeen = false;
		var predict = new Predict(new PredictCallbacks<Lab.ProjectileState>(Callbacks.Get(room)), room.Clock);
		var store = predict.Spawns<Lab.Projectile, LocalProjectile>("projectiles",
			new PredictedSpawnsOptions<Lab.Projectile, LocalProjectile>
			{
				Owned = p => p.owner == room.SessionId,
				SpawnTime = p => p.bornMs,
				Step = (l, dt) =>
				{
					// shared/projectile.ts stepProjectile over the pending local
					l.X += l.Vx * dt;
					l.Y += l.Vy * dt;
					if (l.X < 0) { l.X = 0; l.Vx = Math.Abs(l.Vx); }
					else if (l.X > ArenaW) { l.X = ArenaW; l.Vx = -Math.Abs(l.Vx); }
					if (l.Y < 0) { l.Y = 0; l.Vy = Math.Abs(l.Vy); }
					else if (l.Y > ArenaH) { l.Y = ArenaH; l.Vy = -Math.Abs(l.Vy); }
				},
				OnReject = (_, _) => rejected++,
			});

		var command = new Lab.RangeInput();
		var input = room.Input(command);

		// fire one shot at the turret (50, 8) and spawn the optimistic local
		double aimX = 50, aimY = 8;
		double dx = aimX - me.x, dy = aimY - me.y;
		double len = Math.Sqrt(dx * dx + dy * dy);
		dx /= len; dy /= len;
		var local = new LocalProjectile
		{
			X = me.x, Y = me.y,
			Vx = dx * ProjectileSpeed, Vy = dy * ProjectileSpeed,
		};

		command.aimX = (float)aimX;
		command.aimY = (float)aimY;
		command.fire = true;
		input.Send();
		command.fire = false;
		var handle = store.Spawn(local);

		Check("optimistic local pending immediately",
			!handle.Confirmed && handle.Local == local, $"id={handle.Id}");

		double sendAcc = 0, last = RoomClock.GetNow();
		double leadMs = 0;
		bool confirmed = false;
		for (int frame = 0; frame < 250 && !(confirmed && foreignSeen); frame++)
		{
			await Task.Delay(16);
			double now = RoomClock.GetNow();
			sendAcc += now - last;
			last = now;
			while (sendAcc >= 50.0)
			{
				sendAcc -= 50.0;
				input.Send();   // keep the input stream alive
			}
			predict.Tick(now);
			if (!confirmed && handle.Confirmed)
			{
				confirmed = true;
				leadMs = handle.LeadMs;
			}
			// the turret's projectiles must surface as foreign (server-only) entries
			foreach (var entry in store.Entries())
			{
				if (entry.Confirmed && entry.Local == null && entry.Server?.owner == "turret")
				{
					foreignSeen = true;
				}
			}
		}

		Check("authoritative projectile correlated IN PLACE (stable id)", confirmed, $"id={handle.Id}");
		Check("input lead measured", confirmed && leadMs > 0 && leadMs < 1000, $"leadMs={leadMs:F0}");
		Check("turret projectiles surface as foreign entries", foreignSeen);
		Check("own prediction not TTL-rejected", rejected == 0, $"rejected={rejected}");

		await room.Leave();
	}
}
