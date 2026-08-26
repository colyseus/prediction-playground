import Colyseus
import Foundation

/// The reconciler over `lab-move`, which labs 00, 03, 08 and 09 all build on.
///
/// Predict locally the moment an input is made; when the server confirms one,
/// rewind to what it said and replay everything still in flight. When the step
/// matches the server's, the correction is nothing and the square never
/// visibly moves.
public final class MoveLane: @unchecked Sendable {
    public let room: Colyseus.Room<LabMove.MoveState>
    public let predict: Colyseus.Predict
    public let input: Colyseus.InputHandle
    public private(set) var reconciler: Colyseus.Reconciler?

    private let keyboard: Keyboard
    private var smoothMs: Double
    /// A correction bigger than this pops instead of gliding — a teleport is
    /// not a prediction failure.
    private var snap = Sim.teleportSnapDistance

    /// Runs after the shared movement step, on every live step and replay.
    /// Labs 08 and 09 hang their own prediction off this.
    public var extraStep: (@Sendable (Colyseus.StepContext, SchemaView) -> Void)?

    public var me: LabMove.Player? {
        room.sessionId.flatMap { room.state?.players[$0] }
    }

    public init(
        room: Colyseus.Room<LabMove.MoveState>,
        predict: Colyseus.Predict,
        input: Colyseus.InputHandle,
        keyboard: Keyboard,
        smoothMs: Double = 65
    ) {
        self.room = room
        self.predict = predict
        self.input = input
        self.keyboard = keyboard
        self.smoothMs = smoothMs
    }

    /// Smooth everyone else, and start predicting ourselves once the server
    /// has given us a player.
    public func start(remoteMode: Colyseus.PredictMode = .damped) {
        guard let state = room.state else { return }
        predict.attachAll(
            state.players,
            fields: ["x", "y"],
            options: .init(mode: remoteMode, delay: Sim.remoteInterpMs),
            except: room.sessionId
        )
    }

    /// Build the reconciler. Call once the local player has decoded.
    @discardableResult
    public func spawn(fields: [String] = ["x", "y", "vx", "vy"]) -> Bool {
        guard reconciler == nil, let me else { return false }

        reconciler = predict.reconciler(
            truth: me, input: input, fields: fields, smoothMs: smoothMs, snap: snap
        ) { [weak self] context, state, command in
            var entity = Sim.Entity(view: state)
            Sim.stepEntity(&entity, moveX: command["moveX"], moveY: command["moveY"], dt: context.dt)
            entity.write(to: state)
            self?.extraStep?(context, state)
        }
        return reconciler != nil
    }

    /// Tick and send. The first thing a lab's frame does.
    @discardableResult
    public func drive(now: Double) -> Int {
        if reconciler == nil { spawn() }

        let steps = predict.tick(now)
        for _ in 0 ..< steps {
            input.data.set("moveX", to: keyboard.moveX)
            input.data.set("moveY", to: keyboard.moveY)
            input.send()
        }
        return steps
    }

    /// Where to draw the local player: the reconciled pose, correction and all.
    public var predictedPosition: (x: Double, y: Double) {
        guard let me else { return (x: 0, y: 0) }
        return (x: predict.value(me, "x"), y: predict.value(me, "y"))
    }

    /// What the server last said, for the ghost.
    public var serverPosition: (x: Double, y: Double) {
        guard let me else { return (x: 0, y: 0) }
        return (x: me.x, y: me.y)
    }

    public func setSmoothing(_ ms: Double) {
        smoothMs = ms
        respawn()
    }

    /// Rebuild the reconciler — for a smoothing change, which the C port
    /// learned has to dispose the old one first or two controllers contend for
    /// the same input handle.
    public func respawn() {
        reconciler?.dispose()
        reconciler = nil
        spawn()
    }

    public func reset() {
        reconciler?.reset()
        input.reset()
    }

    public func dispose() {
        reconciler?.dispose()
        reconciler = nil
    }

    public var telemetry: [TelemetryRow] {
        guard let reconciler else {
            return [TelemetryRow("prediction", "starting…", .warn)]
        }

        let drift = reconciler.drift
        let verdict: TelemetryRow.Verdict
        switch drift.status {
        case .matched: verdict = .good
        case .jitter: verdict = .warn
        case .diverging: verdict = .bad
        }

        return [
            TelemetryRow("rtt", String(format: "%.0f ms", room.clock.smoothedRtt)),
            TelemetryRow("pending", "\(reconciler.pendingCount)"),
            TelemetryRow("acked", "\(reconciler.reconcileSeq)"),
            TelemetryRow("correction", String(format: "%.4f", reconciler.lastCorrectionMagnitude)),
            TelemetryRow("drift", describe(drift.status), verdict),
        ]
    }

    private func describe(_ status: Colyseus.Drift.Status) -> String {
        switch status {
        case .matched: return "matched"
        case .jitter: return "jitter"
        case .diverging: return "diverging"
        }
    }
}

public extension Sim.Entity {
    /// Read an entity out of a schema mirror.
    init(view: SchemaView) {
        self.init(x: view["x"], y: view["y"], vx: view["vx"], vy: view["vy"])
    }

    /// Write it back. Fields the schema does not declare are skipped.
    func write(to view: SchemaView) {
        view.set("x", to: x)
        view.set("y", to: y)
        if view.has("vx") { view.set("vx", to: vx) }
        if view.has("vy") { view.set("vy", to: vy) }
    }
}
