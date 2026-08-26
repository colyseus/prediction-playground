import Colyseus
import Foundation

/// Lab 07 — WYSIWYG.
///
/// Evaluate a collision at the instant the input was stamped, and freeze the
/// verdict so replays cannot change their mind.
///
/// Two toggles, and both off is the maximally wrong version. `valueAt` reads a
/// reckoned bot where it was when you pressed the key, rather than where it is
/// now; the memo freezes the outcome on the live step so a rollback replays a
/// decision instead of re-making it against a world that has moved on.
public final class Lab07Wysiwyg: Lab, @unchecked Sendable {
    public static let id = "07"
    public static let title = "WYSIWYG"
    public static let summary = "Judge a collision at the instant the input was stamped, and freeze it."

    private var room: Colyseus.Room<LabBump.BumpState>?
    private var predict: Colyseus.Predict?
    private var input: Colyseus.InputHandle?
    private var reconciler: Colyseus.Reconciler?
    private var keyboard: Keyboard?

    private var useValueAt = true
    private var useMemo = true
    private let bumps = Tally()
    private var lastVerdict: (x: Double, y: Double, until: Double)?

    public init() {}

    public func mount(_ context: LabContext) async throws {
        let room = try await joinLab(context, "lab-bump", LabBump.BumpState.self)
        guard let predict = Colyseus.Predict.get(room), let input = room.input() else {
            throw Colyseus.Error.unavailable("lab-bump gave no predict or input channel")
        }

        self.room = room
        self.predict = predict
        self.input = input
        keyboard = context.keyboard

        guard let state = room.state else { return }
        // The bots are DEAD-RECKONED, which is what makes `valueAt` meaningful:
        // a reckoned field can be evaluated at an arbitrary instant, and an
        // interpolated one cannot.
        predict.attachAllReckon(state.bots, fields: ["x", "y"], smoothMs: 60) { bot, dt, elapsedMs in
            var simulated = Sim.Bot(view: bot)
            Sim.stepBot(&simulated, dt: dt, elapsedMs: elapsedMs)
            simulated.write(to: bot)
        }
        predict.attachAll(state.players, fields: ["x", "y"],
                          options: .init(mode: .damped), except: room.sessionId)
    }

    public func frame(now: Double, dt: Double) {
        guard let predict, let input, let keyboard else { return }

        spawnReconcilerIfNeeded()

        for _ in 0 ..< predict.tick(now) {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }

        if keyboard.takeEdge("v") { useValueAt.toggle(); respawn() }
        if keyboard.takeEdge("m") { useMemo.toggle(); respawn() }

        if let last = lastVerdict, last.until < now { lastVerdict = nil }
    }

    private func respawn() {
        reconciler?.dispose()
        reconciler = nil
    }

    private func spawnReconcilerIfNeeded() {
        guard reconciler == nil,
              let room, let predict, let input,
              let state = room.state,
              let sessionId = room.sessionId,
              let me = state.players[sessionId]
        else { return }

        let useValueAt = self.useValueAt
        let useMemo = self.useMemo

        reconciler = predict.reconciler(
            truth: me, input: input,
            // bumpTicks is reconciled: the immunity window has to survive a
            // rollback, or a replay bumps you twice for one contact.
            fields: ["x", "y", "vx", "vy", "bumpTicks"], smoothMs: 65
        ) { [weak self] context, stateView, command in
            var ticks = Int(stateView["bumpTicks"])
            Sim.stepBumpGate(&ticks)

            var entity = Sim.Entity(view: stateView)
            Sim.stepEntity(&entity, moveX: command["moveX"], moveY: command["moveY"], dt: context.dt)

            // The verdict for THIS input: where were the bots when it was
            // stamped, and did any of them catch us?
            let verdict: [Double] = {
                let compute: () -> [Double] = {
                    for (_, bot) in state.bots.entries {
                        // valueAt reads the reckoned bot at the input's own
                        // instant; value() reads it as of now, which on a
                        // replay is a different world.
                        let botX = useValueAt
                            ? predict.value(bot, "x", at: context.reckonTime)
                            : predict.value(bot, "x")
                        let botY = useValueAt
                            ? predict.value(bot, "y", at: context.reckonTime)
                            : predict.value(bot, "y")

                        if let knock = Sim.collideBot(
                            playerX: entity.x, playerY: entity.y, bumpTicks: ticks,
                            botX: botX, botY: botY
                        ) {
                            return [1, knock.vx, knock.vy, botX]
                        }
                    }
                    return []
                }

                // One derivation for the whole tuple. Splitting it across
                // scalar memos would re-run the collision search per
                // component.
                return useMemo ? context.memo("bump", compute) : compute()
            }()

            if verdict.count == 4 {
                entity.vx = verdict[1]
                entity.vy = verdict[2]
                ticks = Sim.bumpCooldownTicks
                if !context.isReplay {
                    self?.bumps.increment()
                    self?.lastVerdict = (x: entity.x, y: entity.y, until: context.reckonTime + 1200)
                }
            }

            entity.write(to: stateView)
            stateView.set("bumpTicks", to: Double(ticks))
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
            let immune = player.bumpTicks > 0
            list.square(predict.value(player, "x"), predict.value(player, "y"),
                        half: Sim.playerHalf,
                        color: immune ? Palette.dim : WorldView.color(hue: player.hue),
                        alpha: isMe ? 1 : 0.5)
        }

        // Where a bump was judged to have happened — frozen, so a replay does
        // not move it.
        if let verdict = lastVerdict {
            list.circleOutline(verdict.x, verdict.y, radius: Sim.playerHalf + 1.4,
                               color: Palette.bad, alpha: 0.9)
        }
    }

    public func unmount() {
        reconciler?.dispose()
        reconciler = nil
        predict = nil
        room = nil
        input = nil
    }

    public func onReconnect() {
        reconciler?.reset()
        input?.reset()
    }

    public var telemetry: [TelemetryRow] {
        guard let room else { return [] }
        let honest = useValueAt && useMemo
        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("valueAt", useValueAt ? "on" : "off", useValueAt ? .good : .bad),
            TelemetryRow("memo", useMemo ? "on" : "off", useMemo ? .good : .bad),
            TelemetryRow("bumps", "\(bumps.value)"),
            TelemetryRow("verdicts", honest ? "frozen" : "re-derived", honest ? .good : .warn),
        ]
    }

    public var controls: [Control] {
        [
            Control(key: "V", label: "valueAt", value: useValueAt ? "on" : "off"),
            Control(key: "M", label: "memo", value: useMemo ? "on" : "off"),
        ]
    }

    public var roomHandle: AnyObject? { room }
}
