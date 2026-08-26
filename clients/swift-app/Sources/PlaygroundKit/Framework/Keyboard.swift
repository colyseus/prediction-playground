import Foundation

/// Held keys, as the labs want to read them.
///
/// Tri-state axes, and latched edges for the one-shot keys — a lab reads an
/// edge once and it is gone, so a key held down does not fire every frame.
public final class Keyboard: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var edges: Set<String> = []

    public init() {}

    public func press(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if !held.contains(key) { edges.insert(key) }
        held.insert(key)
    }

    public func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        held.remove(key)
    }

    public func isHeld(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains(key)
    }

    /// True once per press.
    public func takeEdge(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return edges.remove(key) != nil
    }

    public func clearEdges() {
        lock.lock()
        defer { lock.unlock() }
        edges.removeAll()
    }

    /// WASD or the arrows, as −1, 0 or 1.
    public var moveX: Double {
        (isHeld("d") || isHeld("right") ? 1 : 0) - (isHeld("a") || isHeld("left") ? 1 : 0)
    }

    public var moveY: Double {
        (isHeld("w") || isHeld("up") ? 1 : 0) - (isHeld("s") || isHeld("down") ? 1 : 0)
    }
}
