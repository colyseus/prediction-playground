import Colyseus
import Foundation
import PlaygroundKit
import SpriteKit

/// Renders whatever the current lab drew, plus the panels around it.
///
/// The scene knows nothing about any particular lab: it drives the shell, asks
/// for a draw list in world coordinates, and paints it.
final class PlaygroundScene: SKScene {
    private let playground: Playground
    private var view_ = WorldView()

    private let arena = SKNode()
    private let shapes = SKNode()
    private let hud = HUDPanel()

    init(size: CGSize, endpoint: String) {
        playground = Playground(endpoint: endpoint)
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = SKColor(cgColor: Palette.background) ?? .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        addChild(arena)
        addChild(shapes)
        addChild(hud.node)

        // The SDK's own timer would pump on a second thread; this scene pumps
        // from its frame callback so decoding, prediction and drawing all
        // happen on one thread and inside one frame.
        Colyseus.autoPump = false
        layout()
        playground.select(0)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        layout()
    }

    private func layout() {
        // The panel takes the right-hand strip; the arena letterboxes into
        // what is left.
        let panelWidth = min(260.0, size.width * 0.32)
        view_.fit(CGSize(width: size.width - panelWidth, height: size.height - 60))
        buildArena()
        hud.layout(in: size, panelWidth: panelWidth)
    }

    // MARK: - Frame

    override func update(_ currentTime: TimeInterval) {
        playground.frame()
        render(playground.draw())
        hud.update(playground)
    }

    private func render(_ list: DrawList) {
        shapes.removeAllChildren()
        for shape in list.shapes {
            if let node = node(for: shape) { shapes.addChild(node) }
        }
    }

    private func node(for shape: DrawList.Shape) -> SKNode? {
        switch shape {
        case .square(let x, let y, let half, let color, let alpha):
            let side = view_.length(half * 2)
            let node = SKShapeNode(rectOf: CGSize(width: side, height: side))
            node.fillColor = SKColor(cgColor: color) ?? .white
            node.strokeColor = .clear
            node.alpha = alpha
            node.position = view_.point(x, y)
            return node

        case .squareOutline(let x, let y, let half, let color, let alpha, let dashed):
            let side = view_.length(half * 2)
            let path = CGPath(rect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), transform: nil)
            let node = SKShapeNode(path: dashed ? dash(path) : path)
            node.fillColor = .clear
            node.strokeColor = SKColor(cgColor: color) ?? .white
            node.lineWidth = 1.5
            node.alpha = alpha
            node.position = view_.point(x, y)
            return node

        case .circle(let x, let y, let radius, let color, let alpha):
            let node = SKShapeNode(circleOfRadius: view_.length(radius))
            node.fillColor = SKColor(cgColor: color) ?? .white
            node.strokeColor = .clear
            node.alpha = alpha
            node.position = view_.point(x, y)
            return node

        case .circleOutline(let x, let y, let radius, let color, let alpha, let dashed):
            let path = CGPath(ellipseIn: CGRect(
                x: -view_.length(radius), y: -view_.length(radius),
                width: view_.length(radius) * 2, height: view_.length(radius) * 2
            ), transform: nil)
            let node = SKShapeNode(path: dashed ? dash(path) : path)
            node.fillColor = .clear
            node.strokeColor = SKColor(cgColor: color) ?? .white
            node.lineWidth = 1.5
            node.alpha = alpha
            node.position = view_.point(x, y)
            return node

        case .line(let x1, let y1, let x2, let y2, let color, let alpha, let width):
            let path = CGMutablePath()
            path.move(to: view_.point(x1, y1))
            path.addLine(to: view_.point(x2, y2))
            let node = SKShapeNode(path: path)
            node.strokeColor = SKColor(cgColor: color) ?? .white
            node.lineWidth = max(1, view_.length(width))
            node.lineCap = .round
            node.alpha = alpha
            return node

        case .rect(let x, let y, let width, let height, let color, let alpha):
            let origin = view_.point(x, y + height)
            let node = SKShapeNode(rect: CGRect(
                x: origin.x, y: origin.y,
                width: view_.length(width), height: view_.length(height)
            ))
            node.fillColor = SKColor(cgColor: color) ?? .white
            node.strokeColor = .clear
            node.alpha = alpha
            return node

        case .label(let x, let y, let text, let color, let size):
            let node = SKLabelNode(fontNamed: "Menlo-Bold")
            node.text = text
            node.fontSize = max(9, view_.length(size))
            node.fontColor = SKColor(cgColor: color) ?? .white
            node.horizontalAlignmentMode = .left
            node.position = view_.point(x, y)
            return node
        }
    }

    /// SpriteKit has no dashed stroke, so the path is cut into dashes.
    private func dash(_ path: CGPath) -> CGPath {
        path.copy(dashingWithPhase: 0, lengths: [5, 4])
    }

    private func buildArena() {
        arena.removeAllChildren()

        let border = SKShapeNode(rect: CGRect(
            origin: view_.point(0, Sim.arenaHeight),
            size: CGSize(width: view_.length(Sim.arenaWidth), height: view_.length(Sim.arenaHeight))
        ))
        border.strokeColor = SKColor(cgColor: Palette.border) ?? .gray
        border.lineWidth = 2
        border.fillColor = .clear
        arena.addChild(border)

        // A ten-unit grid, so motion has something to read against.
        let grid = SKShapeNode()
        let path = CGMutablePath()
        for x in stride(from: 10.0, to: Sim.arenaWidth, by: 10) {
            path.move(to: view_.point(x, 0))
            path.addLine(to: view_.point(x, Sim.arenaHeight))
        }
        for y in stride(from: 10.0, to: Sim.arenaHeight, by: 10) {
            path.move(to: view_.point(0, y))
            path.addLine(to: view_.point(Sim.arenaWidth, y))
        }
        grid.path = path
        grid.strokeColor = SKColor(cgColor: Palette.grid) ?? .gray
        grid.lineWidth = 1
        grid.alpha = 0.18
        arena.addChild(grid)
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        guard let key = Self.name(for: event) else { return }

        switch key {
        case "[": playground.previous()
        case "]": playground.next()
        case "l": playground.cycleLatency()
        case "k": playground.dropConnection()
        default:
            if let digit = Int(key), digit >= 0, digit <= 9 {
                playground.select(digit)
                return
            }
            playground.keyboard.press(key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let key = Self.name(for: event) else { return }
        playground.keyboard.release(key)
    }

    override func mouseMoved(with event: NSEvent) {
        aim(at: event.location(in: self))
    }

    override func mouseDown(with event: NSEvent) {
        aim(at: event.location(in: self))
        playground.keyboard.press("space")
    }

    override func mouseUp(with event: NSEvent) {
        playground.keyboard.release("space")
    }

    /// The labs that aim take the pointer in world units.
    private func aim(at point: CGPoint) {
        let world = view_.worldPoint(point)
        switch playground.current {
        case let lab as Lab06LagComp: lab.setAim(x: world.x, y: world.y)
        case let lab as Lab09PredictedSpawns: lab.setAim(x: world.x, y: world.y)
        case let lab as Lab11DeterministicRng: lab.setAim(x: world.x, y: world.y)
        default: break
        }
    }

    /// Arrow keys and the labs' own bindings, by name.
    private static func name(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 49: return "space"
        default: return event.charactersIgnoringModifiers?.lowercased()
        }
    }

    func shutdown() {
        playground.shutdown()
    }

    /// Render the live scene to a PNG, for `--screenshot`.
    var shell: Playground { playground }
}
