import Colyseus
import Foundation

/// Lab 08 — Optimistic Events.
///
/// The GOAL banner fires the instant your PREDICTED square crosses the line,
/// then settles against the server: confirmed by the `goal` broadcast, or
/// auto-rejected once the server has processed past the predicting input
/// without agreeing.
///
/// The zone gate itself is shared deterministic simulation over a reconciled
/// tick field, so whether you *entered* is never a misprediction. Only the
/// server's deny roll can retract one — turn the deny rate up and watch.
public final class Lab08OptimisticEvents: Lab, @unchecked Sendable {
    public static let id = "08"
    public static let title = "Optimistic Events"
    public static let summary = "Show the goal when you predict it; confirm or retract when the server rules."

    private var room: Colyseus.Room<LabGoal.GoalState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var reconciler: Colyseus.Reconciler?
    private var goals: Colyseus.EventChannel?
    private var keyboard: Keyboard?

    private let predicted = Tally()
    private let confirmed = Tally()
    private let rejected = Tally()
    private var bannerUntil = 0.0
    private var bannerText = ""
    private var denyRate = 0

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-goal", LabGoal.GoalState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-goal gave no predict or input channel")
        }

        self.room = room
        self.predict = predict
        self.input = input
        keyboard = context.keyboard

        if let state = room.state {
            predict.attachAll(state.players, fields: ["x", "y"],
                              options: .init(mode: .damped), except: room.sessionId)
        }

        goals = predict.defineEvent(
            label: "goal",
            onPredict: { [weak self] _ in
                self?.predicted.increment()
                self?.say("GOAL")
            },
            onConfirm: { [weak self] _ in self?.confirmed.increment() },
            onReject: { [weak self] _ in
                self?.rejected.increment()
                self?.say("DENIED")
            }
        )

        let sessionId = room.sessionId
        room.onMessage("goal") { [weak self] payload in
            guard payload["sid"]?.string == sessionId else { return }
            // A confirm that settles nothing means the server scored one the
            // client never saw coming.
            _ = self?.goals?.confirm()
        }
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let predict, let input, let keyboard else { return }

        spawnReconcilerIfNeeded()

        for _ in 0 ..< predict.tick(now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        if keyboard.takeEdge("y") {
            denyRate = denyRate >= 100 ? 0 : denyRate + 25
            room.send("denyRate", ["rate": .int(Int64(denyRate))])
        }
    }

    private func spawnReconcilerIfNeeded() {
        guard reconciler == nil,
              let room, let predict, let input, let goals,
              let sessionId = room.sessionId,
              let me = room.state?.players[sessionId]
        else { return }

        let scored = Tally()
        reconciler = predict.reconciler(
            truth: me, input: input,
            // scoreTicks is reconciled state: the cooldown has to survive a
            // rollback, or a replay scores the same crossing twice.
            fields: ["x", "y", "vx", "vy", "scoreTicks"],
            smoothMs: 65
        ) { context, state, command in
            var entity = Sim.Entity(view: state)
            Sim.stepEntity(&entity, moveX: command["moveX"], moveY: command["moveY"], dt: context.dt)
            entity.write(to: state)

            var ticks = Int(state["scoreTicks"])
            let crossed = Sim.scoreGate(x: entity.x, y: entity.y, scoreTicks: &ticks)
            state.set("scoreTicks", to: Double(ticks))

            // Live steps only: a replay re-runs the physics, never the event.
            if crossed {
                context.predict(goals, key: "goal-\(scored.value)")
                scored.increment()
            }
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let predict, let state = room.state else { return }

        // The goal strip.
        list.rect(Sim.goalZone.x, Sim.goalZone.y, width: Sim.goalZone.width, height: Sim.goalZone.height,
                  color: Palette.good, alpha: 0.18)
        list.circleOutline(Sim.goalZone.x + Sim.goalZone.width / 2,
                           Sim.goalZone.y + Sim.goalZone.height / 2,
                           radius: 1, color: Palette.good, alpha: 0.5)

        for (sessionId, player) in state.players.entries {
            let isMe = sessionId == room.sessionId
            list.square(predict.value(player, "x"), predict.value(player, "y"),
                        half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue), alpha: isMe ? 1 : 0.5)
        }

        if room.clock.now < bannerUntil {
            list.label(Sim.arenaWidth / 2 - 8, Sim.arenaHeight / 2, bannerText,
                       color: bannerText == "GOAL" ? Palette.good : Palette.bad, size: 5)
        }
    }

    private func say(_ text: String) {
        bannerText = text
        bannerUntil = (room?.clock.now ?? 0) + 1200
    }

    public func unmount() {
        reconciler?.dispose()
        goals?.dispose()
        reconciler = nil
        goals = nil
        predict = nil
        room = nil
        input = nil
    }

    public func onReconnect() {
        reconciler?.reset()
        input?.reset()
        goals?.clear()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        var rows = [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("predicted", "\(predicted.value)"),
            TelemetryRow("confirmed", "\(confirmed.value)", .good),
            TelemetryRow("rejected", "\(rejected.value)", rejected.value > 0 ? .warn : .neutral),
            TelemetryRow("pending", "\(goals?.pendingCount ?? 0)"),
            TelemetryRow("deny rate", "\(denyRate)%", denyRate > 0 ? .warn : .neutral),
        ]
        if let reconciler {
            rows.append(TelemetryRow("score", String(format: "%.0f", reconciler.value("scoreTicks"))))
        }
        return rows
    }

    public var controls: [Control] {
        [Control(key: "Y", label: "deny rate", value: "\(denyRate)%")]
    }

    public var roomHandle: AnyObject? { room }
}

/// A counter that escaping handlers and the step closure can both touch.
public final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
