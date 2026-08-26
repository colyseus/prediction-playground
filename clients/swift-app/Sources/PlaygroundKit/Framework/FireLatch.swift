import Foundation

/// Holds "the player wants to fire" until a fixed step actually consumes it.
///
/// A press has to survive the frames in between: `predict.tick` returns 0 on
/// most of them at 20 Hz against a 60 Hz loop, and reading the key edge
/// directly throws the shot away on four frames out of five.
public struct FireLatch: Sendable {
    private var armed = false

    public init() {}

    /// Called once a frame with the key edge.
    public mutating func arm(_ pressed: Bool) {
        if pressed { armed = true }
    }

    /// Called once per fixed step. True at most once per press.
    public mutating func take() -> Bool {
        defer { armed = false }
        return armed
    }

    public var isArmed: Bool { armed }
}
