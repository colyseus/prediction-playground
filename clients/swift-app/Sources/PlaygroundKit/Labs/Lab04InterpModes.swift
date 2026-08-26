import Colyseus
import CoreGraphics
import Foundation

/// Lab 04 — Interp Modes.
///
/// One bot drawn four ways at once. `raw` steps as patches land; `lerp` glides
/// a render delay behind; `damped` chases without ever overshooting; and
/// `extrapolate` projects ahead and is wrong the moment the bot turns.
///
/// Four separate `Predict` instances over the same collection is the point:
/// each one carries its own smoothing, and the same decoded bot reads
/// differently through each.
public final class Lab04InterpModes: Lab, @unchecked Sendable {
    public static let id = "04"
    public static let title = "Interp Modes"
    public static let summary = "One bot drawn four ways: raw, lerp, damped, extrapolate."

    private struct Mode {
        let name: String
        let predict: Colyseus.Predict?
        let color: CGColor
        let offsetY: Double
    }

    private var room: Colyseus.Room<LabBots.BotsState>?
    private var modes: [Mode] = []
    private var input: Colyseus.InputHandle?
    private var keyboard: Keyboard?
    private var pacer = FixedStepPacer()
    private var patternIndex = 0
    private static let patterns = ["patrol", "circle", "wander", "teleport"]

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-bots", LabBots.BotsState.self)
        self.room = room
        input = room.input()
        keyboard = context.keyboard

        guard let state = room.state else { return }

        // One Predict per mode, each attached to the same bots.
        let specs: [(String, Colyseus.PredictMode?, CGColor, Double)] = [
            ("raw", nil, Palette.dim, -9),
            ("lerp", .lerp, Palette.accent, -3),
            ("damped", .damped, Palette.good, 3),
            ("extrapolate", .extrapolate, Palette.warn, 9),
        ]

        modes = specs.map { name, mode, color, offset in
            guard let mode, let predict = Colyseus.Predict.get(room) else {
                // `raw` needs no Predict at all — the value falls through to
                // whatever the decoder last wrote.
                return Mode(name: name, predict: nil, color: color, offsetY: offset)
            }
            predict.attachAll(
                state.bots, fields: ["x", "y"],
                options: .init(mode: mode, delay: Sim.remoteInterpMs, smoothMs: mode == .lerp ? 0 : 50)
            )
            return Mode(name: name, predict: predict, color: color, offsetY: offset)
        }

        room.send("pattern", ["kind": .string(Self.patterns[patternIndex])])
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let input, let keyboard else { return }

        for _ in 0 ..< pacer.steps(at: now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        // Each mode's Predict has to be ticked, and its values read, or
        // nothing is computed: reckoning and smoothing are on-demand.
        for mode in modes { mode.predict?.tick(now) }

        if keyboard.takeEdge("p") {
            patternIndex = (patternIndex + 1) % Self.patterns.count
            room.send("pattern", ["kind": .string(Self.patterns[patternIndex])])
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let state = room.state else { return }

        for (_, bot) in state.bots.entries {
            for mode in modes {
                let x = mode.predict.map { $0.value(bot, "x") } ?? bot.x
                let y = mode.predict.map { $0.value(bot, "y") } ?? bot.y
                list.circle(x, y + mode.offsetY, radius: Sim.botRadius, color: mode.color, alpha: 0.9)
            }
        }

        // A legend, so the four lanes read.
        for (offset, mode) in modes.enumerated() {
            list.label(3, 6 + Double(offset) * 3.2, mode.name, color: mode.color, size: 2.0)
        }

        for (sessionId, player) in state.players.entries {
            list.square(player.x, player.y, half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue),
                        alpha: sessionId == room.sessionId ? 1 : 0.5)
        }
    }

    public func unmount() {
        modes.removeAll()
        room = nil
        input = nil
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        return [
            TelemetryRow("pattern", Self.patterns[patternIndex]),
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("delay", String(format: "%.0f ms", Sim.remoteInterpMs)),
            TelemetryRow("bots", "\(room.state?.bots.count ?? 0)"),
        ]
    }

    public var controls: [Control] {
        [Control(key: "P", label: "pattern", value: Self.patterns[patternIndex])]
    }

    public var roomHandle: AnyObject? { room }
}
