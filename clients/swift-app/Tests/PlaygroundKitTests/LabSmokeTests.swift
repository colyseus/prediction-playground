import Colyseus
import Foundation
import XCTest
@testable import PlaygroundKit

/// Every lab, mounted and driven against the real server.
///
/// This is the check that catches a lab that fails to join, throws in its
/// step, or blows up while painting — the failure modes that never show up in
/// a unit test because they need a room.
final class LabSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try Server.require()
        Colyseus.autoPump = false
    }

    override func tearDown() { Colyseus.autoPump = true }

    func testEveryLabMountsAndRuns() throws {
        let playground = Playground(endpoint: Server.endpoint)
        defer { playground.shutdown() }

        for index in Playground.labs.indices {
            let type = Playground.labs[index]
            playground.select(index)

            let mounted = drive(playground, "lab \(type.id) to join", timeout: 12) {
                playground.current != nil
            }
            XCTAssertTrue(mounted, "lab \(type.id) (\(type.title)) never mounted: \(playground.status)")
            guard mounted else { continue }

            // Real frames, with the draw list built each time.
            drive(playground, seconds: 1.2)

            XCTAssertEqual(type.id, Playground.labs[playground.index].id)
            XCTAssertFalse(playground.telemetry.isEmpty,
                           "lab \(type.id) reported no telemetry")
            XCTAssertFalse(playground.draw().shapes.isEmpty,
                           "lab \(type.id) drew nothing")
        }
    }

    func testTheLabsAreNumberedInOrder() {
        // Explicit closures rather than key paths: a key path to a static
        // member of an existential metatype crashes SILGen in Swift 6.2.4.
        XCTAssertEqual(
            Playground.labs.map { $0.id },
            ["00", "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11"]
        )
        XCTAssertEqual(Set(Playground.labs.map { $0.title }).count, Playground.labs.count)
    }
}
