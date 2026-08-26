import Colyseus
import Foundation

/// Lab 02 — Clocks.
///
/// Three timelines at once: local time, the estimated server time, and the
/// slew-limited render timeline the interpolating labs draw along. The strip
/// at the bottom marks each patch as it lands.
public final class Lab02Clocks: Lab, @unchecked Sendable {
    public static let id = "02"
    public static let title = "Clocks"
    public static let summary = "Local, estimated server, and render time."

    private var room: Colyseus.Room<LabBots.BotsState>?
    private var input: Colyseus.InputHandle?
    private var keyboard: Keyboard?
    private var pacer = FixedStepPacer()

    /// When patches landed, on the local clock — a patch is detected by the
    /// server timestamp changing, which is the only signal there is.
    private var arrivals: [Double] = []
    private var lastServerTime = 0.0

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-bots", LabBots.BotsState.self)
        self.room = room
        input = room.input()
        keyboard = context.keyboard
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let input, let keyboard else { return }

        for _ in 0 ..< pacer.steps(at: now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        let serverTime = room.clock.lastServerTime
        if serverTime != lastServerTime {
            lastServerTime = serverTime
            arrivals.append(now)
            if arrivals.count > 120 { arrivals.removeFirst(arrivals.count - 120) }
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let state = room.state else { return }

        for (_, bot) in state.bots.entries {
            list.circle(bot.x, bot.y, radius: Sim.botRadius, color: Palette.dim, alpha: 0.7)
        }
        for (sessionId, player) in state.players.entries {
            list.square(player.x, player.y, half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue),
                        alpha: sessionId == room.sessionId ? 1 : 0.5)
        }

        // Patch arrivals over the last two seconds, as ticks on a strip: even
        // spacing is a healthy connection, clumps are jitter.
        let now = room.clock.now
        let window = 2000.0
        list.line(from: (x: 4, y: Sim.arenaHeight - 4), to: (x: Sim.arenaWidth - 4, y: Sim.arenaHeight - 4),
                  color: Palette.grid, alpha: 0.5, width: 0.15)
        for arrival in arrivals where now - arrival < window {
            let t = (now - arrival) / window
            let x = Sim.arenaWidth - 4 - t * (Sim.arenaWidth - 8)
            list.line(from: (x: x, y: Sim.arenaHeight - 5.5), to: (x: x, y: Sim.arenaHeight - 2.5),
                      color: Palette.accent, alpha: 0.9, width: 0.2)
        }
    }

    public func unmount() {
        room = nil
        input = nil
        arrivals.removeAll()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        let clock = room.clock
        return [
            TelemetryRow("now", String(format: "%.0f", clock.now)),
            TelemetryRow("serverNow", String(format: "%.0f", clock.serverNow)),
            TelemetryRow("renderNow", String(format: "%.0f", clock.renderNow)),
            TelemetryRow("offset", String(format: "%.0f ms", clock.offset)),
            TelemetryRow("rtt", String(format: "%.0f ms", clock.rtt)),
            TelemetryRow("smoothed", String(format: "%.0f ms", clock.smoothedRtt)),
            TelemetryRow("jitter", String(format: "%.1f ms", clock.jitter),
                         clock.jitter > 30 ? .warn : .good),
            TelemetryRow("patch", String(format: "%.0f ms", clock.patchInterval)),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
