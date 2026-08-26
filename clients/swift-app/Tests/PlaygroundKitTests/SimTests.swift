import XCTest
@testable import PlaygroundKit

final class SimTests: XCTestCase {
    /// The shared simulation, against the same reference numbers the C port
    /// pins. Everything else this app measures assumes this passes.
    func testSelfCheck() {
        let failures = Sim.selfCheck()
        XCTAssertTrue(failures.isEmpty, failures.map(\.description).joined(separator: "\n"))
    }
}
