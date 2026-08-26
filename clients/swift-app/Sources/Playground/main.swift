import AppKit
import Foundation
import PlaygroundKit
import SpriteKit

// `--selfcheck` runs the shared-simulation canaries and exits, so CI can
// verify the port with no display and no server.
if CommandLine.arguments.contains("--selfcheck") {
    let failures = Sim.selfCheck()
    if failures.isEmpty {
        print("sim self-check: OK")
        exit(0)
    }
    failures.forEach { FileHandle.standardError.write(Data(($0.description + "\n").utf8)) }
    exit(1)
}

/// `--screenshot <path> [--lab n] [--seconds n]` plays a lab for a while and
/// writes what it drew, then exits.
struct ScreenshotRequest {
    var path: String
    var lab: Int
    var seconds: TimeInterval
}

func argument(_ name: String) -> String? {
    CommandLine.arguments.firstIndex(of: name).map { CommandLine.arguments[$0 + 1] }
}

let screenshot = argument("--screenshot").map {
    ScreenshotRequest(
        path: $0,
        lab: argument("--lab").flatMap(Int.init) ?? 3,
        seconds: argument("--seconds").flatMap(Double.init) ?? 6
    )
}

let endpoint = argument("--endpoint")
    ?? ProcessInfo.processInfo.environment["PLAYGROUND_ENDPOINT"]
    ?? "ws://127.0.0.1:5173"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var scene: PlaygroundScene!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 1180, height: 700)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prediction Playground — Colyseus Swift SDK"
        window.center()

        let view = SKView(frame: NSRect(origin: .zero, size: size))
        scene = PlaygroundScene(size: size, endpoint: endpoint)
        view.presentScene(scene)
        window.contentView = view

        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let screenshot else { return }
        scene.shell.select(screenshot.lab)
        DispatchQueue.main.asyncAfter(deadline: .now() + screenshot.seconds) {
            let ok = Self.write(view: view, scene: self.scene, to: screenshot.path)
            print(ok ? "wrote \(screenshot.path)" : "could not render a frame")
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func write(view: SKView, scene: SKScene, to path: String) -> Bool {
        guard let texture = view.texture(from: scene),
              let image = texture.cgImage() as CGImage?
        else { return false }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        scene?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
