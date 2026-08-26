import Colyseus
import Foundation

/// Lab 01 — Feel the Lag.
///
/// Draws the server's position directly, with no prediction at all, so every
/// keypress waits a full round trip before anything moves. Turn the latency up
/// and the square rubber-bands; that gap is what the rest of the labs close.
public final class Lab01FeelTheLag: Lab, @unchecked Sendable {
    public static let id = "01"
    public static let title = "Feel the Lag"
    public static let summary = "The server's position, drawn as it arrives."

    private var room: Colyseus.Room<LabMove.MoveState>?
    private var input: Colyseus.InputHandle?
    private var keyboard: Keyboard?
    // No reconciler here, so predict.tick would return nothing: this lab paces
    // its own sends.
    private var pacer = FixedStepPacer()

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-move", LabMove.MoveState.self)
        self.room = room
        input = room.input()
        keyboard = context.keyboard
    }

    public func frame(now: Double, dt: Double) {
        guard let input, let keyboard else { return }
        for _ in 0 ..< pacer.steps(at: now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let state = room.state else { return }
        for (sessionId, player) in state.players.entries {
            let isMe = sessionId == room.sessionId
            // The raw decoded value — no smoothing, no prediction.
            list.square(player.x, player.y, half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue), alpha: isMe ? 1 : 0.5)
            if isMe {
                list.squareOutline(player.x, player.y, half: Sim.playerHalf + 0.5,
                                   color: Palette.ghost, alpha: 0.6)
            }
        }
    }

    public func unmount() {
        room = nil
        input = nil
    }

    public var telemetry: [TelemetryRow] {
        guard let room, let input else { return [] }
        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("sent", "\(input.sentCount)"),
            TelemetryRow("prediction", "none", .warn),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
