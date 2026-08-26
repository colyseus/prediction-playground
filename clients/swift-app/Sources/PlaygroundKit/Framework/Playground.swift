import Colyseus
import Foundation

/// The shell: which lab is mounted, the frame loop, and the connection.
///
/// It owns the room lifecycle so labs never have to; a lab is mounted, driven,
/// and unmounted, and knows nothing about the one before it.
public final class Playground: @unchecked Sendable {
    /// Every lab, in the order the app steps through them.
    public static let labs: [any Lab.Type] = [
        Lab00Split.self,
        Lab01FeelTheLag.self,
        Lab02Clocks.self,
        Lab03Reconcile.self,
        Lab04InterpModes.self,
        Lab05DeadReckoning.self,
        Lab06LagComp.self,
        Lab07Wysiwyg.self,
        Lab08OptimisticEvents.self,
        Lab09PredictedSpawns.self,
        Lab10CompositeSim.self,
        Lab11DeterministicRng.self,
    ]

    public let keyboard = Keyboard()
    public private(set) var current: (any Lab)?
    public private(set) var index = 0
    public private(set) var status = "connecting…"

    private let endpoint: String
    private let isPrivate: Bool
    private var client: Colyseus.Client?
    private var mounting = false
    private var lastFrame: Double?

    /// Injected latency presets, in round-trip milliseconds. Localhost has
    /// none, so most of these labs show nothing at the first one.
    public static let latencyPresets: [(delay: Double, jitter: Double)] =
        [(0, 0), (80, 0), (200, 0), (200, 80), (400, 0)]
    public private(set) var latencyIndex = 0

    public init(endpoint: String, isPrivate: Bool = true) {
        self.endpoint = endpoint
        self.isPrivate = isPrivate
    }

    public var title: String {
        guard let current else { return "…" }
        return "\(type(of: current).id) — \(type(of: current).title)"
    }

    public var summary: String {
        current.map { type(of: $0).summary } ?? ""
    }

    /// Mount a lab by index, taking down whatever was there.
    public func select(_ index: Int) {
        let wrapped = (index % Self.labs.count + Self.labs.count) % Self.labs.count
        self.index = wrapped
        mount(Self.labs[wrapped])
    }

    public func next() { select(index + 1) }
    public func previous() { select(index - 1) }

    private func mount(_ type: any Lab.Type) {
        current?.unmount()
        current = nil
        keyboard.clearEdges()
        status = "joining \(type.id)…"
        mounting = true

        let lab = type.init()
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.client ?? Colyseus.Client(endpoint: endpoint)
                self.client = client
                let context = LabContext(
                    client: client, endpoint: endpoint,
                    keyboard: keyboard, isPrivate: isPrivate
                )
                try await lab.mount(context)

                // A lab switched away from while this was in flight must not
                // come back and take over.
                guard mounting, self.index == Self.labs.firstIndex(where: { $0 == type }) ?? self.index
                else {
                    lab.unmount()
                    return
                }

                current = lab
                mounting = false
                status = ""
                wireConnection(of: lab)
                // Every lab joins a fresh room, and the injection lives on the
                // room — without this the preset survives only until the next
                // lab switch, while the HUD keeps reporting it.
                if let preferred = type.preferredLatencyIndex { latencyIndex = preferred }
                applyLatency()
            } catch {
                mounting = false
                status = "could not join: \(error.localizedDescription)"
            }
        }
    }

    private func wireConnection(of lab: any Lab) {
        // Every room type is a different generic, so the shell reaches the
        // connection events through the one thing they share.
        guard let room = lab.roomHandle as? ConnectionEvents else { return }
        room.observeConnection(
            onDrop: { [weak self] reason in
                self?.status = reason.isEmpty ? "reconnecting…" : "reconnecting: \(reason)"
            },
            onReconnect: { [weak self] in
                self?.status = ""
                lab.onReconnect()
            },
            onLeave: { [weak self] reason in
                self?.status = reason.isEmpty ? "disconnected" : reason
            }
        )
    }

    /// One frame.
    ///
    /// The clock comes from the SDK rather than from the caller: prediction
    /// measures against a monotonic millisecond count, and handing it wall
    /// time quietly breaks every horizon it computes.
    public func frame() {
        Colyseus.pump()

        let now = Colyseus.now
        let dt = lastFrame.map { now - $0 } ?? 0
        lastFrame = now
        current?.frame(now: now, dt: dt)
    }

    public func draw() -> DrawList {
        var list = DrawList()
        current?.draw(&list)
        return list
    }

    public var telemetry: [TelemetryRow] { current?.telemetry ?? [] }
    public var controls: [Control] { current?.controls ?? [] }

    /// Cycle the injected latency.
    public func cycleLatency() {
        latencyIndex = (latencyIndex + 1) % Self.latencyPresets.count
        applyLatency()
    }

    public var latencyLabel: String {
        let preset = Self.latencyPresets[latencyIndex]
        if preset.delay == 0 { return "LAN" }
        return preset.jitter > 0
            ? "\(Int(preset.delay))ms ±\(Int(preset.jitter))"
            : "\(Int(preset.delay))ms"
    }

    private func applyLatency() {
        guard let room = current?.roomHandle as? ConnectionEvents else { return }
        let preset = Self.latencyPresets[latencyIndex]
        room.injectLatency(delayMs: preset.delay, jitterMs: preset.jitter)
    }

    /// Kill the connection uncleanly, to watch it come back.
    public func dropConnection() {
        (current?.roomHandle as? ConnectionEvents)?.drop()
    }

    public func shutdown() {
        current?.unmount()
        current = nil
        client = nil
    }
}

/// What the shell needs from a room, whatever its state type is.
public protocol ConnectionEvents: AnyObject {
    func observeConnection(
        onDrop: @escaping @Sendable (String) -> Void,
        onReconnect: @escaping @Sendable () -> Void,
        onLeave: @escaping @Sendable (String) -> Void
    )
    func injectLatency(delayMs: Double, jitterMs: Double)
    func drop()
}

extension Colyseus.Room: ConnectionEvents {
    public func observeConnection(
        onDrop: @escaping @Sendable (String) -> Void,
        onReconnect: @escaping @Sendable () -> Void,
        onLeave: @escaping @Sendable (String) -> Void
    ) {
        self.onDrop { _, reason in onDrop(reason) }
        self.onReconnect { onReconnect() }
        self.onLeave { _, reason in onLeave(reason) }
    }

    public func injectLatency(delayMs: Double, jitterMs: Double) {
        setLatency(delayMs: delayMs, jitterMs: jitterMs)
    }

    public func drop() {
        dropConnection()
    }
}
