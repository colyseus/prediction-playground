import Colyseus
import Foundation
import XCTest
@testable import PlaygroundKit

/// What each lab claims, checked against the real server.
///
/// The smoke test proves every lab runs; this proves the ones that make a
/// measurable claim are telling the truth.
final class AcceptanceTests: XCTestCase {
    private var playground: Playground!

    override func setUpWithError() throws {
        try Server.require()
        Colyseus.autoPump = false
        playground = Playground(endpoint: Server.endpoint)
    }

    override func tearDown() {
        playground?.shutdown()
        playground = nil
        Colyseus.autoPump = true
    }

    /// Mount one lab and wait for it to join.
    private func mount<T: Lab>(_ type: T.Type) throws -> T {
        let index = try XCTUnwrap(
            Playground.labs.firstIndex { $0.id == type.id },
            "no lab \(type.id) in the registry"
        )
        playground.select(index)
        drive(playground, "lab \(type.id) to join", timeout: 12) { playground.current != nil }
        return try XCTUnwrap(playground.current as? T, "lab \(type.id) mounted as the wrong type")
    }

    /// Hold a direction for a while, driving frames.
    private func hold(_ keys: [String], seconds: TimeInterval) {
        keys.forEach { playground.keyboard.press($0) }
        drive(playground, seconds: seconds)
        keys.forEach { playground.keyboard.release($0) }
    }

    private func telemetry(_ label: String) -> String? {
        playground.telemetry.first { $0.label == label }?.value
    }

