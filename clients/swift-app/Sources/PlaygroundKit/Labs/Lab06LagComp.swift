import Colyseus
import Foundation

/// Lab 06 — Lag Compensation.
///
/// Shoot at where you SEE a bot, and the server rewinds to the instant you saw
/// it before deciding. Without that, at any real latency you have to lead your
/// target by the round trip and the game feels like it is lying to you.
///
/// The input handle's `allowRewind` gate marks which inputs carry a
/// lag-compensation stamp — the fire ones. Stamping every input would be
/// expensive and pointless.
public final class Lab06LagComp: Lab, @unchecked Sendable {
    public static let id = "06"
    public static let title = "Lag Compensation"
    public static let summary = "Shoot at where you see a bot; the server rewinds to that instant."

    private struct Marker {
        let x: Double
        let y: Double
        let hit: Bool
        let until: Double
    }

    private var room: Colyseus.Room<LabRange.RangeState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var reconciler: Colyseus.Reconciler?
    private var keyboard: Keyboard?

    private var aim = (x: Sim.arenaWidth - 10, y: Sim.arenaHeight / 2)
    private var markers: [Marker] = []
    private let shots = Tally()
    private var fire = FireLatch()
    private let hits = Tally()

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

        // Only the fire inputs get a lag-comp stamp.
        input.allowRewind { $0.bool("fire") }

        guard let state = room.state else { return }
        // The bots are what you shoot at, so they lerp at the delay the server
        // will rewind to. A reconciler built through the Predict binds that
        // delay to the input handle automatically.
        predict.attachAll(state.bots, fields: ["x", "y"],
                          options: .init(mode: .lerp, delay: Sim.remoteInterpMs))
        predict.attachAll(state.players, fields: ["x", "y"],
                          options: .init(mode: .damped), except: room.sessionId)

        let sessionId = room.sessionId
        room.onMessage("shot") { [weak self] payload in
            guard let self, payload["sid"]?.string == sessionId else { return }
            let hit = payload["hit"]?.bool ?? false
            shots.increment()
            if hit { hits.increment() }
            markers.append(Marker(
                x: payload["seenX"]?.double ?? 0,
                y: payload["seenY"]?.double ?? 0,
                hit: hit,
                until: (room.clock.now) + 1500
            ))
        }
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let predict, let input, let keyboard else { return }

        spawnReconcilerIfNeeded()
        fire.arm(keyboard.takeEdge("space"))
        if keyboard.takeEdge("c") {
            room.send("lagcomp", ["on": .bool(!(room.state?.lagComp ?? true))])
        }

        for _ in 0 ..< predict.tick(now) {
            let wantsFire = fire.take()
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.data.set("aimX", to: aim.x)
            input.data.set("aimY", to: aim.y)
            input.data.set("fire", to: wantsFire)
            input.data.set("spread", to: false)
            input.send()
        }

        markers.removeAll { $0.until < now }
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
                        radius: Sim.botRadius, color: Palette.warn, alpha: 0.9)
        }

        for (sessionId, player) in state.players.entries {
            let isMe = sessionId == room.sessionId
            list.square(predict.value(player, "x"), predict.value(player, "y"),
                        half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue), alpha: isMe ? 1 : 0.5)
        }

        // The aim ray, previewed with the same rayCircle the server resolves
        // with — a different reach would show a hit the server denies.
        if let reconciler {
            let originX = reconciler.value("x")
            let originY = reconciler.value("y")
            let dx = aim.x - originX
            let dy = aim.y - originY
            let length = max((dx * dx + dy * dy).squareRoot(), 1e-6)
            let dirX = dx / length, dirY = dy / length

            var nearest = Sim.shotRange
            for (_, bot) in state.bots.entries {
                if let t = Sim.rayCircle(
                    originX: originX, originY: originY, dirX: dirX, dirY: dirY,
                    centreX: predict.value(bot, "x"), centreY: predict.value(bot, "y"),
                    radius: Sim.botRadius, maxDistance: Sim.shotRange
                ) { nearest = min(nearest, t) }
            }

            let willHit = nearest < Sim.shotRange
            list.line(from: (x: originX, y: originY),
                      to: (x: originX + dirX * nearest, y: originY + dirY * nearest),
                      color: willHit ? Palette.good : Palette.accent,
                      alpha: 0.7, width: 0.14)
        }

        // Where the server says the bot WAS when you fired.
        for marker in markers {
            list.circleOutline(marker.x, marker.y, radius: Sim.botRadius + 0.6,
                               color: marker.hit ? Palette.good : Palette.bad, alpha: 0.9)
        }
    }

    public func unmount() {
        reconciler?.dispose()
        reconciler = nil
        predict = nil
        room = nil
        input = nil
        markers.removeAll()
    }

    public func onReconnect() {
        reconciler?.reset()
        input?.reset()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        let total = shots.value
        let landed = hits.value
        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("lag comp", (room.state?.lagComp ?? false) ? "on" : "off",
                         (room.state?.lagComp ?? false) ? .good : .warn),
            TelemetryRow("shots", "\(total)"),
            TelemetryRow("hits", "\(landed)", landed == total && total > 0 ? .good : .neutral),
            TelemetryRow("render delay", String(format: "%.0f ms", input?.renderDelay ?? 0)),
        ]
    }

    public var controls: [Control] {
        [
            Control(key: "space", label: "fire"),
            Control(key: "C", label: "lag comp", value: (room?.state?.lagComp ?? false) ? "on" : "off"),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
