import Colyseus
import Foundation

/// Lab 00 — Lag vs Prediction.
///
/// One entity, two lanes, one room. The top lane draws the server's position
/// as it arrives; the bottom lane draws the prediction. At any real latency
/// they visibly separate by about the round trip, which is the whole case for
/// everything that follows.
///
/// It is lab 03's netcode mounted once and rendered twice — the point is that
/// the difference is in the drawing, not in the connection.
public final class Lab00Split: Lab, @unchecked Sendable {
    public static let id = "00"
    public static let title = "Lag vs Prediction"
    public static let summary = "The same entity drawn twice: as it arrives, and as predicted."

    private var lane: MoveLane?

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-move", LabMove.MoveState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-move gave no predict or input channel")
        }

        let lane = MoveLane(room: room, predict: predict, input: input, keyboard: context.keyboard)
        lane.start()
        self.lane = lane
    }

    public func frame(now: Double, dt: Double) {
        lane?.drive(now: now)
    }

    public func draw(_ list: inout DrawList) {
        guard let lane, let me = lane.me else { return }

        let quarter = Sim.arenaHeight / 4
        let colour = WorldView.color(hue: me.hue)

        // Divider, and a word on each lane.
        list.line(from: (x: 0, y: Sim.arenaHeight / 2), to: (x: Sim.arenaWidth, y: Sim.arenaHeight / 2),
                  color: Palette.grid, alpha: 0.5, width: 0.12)
        list.label(4, quarter - 6, "SERVER", color: Palette.dim, size: 2.2)
        list.label(4, quarter * 3 - 6, "PREDICTED", color: Palette.accent, size: 2.2)

        // Top: the raw decoded position, squashed into the upper half.
        let server = lane.serverPosition
        list.square(server.x, quarter + (server.y - Sim.arenaHeight / 2) / 2,
                    half: Sim.playerHalf, color: colour, alpha: 0.55)

        // Bottom: the reconciled pose, the same way.
        let predicted = lane.predictedPosition
        list.square(predicted.x, quarter * 3 + (predicted.y - Sim.arenaHeight / 2) / 2,
                    half: Sim.playerHalf, color: colour)
    }

    public func unmount() {
        lane?.dispose()
        lane = nil
    }

    public func onReconnect() {
        lane?.reset()
    }

    public var telemetry: [TelemetryRow] {
        guard let lane else { return [] }
        var rows = lane.telemetry
        // What the two lanes are apart by, which is what the lab is about.
        let gap = (lane.predictedPosition.x - lane.serverPosition.x)
        rows.append(TelemetryRow("lead", String(format: "%.2f u", abs(gap))))
        return rows
    }

    public var roomHandle: AnyObject? { lane?.room }
}
