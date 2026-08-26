import Foundation

/// Paces fixed steps for the labs that have no reconciler.
///
/// `predict.tick` only starts returning steps once a reconciler advertises the
/// server's step, so a lab that only sends inputs — lab 01, lab 02 — needs its
/// own accumulator.
public struct FixedStepPacer: Sendable {
    private let stepMs: Double
    private var accumulator = 0.0
    private var last: Double?

    /// A hitch drops the backlog rather than firing a burst that would look
    /// like a speed-up.
    private let maxStepsPerFrame = 5

    public init(hz: Double = Sim.tickHz) {
        stepMs = 1000 / hz
    }

    /// How many steps are due at `now`, in milliseconds.
    public mutating func steps(at now: Double) -> Int {
        defer { last = now }
        guard let last else { return 1 }

        accumulator += now - last
        var due = 0
        while accumulator >= stepMs, due < maxStepsPerFrame {
            accumulator -= stepMs
            due += 1
        }
        if due == maxStepsPerFrame { accumulator = 0 }
        return due
    }
}
