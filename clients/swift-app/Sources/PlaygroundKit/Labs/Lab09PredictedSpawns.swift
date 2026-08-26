import Colyseus
import Foundation

/// Lab 09 — Predicted Spawns.
///
/// Click-to-fire feels instant because the client spawns an optimistic
/// projectile the same frame. When the server's authoritative one arrives, the
/// store correlates the two into one entry — same id, same sprite, no seam.
///
/// The lead readout is measured per shot rather than assumed, which is what
/// keeps your projectile flying your timeline through the handoff instead of
/// snapping back by lead × velocity.
public final class Lab09PredictedSpawns: Lab, @unchecked Sendable {
    public static let id = "09"
    public static let title = "Predicted Spawns"
    public static let summary = "Fire immediately, then hand off to the server's projectile."

    private var room: Colyseus.Room<LabProjectile.ProjectileState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var reconciler: Colyseus.Reconciler?
    /// Internal rather than private so the acceptance tests can follow one
    /// entry across the handoff by its id.
    private(set) var spawns: Colyseus.Spawns?
    private var keyboard: Keyboard?

    private var optimistic = true
    private var fire = FireLatch()
    /// The entries we spawned, newest last. The turret's projectiles arrive as
    /// server-only entries with no lead to report, so the readout has to know
    /// which ones were ours.
    private var mine: [Int] = []
    private var aim = (x: Sim.arenaWidth - 10, y: Sim.arenaHeight / 2)
    private let fired = Tally()

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-projectile", LabProjectile.ProjectileState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-projectile gave no predict or input channel")
        }

        self.room = room
        self.predict = predict
        self.input = input
        keyboard = context.keyboard

        guard let state = room.state else { return }
        predict.attachAll(state.players, fields: ["x", "y"],
                          options: .init(mode: .damped), except: room.sessionId)

        let sessionId = room.sessionId
        spawns = predict.spawns(
            state.projectiles,
            // Which arriving projectiles are ours to correlate. The turret's
            // surface as server-only entries.
            owned: { $0.string("owner") == sessionId },
            // Supplying this turns on the measured input lead.
            spawnTime: { $0["bornMs"] },
            // The same flight the server integrates, so a CONFIRMED
            // projectile keeps moving between snapshots instead of reading
            // the last one the server sent — which is a round trip behind
            // where the prediction had already flown it, and shows up as the
            // trajectory changing the moment the server acknowledges the shot.
            //
            // No smoothing: a constant-velocity projectile rebases exactly, so
            // easing the rebase in would only add lag.
            reckon: .init(fields: ["x", "y"]) { projectile, dt, _ in
                var body = Sim.Entity(view: projectile)
                Sim.stepProjectile(&body, dt: dt)
                body.write(to: projectile)
            }
        )
    }

    public func frame(now: Double, dt: Double) {
        guard let room, let predict, let input, let keyboard else { return }

        spawnReconcilerIfNeeded()

        fire.arm(keyboard.takeEdge("space"))
        if keyboard.takeEdge("o") { optimistic.toggle() }

        for _ in 0 ..< predict.tick(now) {
            // Taken inside the step loop: most frames have no step due, and
            // reading the key edge out here would drop the shot on those.
            let wantsFire = fire.take()

            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.data.set("aimX", to: aim.x)
            input.data.set("aimY", to: aim.y)
            input.data.set("fire", to: wantsFire)
            input.send()

            if wantsFire {
                if optimistic { spawnLocal() }
                fired.increment()
            }
        }
    }

    /// Where the pointer is aiming, in world units.
    public func setAim(x: Double, y: Double) {
        aim = (x: x, y: y)
    }

    private func spawnLocal() {
        // The RAW predicted pose, not the rendered one: the server fires from
        // the position its own stepEntity just produced, and value() adds the
        // decaying correction and the interpolation between steps. Firing from
        // the smoothed pose aims the shot slightly differently from the one
        // the server will create.
        guard let spawns, let state = reconciler?.state else { return }

        let originX = state["x"]
        let originY = state["y"]
        let dx = aim.x - originX
        let dy = aim.y - originY
        let length = max((dx * dx + dy * dy).squareRoot(), 1e-6)

        let id = spawns.spawn(LocalProjectile(
            x: originX, y: originY,
            vx: dx / length * Sim.projectileSpeed,
            vy: dy / length * Sim.projectileSpeed
        ))
        mine.append(id)
        if mine.count > 32 { mine.removeFirst(mine.count - 32) }
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

        for (sessionId, player) in state.players.entries {
            let isMe = sessionId == room.sessionId
            list.square(predict.value(player, "x"), predict.value(player, "y"),
                        half: Sim.playerHalf,
                        color: WorldView.color(hue: player.hue), alpha: isMe ? 1 : 0.5)
        }

        // One render path across the handoff: pending entries read their
        // prediction, confirmed ones read the server's instance.
        if let spawns {
            for entry in spawns.entries {
                let x = spawns.value(entry, "x")
                let y = spawns.value(entry, "y")
                guard !x.isNaN, !y.isNaN else { continue }
                list.circle(x, y, radius: Sim.projectileRadius,
                            color: entry.isConfirmed ? Palette.good : Palette.warn,
                            alpha: entry.isConfirmed ? 1 : 0.8)
            }
        }

        // The aim line starts at the sprite, which is the rendered pose —
        // shots leave from the raw predicted one, a fraction of a unit away.
        if let reconciler {
            list.line(from: (x: reconciler.value("x"), y: reconciler.value("y")), to: aim,
                      color: Palette.accent, alpha: 0.35, width: 0.12)
        }
    }

    public func unmount() {
        mine.removeAll()
        spawns?.dispose()
        reconciler?.dispose()
        spawns = nil
        reconciler = nil
        predict = nil
        room = nil
        input = nil
    }

    public func onReconnect() {
        reconciler?.reset()
        input?.reset()
        spawns?.clear()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        let entries = spawns?.entries ?? []
        let pending = entries.filter { !$0.isConfirmed }.count
        // The lead measured on the most recent confirmed shot of OUR own —
        // a turret projectile is a server-only entry and has none.
        let lead = mine.reversed()
            .compactMap { id in entries.first { $0.id == id && $0.isConfirmed } }
            .first?.leadMs ?? 0

        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("fired", "\(fired.value)"),
            TelemetryRow("in flight", "\(entries.count)"),
            TelemetryRow("pending", "\(pending)", pending > 0 ? .warn : .good),
            TelemetryRow("lead", String(format: "%.0f ms", lead)),
            TelemetryRow("optimistic", optimistic ? "on" : "off", optimistic ? .good : .warn),
        ]
    }

    public var controls: [Control] {
        [
            Control(key: "space", label: "fire"),
            Control(key: "O", label: "optimistic", value: optimistic ? "on" : "off"),
        ]
    }

    public var roomHandle: AnyObject? { room }
}

/// The optimistic projectile, before the server has one.
final class LocalProjectile: Colyseus.SpawnLocal, @unchecked Sendable {
    private var body: Sim.Entity

    init(x: Double, y: Double, vx: Double, vy: Double) {
        body = Sim.Entity(x: x, y: y, vx: vx, vy: vy)
        super.init()
    }

    /// The same flight the server integrates.
    override func step(dt: Double) {
        Sim.stepProjectile(&body, dt: dt)
    }

    override func value(_ field: String) -> Double {
        switch field {
        case "x": return body.x
        case "y": return body.y
        case "vx": return body.vx
        case "vy": return body.vy
        default: return .nan
        }
    }
}
