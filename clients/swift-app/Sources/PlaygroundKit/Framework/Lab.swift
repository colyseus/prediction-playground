import Colyseus
import Foundation

/// A row on the telemetry panel.
public struct TelemetryRow: Sendable {
    public enum Verdict: Sendable { case neutral, good, warn, bad }

    public var label: String
    public var value: String
    public var verdict: Verdict

    public init(_ label: String, _ value: String, _ verdict: Verdict = .neutral) {
        self.label = label
        self.value = value
        self.verdict = verdict
    }
}

/// A knob a lab exposes, and the key that turns it.
public struct Control: Sendable {
    public var key: String
    public var label: String
    public var value: String

    public init(key: String, label: String, value: String = "") {
        self.key = key
        self.label = label
        self.value = value
    }
}

/// What every lab is handed when it mounts.
public struct LabContext: Sendable {
    public let client: Colyseus.Client
    public let endpoint: String
    public let keyboard: Keyboard
    /// Open a room of this lab's own, so two runs of the app do not land in
    /// each other's arena.
    public let isPrivate: Bool

    public init(client: Colyseus.Client, endpoint: String, keyboard: Keyboard, isPrivate: Bool) {
        self.client = client
        self.endpoint = endpoint
        self.keyboard = keyboard
        self.isPrivate = isPrivate
    }
}

/// One lab.
///
/// The shape mirrors the web client's contract: mount, a frame each vsync,
/// unmount, and a hook for when the connection comes back. Labs never leave
/// their room themselves — the shell owns that.
///
/// Nothing here draws. A lab fills a ``DrawList`` in world coordinates and the
/// shell renders it, which is what lets the tests mount all twelve and drive
/// real frames with no window.
public protocol Lab: AnyObject, Sendable {
    /// "00" through "11".
    static var id: String { get }
    static var title: String { get }
    /// One line on what the lab is showing.
    static var summary: String { get }

    init()

    func mount(_ context: LabContext) async throws
    /// Advance one frame. `now` is the room clock's local milliseconds.
    func frame(now: Double, dt: Double)
    func draw(_ list: inout DrawList)
    func unmount()

    /// The reconnected session numbers its inputs from zero, so anything
    /// holding predicted state has to let go of it here.
    func onReconnect()

    var telemetry: [TelemetryRow] { get }
    var controls: [Control] { get }
    /// The room, for the shell's connection banner and for tests.
    var roomHandle: AnyObject? { get }
}

public extension Lab {
    func onReconnect() {}
    var controls: [Control] { [] }
}

/// Join a lab's room.
///
/// Private by default: the labs run against a shared dev server, and a
/// `joinOrCreate` would seat two runs of the app — or a stray browser tab — in
/// the same arena, which changes what every reading means.
public func joinLab<State: SchemaRef>(
    _ context: LabContext,
    _ roomName: String,
    _ state: State.Type = State.self
) async throws -> Colyseus.Room<State> {
    let options: MessagePackValue = context.isPrivate ? ["private": true] : [:]
    let room = context.isPrivate
        ? try await context.client.create(roomName, options: options, state: state)
        : try await context.client.joinOrCreate(roomName, options: options, state: state)
    return room
}
