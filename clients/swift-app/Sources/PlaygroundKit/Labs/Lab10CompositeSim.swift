import Colyseus
import Foundation

/// Lab 10 — Composite Sim.
///
/// A paddle and a puck rolled back together, because one hits the other.
/// Replaying the paddle without the puck it just struck reproduces a different
/// contact, so both are parts of one reconciler and both are re-adopted from
/// the same server tick on every ack.
///
/// The bot paddle is predicted in full: its policy is a pure function of
/// synced state, so the client can run the server's own decision. Remote
/// humans enter as colliders at their latest snapshot, which is where a
/// contested touch honestly mispredicts.
public final class Lab10CompositeSim: Lab, @unchecked Sendable {
    public static let id = "10"
    public static let title = "Composite Sim"
    public static let summary = "A paddle and a puck rolled back together."

    private var room: Colyseus.Room<LabHockey.HockeyState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var sim: Colyseus.Reconciler?
    private var keyboard: Keyboard?
    private var smoothingIndex = 2
    private static let smoothingPresets: [Double] = [0, 30, 65, 120, 250]

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-hockey", LabHockey.HockeyState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-hockey gave no predict or input channel")
        }

        self.room = room
        self.predict = predict
        self.input = input
        keyboard = context.keyboard

        guard let state = room.state else { return }
        // Lerp, not damped: a remote paddle is a COLLIDER in the step as well
        // as a sprite, and damped's lag varies with velocity — the gap between
        // the pose you see and the snapshot the step collides against would
        // breathe with it.
        predict.attachAll(state.players, fields: ["x", "y"],
                          options: .init(mode: .lerp, delay: Sim.remoteInterpMs),
                          except: room.sessionId)
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let predict, let input, let keyboard else { return }

        spawnSimIfNeeded()

        for _ in 0 ..< predict.tick(now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        if keyboard.takeEdge("b") { room.send("bot", ["on": .bool(!(room.state?.botEnabled ?? true))]) }
        if keyboard.takeEdge("r") { room.send("resetPuck") }
        if keyboard.takeEdge(".") {
            smoothingIndex = (smoothingIndex + 1) % Self.smoothingPresets.count
            // A smoothing change respawns the controller — and the old one has
            // to go first, or two of them contend for the same input handle.
            sim?.dispose()
            sim = nil
        }
    }

    private func spawnSimIfNeeded() {
        guard sim == nil,
              let room, let predict, let input,
              let state = room.state,
              let sessionId = room.sessionId,
              let me = state.players[sessionId],
              let puck = state.puck
        else { return }

        var parts: [Colyseus.SimPart] = [.bound("paddle", me), .bound("puck", puck)]
        let bot = state.players[Sim.hockeyBotId]
        if let bot { parts.append(.bound("bot", bot)) }

        sim = predict.sim(
            input: input,
            parts: parts,
            smoothMs: Self.smoothingPresets[smoothingIndex]
        ) { context, world, command in
            guard let paddleView = world["paddle"], let puckView = world["puck"] else { return }

            // The server's order, reproduced: paddles, then the puck, then the
            // contacts, in the players-map order.
            var paddle = Sim.Entity(view: paddleView)
            Sim.stepEntity(&paddle, moveX: command["moveX"], moveY: command["moveY"], dt: context.dt)
            paddle.write(to: paddleView)

            var botBody: Sim.Entity?
            if let botView = world["bot"] {
                var body = Sim.Entity(view: botView)
                var puckBefore = Sim.Entity(view: puckView)
                // The bot steps from the PRE-step puck, exactly as the server's
                // paddle loop runs before stepPuck.
                let move = Sim.botInput(
                    botX: body.x, botY: body.y,
                    puckX: puckBefore.x, puckY: puckBefore.y,
                    enabled: state.botEnabled
                )
                Sim.stepEntity(&body, moveX: move.moveX, moveY: move.moveY, dt: context.dt)
                body.write(to: botView)
                botBody = body
                _ = puckBefore
            }

            var puckBody = Sim.Entity(view: puckView)
            Sim.stepPuck(&puckBody, dt: context.dt)

            for (sessionId, player) in state.players.entries {
                if sessionId == room.sessionId {
                    Sim.collidePaddlePuck(paddleX: paddle.x, paddleY: paddle.y,
                                          paddleVx: paddle.vx, paddleVy: paddle.vy, puck: &puckBody)
                } else if sessionId == Sim.hockeyBotId, let botBody {
                    Sim.collidePaddlePuck(paddleX: botBody.x, paddleY: botBody.y,
                                          paddleVx: botBody.vx, paddleVy: botBody.vy, puck: &puckBody)
                } else {
                    // A remote human, as a zero-delta collider at its last
                    // known pose. Their next input is unknowable, so this is
                    // where a contested touch mispredicts by design.
                    Sim.collidePaddlePuck(paddleX: player.x, paddleY: player.y,
                                          paddleVx: player.vx, paddleVy: player.vy, puck: &puckBody)
                }
            }

            puckBody.write(to: puckView)
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let predict, let state = room.state else { return }

        for (sessionId, player) in state.players.entries {
            let isMe = sessionId == room.sessionId
            let isBot = sessionId == Sim.hockeyBotId
            list.circle(predict.value(player, "x"), predict.value(player, "y"),
                        radius: Sim.paddleRadius,
                        color: isBot ? Palette.warn : WorldView.color(hue: player.hue),
                        alpha: isMe ? 1 : 0.75)
        }

        if let puck = state.puck {
            // The predicted puck, and a dashed ghost where the server has it.
            list.circle(predict.value(puck, "x"), predict.value(puck, "y"),
                        radius: Sim.puckRadius, color: Palette.ghost)
            list.circleOutline(puck.x, puck.y, radius: Sim.puckRadius,
                               color: Palette.ghost, alpha: 0.3, dashed: true)
        }
    }

    public func unmount() {
        sim?.dispose()
        sim = nil
        predict = nil
        room = nil
        input = nil
    }

    public func onReconnect() {
        sim?.reset()
        input?.reset()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        var rows = [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("bot", (room.state?.botEnabled ?? false) ? "predicted" : "off"),
            TelemetryRow("smoothing", "\(Int(Self.smoothingPresets[smoothingIndex])) ms"),
        ]

        if let sim {
            let drift = sim.drift
            // A composite sim re-adopts a whole world every ack, so it cannot
            // reconcile to exactly zero the way a flat reconciler does. The
            // playground measured 0.5 as the line between an honest contested
            // touch and a real determinism bug.
            let verdict: TelemetryRow.Verdict = drift.ema < 0.5 ? .good : .bad
            rows.append(TelemetryRow("pending", "\(sim.pendingCount)"))
            rows.append(TelemetryRow("correction", String(format: "%.3f", sim.lastCorrectionMagnitude)))
            rows.append(TelemetryRow("drift ema", String(format: "%.3f", drift.ema), verdict))
        }
        return rows
    }

    public var controls: [Control] {
        [
            Control(key: "B", label: "bot", value: (room?.state?.botEnabled ?? false) ? "on" : "off"),
            Control(key: "R", label: "reset puck"),
            Control(key: ".", label: "smoothing", value: "\(Int(Self.smoothingPresets[smoothingIndex])) ms"),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
