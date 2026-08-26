import Colyseus
import Foundation

/// Lab 05 — Dead Reckoning.
///
/// Instead of interpolating between snapshots, forward-simulate the last one
/// through the same step the server runs. Where it applies there is no render
/// delay at all — the client computes what the server is about to send.
///
/// Set the pattern to `wander` to see the honest limit: that bot re-rolls its
/// heading from a seed only the server has, so reckoning visibly breaks. That
/// is the technique's boundary, not a bug.
public final class Lab05DeadReckoning: Lab, @unchecked Sendable {
    public static let id = "05"
    public static let title = "Dead Reckoning"
    public static let summary = "Forward-simulate the last snapshot instead of interpolating it."

    private var room: Colyseus.Room<LabBots.BotsState>?
    /// The reckoned view, and a lerped one beside it as the baseline.
    private var reckon: Colyseus.Predict?
    private var baseline: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var keyboard: Keyboard?
    private var pacer = FixedStepPacer()
    private var patternIndex = 3
    private static let patterns = ["patrol", "circle", "wander", "teleport"]

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-bots", LabBots.BotsState.self)
        self.room = room
        input = room.input()
        keyboard = context.keyboard

        guard let state = room.state,
              let reckon = Colyseus.Predict.get(room),
              let baseline = Colyseus.Predict.get(room)
        else { return }

        // The reckoned bots run the server's own step. `snap` cuts rather than
        // glides when the teleporter warps, which is a discontinuity and not a
        // reckoning failure.
        reckon.attachAllReckon(
            state.bots,
            fields: ["x", "y"],
            smoothMs: 60,
            snap: Sim.teleportSnapDistance
        ) { bot, dt, elapsedMs in
            var simulated = Sim.Bot(view: bot)
            Sim.stepBot(&simulated, dt: dt, elapsedMs: elapsedMs)
            simulated.write(to: bot)
        }
        self.reckon = reckon

        baseline.attachAll(state.bots, fields: ["x", "y"],
                           options: .init(mode: .lerp, delay: Sim.remoteInterpMs))
        self.baseline = baseline

        room.send("pattern", ["kind": .string(Self.patterns[patternIndex])])
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let input, let keyboard else { return }

        for _ in 0 ..< pacer.steps(at: now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        reckon?.tick(now)
        baseline?.tick(now)

        if keyboard.takeEdge("p") {
            patternIndex = (patternIndex + 1) % Self.patterns.count
            room.send("pattern", ["kind": .string(Self.patterns[patternIndex])])
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let state = room.state else { return }

        for (_, bot) in state.bots.entries {
            // The baseline: interpolated, and so a render delay behind.
            if let baseline {
                list.circleOutline(baseline.value(bot, "x"), baseline.value(bot, "y"),
                                   radius: Sim.botRadius, color: Palette.dim, alpha: 0.6, dashed: true)
            }
            // The reckoned one: computed forward to now.
            if let reckon {
                list.circle(reckon.value(bot, "x"), reckon.value(bot, "y"),
                            radius: Sim.botRadius, color: Palette.good, alpha: 0.95)
            }
            // And where the server actually last said it was.
            list.circleOutline(bot.x, bot.y, radius: Sim.botRadius * 0.5,
                               color: Palette.ghost, alpha: 0.35)
        }

        for (sessionId, player) in state.players.entries {
            list.square(player.x, player.y, half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue),
                        alpha: sessionId == room.sessionId ? 1 : 0.5)
        }

        list.label(3, 6, "reckoned", color: Palette.good, size: 2.0)
        list.label(3, 9.2, "lerped", color: Palette.dim, size: 2.0)
    }

    public func unmount() {
        reckon = nil
        baseline = nil
        room = nil
        input = nil
    }

    public var telemetry: [TelemetryRow] {
        guard let room, let state = room.state else { return [] }

        // How far the two views disagree — near zero while the pattern is
        // computable, and visibly not on `wander`.
        var gap = 0.0
        if let reckon, let baseline {
            for (_, bot) in state.bots.entries {
                let dx = reckon.value(bot, "x") - baseline.value(bot, "x")
                let dy = reckon.value(bot, "y") - baseline.value(bot, "y")
                gap = max(gap, (dx * dx + dy * dy).squareRoot())
            }
        }

        let pattern = Self.patterns[patternIndex]
        return [
            TelemetryRow("pattern", pattern, pattern == "wander" ? .warn : .good),
            TelemetryRow("gap", String(format: "%.2f u", gap)),
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("predictable", pattern == "wander" ? "no — server seed" : "yes",
                         pattern == "wander" ? .warn : .good),
        ]
    }

    public var controls: [Control] {
        [Control(key: "P", label: "pattern", value: Self.patterns[patternIndex])]
    }

    public var roomHandle: AnyObject? { room }
}

extension Sim.Bot {
    /// Read a bot out of a schema instance, including the fields the step
    /// needs that prediction never touches.
    init(view: SchemaView) {
        self.init()
        x = view["x"]
        y = view["y"]
        vx = view["vx"]
        vy = view["vy"]
        kind = view.string("kind") ?? "patrol"
        minX = view["minX"]
        maxX = view["maxX"]
        baseY = view["baseY"]
        phaseMs = view["phaseMs"]
        speed = view["speed"]
        lastTeleport = view["lastTeleport"]
    }

    func write(to view: SchemaView) {
        view.set("x", to: x)
        view.set("y", to: y)
        if view.has("vx") { view.set("vx", to: vx) }
        if view.has("vy") { view.set("vy", to: vy) }
        if view.has("lastTeleport") { view.set("lastTeleport", to: lastTeleport) }
    }
}
