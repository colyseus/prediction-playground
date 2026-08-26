import Colyseus
import Foundation

/// Lab 03 — Reconcile.
///
/// Predict locally; rewind and replay when the server disagrees. Your square is
/// the prediction, the dashed ghost is the last position the server confirmed,
/// and the red arrow is the correction being applied.
///
/// Press **I** and the server kicks you in a way the client never predicted:
/// the arrow appears and decays rather than snapping. Press **T** and the
/// server teleports you, which is a discontinuity rather than a mistake — the
/// snap threshold cuts instead of gliding.
public final class Lab03Reconcile: Lab, @unchecked Sendable {
    public static let id = "03"
    public static let title = "Reconcile"
    public static let summary = "Predict locally; rewind and replay when the server disagrees."

    /// Internal rather than private so the acceptance tests can read the
    /// reconciler's own numbers, not just the formatted telemetry.
    private(set) var lane: MoveLane?
    private var keyboard: Keyboard?
    private var showGhost = true
    private var smoothingIndex = 2
    private static let smoothingPresets: [Double] = [0, 30, 65, 120, 250]

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-move", LabMove.MoveState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-move gave no predict or input channel")
        }

        let lane = MoveLane(
            room: room, predict: predict, input: input,
            keyboard: context.keyboard, smoothMs: Self.smoothingPresets[smoothingIndex]
        )
        lane.start()
        self.lane = lane
        keyboard = context.keyboard
    }

    public func frame(now: Double, dt: Double) {
        guard let lane, let keyboard else { return }
        lane.drive(now: now)

        if keyboard.takeEdge("i") { lane.room.send("impulse") }
        if keyboard.takeEdge("t") { lane.room.send("teleport") }
        if keyboard.takeEdge("g") { showGhost.toggle() }
        // `,` and `.` rather than `[` and `]`: the shell owns those for
        // stepping between labs.
        let step = keyboard.takeEdge(",") ? -1 : (keyboard.takeEdge(".") ? 1 : 0)
        if step != 0 {
            smoothingIndex = (smoothingIndex + step + Self.smoothingPresets.count) % Self.smoothingPresets.count
            lane.setSmoothing(Self.smoothingPresets[smoothingIndex])
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let lane, let state = lane.room.state else { return }

        // Everyone else, smoothed.
        for (sessionId, player) in state.players.entries where sessionId != lane.room.sessionId {
            let x = lane.predict.value(player, "x")
            let y = lane.predict.value(player, "y")
            list.square(x, y, half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue), alpha: 0.55)
        }

        guard let me = lane.me else { return }
        let predicted = lane.predictedPosition
        let server = lane.serverPosition

        if showGhost {
            list.squareOutline(server.x, server.y, half: Sim.playerHalf,
                               color: Palette.ghost, alpha: 0.35, dashed: true)
        }

        list.square(predicted.x, predicted.y, half: Sim.playerHalf,
                    color: WorldView.color(hue: me.hue))

        // The correction, drawn from where the server put you to where you are.
        let dx = predicted.x - server.x
        let dy = predicted.y - server.y
        if (dx * dx + dy * dy).squareRoot() > 0.05 {
            list.line(from: (x: server.x, y: server.y), to: (x: predicted.x, y: predicted.y),
                      color: Palette.bad, alpha: 0.9, width: 0.28)
        }
    }

    public func unmount() {
        lane?.dispose()
        lane = nil
    }

    public func onReconnect() {
        lane?.reset()
    }

    public var telemetry: [TelemetryRow] { lane?.telemetry ?? [] }

    public var controls: [Control] {
        [
            Control(key: "I", label: "impulse"),
            Control(key: "T", label: "teleport"),
            Control(key: "G", label: "ghost", value: showGhost ? "on" : "off"),
            Control(key: ", .", label: "smoothing",
                    value: "\(Int(Self.smoothingPresets[smoothingIndex])) ms"),
        ]
    }

    public var roomHandle: AnyObject? { lane?.room }
}
