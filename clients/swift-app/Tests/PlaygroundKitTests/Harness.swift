import Colyseus
import Foundation
import XCTest
@testable import PlaygroundKit

enum Server {
    static let endpoint = ProcessInfo.processInfo.environment["PLAYGROUND_ENDPOINT"]
        ?? "ws://127.0.0.1:5173"

    /// Skip rather than fail when the playground is not running, with the
    /// command that starts it — `--host` is not optional, because Vite binds
    /// IPv6 loopback and a native client dials IPv4.
    static func require() throws {
        guard let url = URL(string: endpoint.replacingOccurrences(of: "ws://", with: "http://")) else {
            throw XCTSkip("bad endpoint \(endpoint)")
        }

        var request = URLRequest(url: url.appendingPathComponent("matchmake/"))
        request.timeoutInterval = 2

        let reachable = Flag()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable.set(response != nil)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)

        guard reachable.value else {
            throw XCTSkip("no playground on \(endpoint) — start it with: pnpm dev --host 0.0.0.0")
        }
    }
}

extension XCTestCase {
    /// Drive the real shell's frame loop until `condition` holds.
    @discardableResult
    func drive(
        _ playground: Playground,
        _ what: String,
        timeout: TimeInterval = 10,
        until condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            playground.frame()
            _ = playground.draw()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        return false
    }

    /// Drive for a fixed stretch, drawing every frame — which is what catches
    /// a lab that throws while painting.
    func drive(_ playground: Playground, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            playground.frame()
            _ = playground.draw()
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        }
    }

}

/// A boolean an escaping handler can set.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flag = value
    }
}
