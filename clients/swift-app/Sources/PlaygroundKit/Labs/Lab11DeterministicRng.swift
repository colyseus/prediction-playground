import Colyseus
import Foundation

/// Lab 11 — Deterministic RNG.
///
/// The shotgun fan is random, and both sides roll it identically: the seed is
/// the input's sequence number and a per-round salt that rides the schema, so
/// nothing random goes on the wire and the client can draw the exact pellets
/// the server will resolve.
///
/// Press **X** to cheat with a local random source instead, and the overlay
/// stops lining up — which is the whole demonstration.
public final class Lab11DeterministicRng: Lab, @unchecked Sendable {
    public static let id = "11"
    public static let title = "Deterministic RNG"
    public static let summary = "Both sides derive the same shotgun spread from a shared seed."

    private struct Fan {
        let originX: Double
        let originY: Double
        let angles: [Double]
        let fromServer: Bool
        let until: Double
    }

    private var room: Colyseus.Room<LabRange.RangeState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var reconciler: Colyseus.Reconciler?
    private var keyboard: Keyboard?

    private var aim = (x: Sim.arenaWidth - 10, y: Sim.arenaHeight / 2)
    private var fans: [Fan] = []
    private var cheat = false
    private var fire = FireLatch()
    private var lastPredictedAngles: [Double] = []
    private var lastServerAngles: [Double] = []

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-range", LabRange.RangeState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-range gave no predict or input channel")
        }

        self.room = room
        self.predict = predict
        self.input = input
        keyboard = context.keyboard
        input.allowRewind { $0.bool("fire") }

        if let state = room.state {
            predict.attachAll(state.bots, fields: ["x", "y"],
                              options: .init(mode: .lerp, delay: Sim.remoteInterpMs))
        }

        let sessionId = room.sessionId
        room.onMessage("spread") { [weak self] payload in
            guard let self, payload["sid"]?.string == sessionId else { return }
            let angles = payload["angles"]?.array?.compactMap { $0.double } ?? []
            lastServerAngles = angles
            fans.append(Fan(
                originX: payload["ox"]?.double ?? 0,
                originY: payload["oy"]?.double ?? 0,
                angles: angles,
                fromServer: true,
                until: room.clock.now + 2500
            ))
        }
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let predict, let input, let keyboard else { return }

        spawnReconcilerIfNeeded()
        fire.arm(keyboard.takeEdge("space"))
        if keyboard.takeEdge("x") { cheat.toggle() }

        for _ in 0 ..< predict.tick(now) {
            let wantsFire = fire.take()
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.data.set("aimX", to: aim.x)
            input.data.set("aimY", to: aim.y)
            input.data.set("fire", to: wantsFire)
            input.data.set("spread", to: true)

            // The sequence number the send returns IS the seed. Nothing about
            // the roll travels; both sides derive it from (seq, salt).
            let seq = input.send()

            // The raw predicted pose, matching what the server fires from.
            if wantsFire, let state = reconciler?.state {
                let originX = state["x"]
                let originY = state["y"]
                let base = atan2(aim.y - originY, aim.x - originX)
                let salt = UInt32(truncatingIfNeeded: Int(room.state?.salt ?? 0))

                let angles = cheat
                    // Local randomness cannot be re-derived by anyone, which is
                    // exactly why the overlay stops matching.
                    ? (0 ..< Sim.pellets).map { _ in
                        base + (Double.random(in: 0 ..< 1) - 0.5) * Sim.spreadRadians
                    }
                    : Sim.spreadAngles(base: base, seq: seq, salt: salt)

                lastPredictedAngles = angles
                fans.append(Fan(originX: originX, originY: originY, angles: angles,
                                fromServer: false, until: now + 2500))
            }
        }

        fans.removeAll { $0.until < now }
    }

    public func setAim(x: Double, y: Double) {
        aim = (x: x, y: y)
    }

    private func spawnReconcilerIfNeeded() {
        guard reconciler == nil,
              let room, let predict, let input,
              let sessionId = room.sessionId,
              let me = room.state?.players[sessionId]
        else { return }

        reconciler = predict.reconciler(
            truth: me, input: input, fields: ["x", "y", "vx", "vy"], smoothMs: 65
        ) { context, state, command in
            var entity = Sim.Entity(view: state)
            Sim.stepEntity(&entity, moveX: command["moveX"], moveY: command["moveY"], dt: context.dt)
            entity.write(to: state)
        }
    }

    public func draw(_ list: inout DrawList) {
        guard let room, let predict, let state = room.state else { return }

        for (_, bot) in state.bots.entries {
            list.circle(predict.value(bot, "x"), predict.value(bot, "y"),
                        radius: Sim.botRadius, color: Palette.warn, alpha: 0.8)
        }
        for (sessionId, player) in state.players.entries {
            list.square(predict.value(player, "x"), predict.value(player, "y"),
                        half: Sim.playerHalf, color: WorldView.color(hue: player.hue),
                        alpha: sessionId == room.sessionId ? 1 : 0.5)
        }

        // Two fans overlaid: the client's prediction, and the server's answer.
        // They sit on top of each other until you cheat.
        for fan in fans {
            for angle in fan.angles {
                let length = 24.0
                list.line(
                    from: (x: fan.originX, y: fan.originY),
                    to: (x: fan.originX + cos(angle) * length, y: fan.originY + sin(angle) * length),
                    color: fan.fromServer ? Palette.good : Palette.accent,
                    alpha: fan.fromServer ? 0.55 : 0.9,
                    width: fan.fromServer ? 0.3 : 0.12
                )
            }
        }

        list.label(3, 6, "predicted", color: Palette.accent, size: 2.0)
        list.label(3, 9.2, "server", color: Palette.good, size: 2.0)
    }

    public func unmount() {
        reconciler?.dispose()
        reconciler = nil
        predict = nil
        room = nil
        input = nil
        fans.removeAll()
    }

    public func onReconnect() {
        reconciler?.reset()
        input?.reset()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }

        // How far apart the two fans are, pellet for pellet. Zero unless
        // someone is cheating.
        var mismatch = 0.0
        if lastPredictedAngles.count == lastServerAngles.count {
            for (a, b) in zip(lastPredictedAngles, lastServerAngles) {
                mismatch = max(mismatch, abs(a - b))
            }
        }

        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("salt", String(format: "%.0f", room.state?.salt ?? 0)),
            TelemetryRow("source", cheat ? "Double.random" : "shared seed", cheat ? .bad : .good),
            TelemetryRow("mismatch", String(format: "%.6f rad", mismatch),
                         mismatch < 1e-12 ? .good : .bad),
        ]
    }

    public var controls: [Control] {
        [
            Control(key: "space", label: "fire"),
            Control(key: "X", label: "cheat", value: cheat ? "on" : "off"),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