    /// Drive frames, reading a numeric telemetry row on EVERY one.
    ///
    /// Sampling on a timer instead aliases against the server's 20 Hz
    /// reconcile: the correction is written when an ack lands and decays from
    /// there, so a 50 ms sampler can step over the whole event.
    private func peak(of label: String, seconds: TimeInterval) -> Double {
        var highest = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            playground.frame()
            _ = playground.draw()
            highest = max(highest, telemetry(label).flatMap(Double.init) ?? 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        return highest
    }

    // MARK: - 02

    func testClocksSyncToTheServer() throws {
        _ = try mount(Lab02Clocks.self)
        drive(playground, seconds: 1.5)

        let serverNow = try XCTUnwrap(telemetry("serverNow").flatMap(Double.init))
        let now = try XCTUnwrap(telemetry("now").flatMap(Double.init))
        XCTAssertNotEqual(serverNow, now, "no server time — is the room stamping patches?")
        XCTAssertNotNil(telemetry("jitter"))
        XCTAssertGreaterThan(try XCTUnwrap(telemetry("patch").flatMap { Double($0.dropLast(3)) }), 0)
    }

    // MARK: - Movement

    /// W has to move you UP the screen.
    ///
    /// The arena's y grows downward and only the renderer flips it, so a
    /// keyboard that reports +1 for W sends you the other way — which is what
    /// it did.
    func testMovingUpDecreasesY() throws {
        let lab = try mount(Lab03Reconcile.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("drift") != nil }

        let lane = try XCTUnwrap(lab.lane)
        let start = lane.predictedPosition.y

        hold(["w"], seconds: 1.2)
        XCTAssertLessThan(lane.predictedPosition.y, start - 2,
                          "W moved from y \(start) to \(lane.predictedPosition.y)")

        let afterUp = lane.predictedPosition.y
        hold(["s"], seconds: 1.2)
        XCTAssertGreaterThan(lane.predictedPosition.y, afterUp + 2,
                             "S moved from y \(afterUp) to \(lane.predictedPosition.y)")
    }

    // MARK: - 03

    func testReconcileLeadsTheServerAndCorrectsToNothing() throws {
        let lab = try mount(Lab03Reconcile.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("drift") != nil }

        // A box with coasts between the legs: holding one direction pins the
        // square against a wall, where there is no velocity for friction to
        // act on and the reading means nothing.
        for keys in [["d"], [], ["s"], [], ["a"], [], ["w"], []] {
            hold(keys, seconds: 0.4)
        }

        XCTAssertGreaterThan(try XCTUnwrap(telemetry("acked").flatMap(Int.init)), 0)
        XCTAssertEqual(telemetry("drift"), "matched",
                       "correction \(telemetry("correction") ?? "?")")

        // The impulse is a kick the client could not have predicted.
        //
        // Sampling has to start with the key, not after it: on loopback the
        // server applies the shove and the client reconciles it inside a
        // hundred milliseconds, and the next reconcile overwrites the reading.
        playground.keyboard.press("i")
        let corrected = peak(of: "correction", seconds: 3.0)
        playground.keyboard.release("i")
        XCTAssertGreaterThan(corrected, 1e-3, "the impulse produced no correction at all")

        // ...and it eases out rather than staying.
        let after = peak(of: "correction", seconds: 2.0)
        XCTAssertLessThan(after, corrected)
        _ = lab
    }

    // MARK: - 00

    func testSplitLanesSeparateUnderLatency() throws {
        _ = try mount(Lab00Split.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("drift") != nil }

        // 400 ms of round trip, so the prediction runs visibly ahead of the
        // position the server has confirmed.
        playground.cycleLatency()
        playground.cycleLatency()
        playground.cycleLatency()
        playground.cycleLatency()

        // Measured WHILE moving: the moment you stop, the server catches up
        // and the two lanes converge, so an after-the-fact reading is zero.
        playground.keyboard.press("d")
        var highest = 0.0
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            playground.frame()
            _ = playground.draw()
            highest = max(highest, telemetry("lead").flatMap { Double($0.dropLast(2)) } ?? 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        playground.keyboard.release("d")

        XCTAssertGreaterThan(highest, 1.0, "the two lanes never separated")
    }

    // MARK: - 05

    func testDeadReckoningTracksAComputableBotAndBreaksOnWander() throws {
        let lab = try mount(Lab05DeadReckoning.self)
        drive(playground, seconds: 1.5)

        // The teleporter's schedule is synced, so reckoning follows it.
        XCTAssertEqual(telemetry("predictable"), "yes")

        // Wander re-rolls its heading from a seed only the server has.
        playground.keyboard.press("p")
        drive(playground, seconds: 0.1)
        playground.keyboard.release("p")
        drive(playground, seconds: 0.3)

        // Step to `wander` — the order is patrol, circle, wander, teleport.
        while telemetry("pattern") != "wander" {
            playground.keyboard.press("p")
            drive(playground, seconds: 0.1)
            playground.keyboard.release("p")
            drive(playground, seconds: 0.3)
        }
        XCTAssertEqual(telemetry("predictable"), "no — server seed")
        _ = lab
    }

    // MARK: - 08

    func testAPredictedGoalIsConfirmed() throws {
        _ = try mount(Lab08OptimisticEvents.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("pending") != nil }

        // The goal strip is on the right edge, at mid height.
        hold(["d"], seconds: 4.0)

        let predicted = try XCTUnwrap(telemetry("predicted").flatMap(Int.init))
        XCTAssertGreaterThan(predicted, 0, "never reached the goal zone")

        drive(playground, "the server to confirm", timeout: 6) {
            (telemetry("confirmed").flatMap(Int.init) ?? 0) > 0
        }
        XCTAssertEqual(telemetry("rejected"), "0", "a goal was retracted with deny rate at zero")
    }

    // MARK: - 09

    func testAPredictedSpawnIsHandedOff() throws {
        let lab = try mount(Lab09PredictedSpawns.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("fired") != nil }

        lab.setAim(x: Sim.arenaWidth - 6, y: Sim.arenaHeight / 2)
        playground.keyboard.press("space")
        drive(playground, seconds: 0.15)
        playground.keyboard.release("space")

        XCTAssertGreaterThan(try XCTUnwrap(telemetry("fired").flatMap(Int.init)), 0)

        // The server's projectile takes over the same entry, and the lead is
        // measured rather than assumed.
        drive(playground, "the handoff", timeout: 6) {
            (telemetry("lead").flatMap { Double($0.dropLast(3)) } ?? 0) > 0
        }
        XCTAssertEqual(telemetry("pending"), "0", "a prediction was never correlated")

        // And the projectile does not change course when the server
        // acknowledges it.
        //
        // A confirmed entry that is not reckoned reads the last position the
        // server sent — behind where the prediction had already flown it — so
        // the projectile snaps BACKWARDS along its own path and appears to
        // re-aim. That reversal is the visible bug; measured at −1.7 units
        // without the reckon step. With it the seam is a small step forward,
        // which is timing, not a change of course.
        playground.keyboard.press("space")
        let seam = handoffSeam(of: lab, seconds: 2.5)
        playground.keyboard.release("space")

        let jump = try XCTUnwrap(seam, "no entry crossed from pending to confirmed while sampling")
        XCTAssertGreaterThan(
            jump.alongVelocity, -0.1,
            "the projectile snapped backwards by \(-jump.alongVelocity) units when confirmed"
        )
        XCTAssertLessThan(jump.distance, 3.0, "the projectile jumped \(jump.distance) units when confirmed")
    }

    /// How a spawn's drawn position moves across the one frame where it stops
    /// being a prediction and becomes the server's, and how much of that is
    /// along its own direction of travel.
    ///
    /// The entry id is stable across the handoff by design, which is what
    /// makes a single projectile followable through it.
    private func handoffSeam(
        of lab: Lab09PredictedSpawns,
        seconds: TimeInterval
    ) -> (distance: Double, alongVelocity: Double)? {
        var previous: [Int: (x: Double, y: Double, confirmed: Bool)] = [:]
        var worst: (distance: Double, alongVelocity: Double)?

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            playground.frame()

            for entry in lab.spawns?.entries ?? [] {
                let x = lab.spawns?.value(entry, "x") ?? .nan
                let y = lab.spawns?.value(entry, "y") ?? .nan
                guard !x.isNaN, !y.isNaN else { continue }
                defer { previous[entry.id] = (x: x, y: y, confirmed: entry.isConfirmed) }

                // Only the crossing frame, not every frame.
                guard let last = previous[entry.id], !last.confirmed, entry.isConfirmed,
                      let server = entry.server
                else { continue }

                let dx = x - last.x, dy = y - last.y
                let speed = (server["vx"] * server["vx"] + server["vy"] * server["vy"]).squareRoot()
                guard speed > 1e-9 else { continue }

                let along = (dx * server["vx"] + dy * server["vy"]) / speed
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance > (worst?.distance ?? -1) {
                    worst = (distance: distance, alongVelocity: along)
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        return worst
    }

    // MARK: - 10

    func testTheCompositeSimStaysWithinTheMeasuredTolerance() throws {
        _ = try mount(Lab10CompositeSim.self)
        drive(playground, "the sim to start", timeout: 10) { telemetry("drift ema") != nil }

        // Chase the puck around for a while: contacts are what a composite
        // reconciler exists for, and what would mispredict if it were wrong.
        for keys in [["w"], ["d"], ["s"], ["a"], ["w", "d"], ["s", "a"]] {
            hold(keys, seconds: 1.0)
        }

        let drift = try XCTUnwrap(telemetry("drift ema").flatMap(Double.init))
        // 0.5 is the playground's measured line between an honest contested
        // touch and a real determinism bug — freezing the bot instead of
        // predicting it measured 2.06.
        XCTAssertLessThan(drift, 0.5, "drift ema \(drift)")
    }

    // MARK: - 11

    func testTheShotgunFanMatchesTheServersRoll() throws {
        let lab = try mount(Lab11DeterministicRng.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("salt") != nil }

        lab.setAim(x: Sim.arenaWidth - 6, y: Sim.arenaHeight / 2)
        for _ in 0 ..< 3 {
            playground.keyboard.press("space")
            drive(playground, seconds: 0.15)
            playground.keyboard.release("space")
            drive(playground, seconds: 0.8)
        }

        XCTAssertEqual(telemetry("source"), "shared seed")
        let mismatch = try XCTUnwrap(telemetry("mismatch").flatMap { Double($0.dropLast(4)) })
        XCTAssertLessThan(mismatch, 1e-12,
                          "the client's fan and the server's disagree by \(mismatch) rad")
    }

    // MARK: - Reconnect

    func testADroppedConnectionComesBackAndPredictionSurvives() throws {
        _ = try mount(Lab03Reconcile.self)
        drive(playground, "prediction to start", timeout: 8) { telemetry("drift") != nil }

        // The SDK will not retry a connection that never really established,
        // so play past the uptime gate first.
        hold(["d"], seconds: 6.0)

        playground.dropConnection()
        drive(playground, "the drop", timeout: 6) { playground.status.contains("reconnect") }
        drive(playground, "the reconnect", timeout: 25) { playground.status.isEmpty }

        // The reconnected session numbers its inputs from zero; the lab's
        // onReconnect has to have let go of the old window.
        hold(["a"], seconds: 2.0)
        XCTAssertEqual(telemetry("drift"), "matched",
                       "correction \(telemetry("correction") ?? "?") after reconnect")
    }
}
