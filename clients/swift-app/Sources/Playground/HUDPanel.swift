import Colyseus
import Foundation
import PlaygroundKit
import SpriteKit

/// The title, the telemetry rows and the key bindings.
@MainActor
final class HUDPanel {
    let node = SKNode()

    private let title = SKLabelNode(fontNamed: "Menlo-Bold")
    private let summary = SKLabelNode(fontNamed: "Menlo")
    private let status = SKLabelNode(fontNamed: "Menlo-Bold")
    private let latency = SKLabelNode(fontNamed: "Menlo")
    private var rows: [(label: SKLabelNode, value: SKLabelNode)] = []
    private var controls: [SKLabelNode] = []
    private let footer = SKLabelNode(fontNamed: "Menlo")

    private var panelX = 0.0
    private var top = 0.0

    init() {
        node.zPosition = 100

        for label in [title, summary, status, latency, footer] {
            label.horizontalAlignmentMode = .left
            node.addChild(label)
        }

        title.fontSize = 15
        title.fontColor = SKColor(cgColor: Palette.text) ?? .white
        summary.fontSize = 10
        summary.fontColor = SKColor(cgColor: Palette.dim) ?? .gray
        status.fontSize = 12
        status.fontColor = SKColor(cgColor: Palette.warn) ?? .yellow
        latency.fontSize = 11
        latency.fontColor = SKColor(cgColor: Palette.accent) ?? .cyan
        footer.fontSize = 10
        footer.fontColor = SKColor(cgColor: Palette.dim) ?? .gray
        footer.text = "[ ] lab   0-9 jump   L latency   K drop"

        // Enough rows for the busiest lab; unused ones stay blank.
        for index in 0 ..< 10 {
            let label = SKLabelNode(fontNamed: "Menlo")
            let value = SKLabelNode(fontNamed: "Menlo-Bold")
            label.fontSize = 11
            value.fontSize = 11
            label.horizontalAlignmentMode = .left
            value.horizontalAlignmentMode = .left
            label.fontColor = SKColor(cgColor: Palette.dim) ?? .gray
            node.addChild(label)
            node.addChild(value)
            rows.append((label: label, value: value))
            _ = index
        }

        for _ in 0 ..< 5 {
            let label = SKLabelNode(fontNamed: "Menlo")
            label.fontSize = 10
            label.horizontalAlignmentMode = .left
            label.fontColor = SKColor(cgColor: Palette.dim) ?? .gray
            node.addChild(label)
            controls.append(label)
        }
    }

    func layout(in size: CGSize, panelWidth: Double) {
        panelX = size.width - panelWidth + 14
        top = size.height - 28

        title.position = CGPoint(x: panelX, y: top)
        summary.position = CGPoint(x: panelX, y: top - 18)
        status.position = CGPoint(x: panelX, y: top - 38)
        latency.position = CGPoint(x: panelX, y: top - 56)

        for (index, row) in rows.enumerated() {
            let y = top - 82 - Double(index) * 16
            row.label.position = CGPoint(x: panelX, y: y)
            row.value.position = CGPoint(x: panelX + 96, y: y)
        }

        for (index, control) in controls.enumerated() {
            control.position = CGPoint(x: panelX, y: top - 260 - Double(index) * 15)
        }

        footer.position = CGPoint(x: 14, y: 14)
    }

    func update(_ playground: Playground) {
        title.text = playground.title
        summary.text = wrap(playground.summary)
        status.text = playground.status
        latency.text = "latency  \(playground.latencyLabel)"

        let telemetry = playground.telemetry
        for (index, row) in rows.enumerated() {
            guard index < telemetry.count else {
                row.label.text = ""
                row.value.text = ""
                continue
            }
            row.label.text = telemetry[index].label
            row.value.text = telemetry[index].value
            row.value.fontColor = SKColor(cgColor: colour(for: telemetry[index].verdict)) ?? .white
        }

        let bindings = playground.controls
        for (index, control) in controls.enumerated() {
            guard index < bindings.count else {
                control.text = ""
                continue
            }
            let binding = bindings[index]
            control.text = binding.value.isEmpty
                ? "\(binding.key)  \(binding.label)"
                : "\(binding.key)  \(binding.label): \(binding.value)"
        }
    }

    /// The summary is one line in the panel's width, so it gets clipped rather
    /// than running under the arena.
    private func wrap(_ text: String) -> String {
        text.count > 34 ? String(text.prefix(33)) + "…" : text
    }

    private func colour(for verdict: TelemetryRow.Verdict) -> CGColor {
        switch verdict {
        case .neutral: return Palette.text
        case .good: return Palette.good
        case .warn: return Palette.warn
        case .bad: return Palette.bad
        }
    }
}
