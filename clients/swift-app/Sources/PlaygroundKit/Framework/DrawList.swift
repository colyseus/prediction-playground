import CoreGraphics
import Foundation

/// What a lab wants drawn, in world coordinates.
///
/// Labs emit these instead of touching SpriteKit, which is what lets the
/// acceptance tests mount every lab and drive real frames with nothing
/// rendering.
public struct DrawList: Sendable {
    public enum Shape: Sendable {
        /// A filled square, centred, with a half-extent in world units.
        case square(x: Double, y: Double, half: Double, color: CGColor, alpha: Double)
        /// An outlined square — a ghost, a server position.
        case squareOutline(x: Double, y: Double, half: Double, color: CGColor, alpha: Double, dashed: Bool)
        case circle(x: Double, y: Double, radius: Double, color: CGColor, alpha: Double)
        case circleOutline(x: Double, y: Double, radius: Double, color: CGColor, alpha: Double, dashed: Bool)
        case line(x1: Double, y1: Double, x2: Double, y2: Double, color: CGColor, alpha: Double, width: Double)
        case rect(x: Double, y: Double, width: Double, height: Double, color: CGColor, alpha: Double)
        /// World-anchored text, for a label pinned to a thing.
        case label(x: Double, y: Double, text: String, color: CGColor, size: Double)
    }

    public private(set) var shapes: [Shape] = []

    public init() {}

    public mutating func add(_ shape: Shape) { shapes.append(shape) }

    public mutating func square(
        _ x: Double, _ y: Double, half: Double, color: CGColor, alpha: Double = 1
    ) {
        shapes.append(.square(x: x, y: y, half: half, color: color, alpha: alpha))
    }

    public mutating func squareOutline(
        _ x: Double, _ y: Double, half: Double, color: CGColor, alpha: Double = 1, dashed: Bool = false
    ) {
        shapes.append(.squareOutline(x: x, y: y, half: half, color: color, alpha: alpha, dashed: dashed))
    }

    public mutating func circle(
        _ x: Double, _ y: Double, radius: Double, color: CGColor, alpha: Double = 1
    ) {
        shapes.append(.circle(x: x, y: y, radius: radius, color: color, alpha: alpha))
    }

    public mutating func circleOutline(
        _ x: Double, _ y: Double, radius: Double, color: CGColor, alpha: Double = 1, dashed: Bool = false
    ) {
        shapes.append(.circleOutline(x: x, y: y, radius: radius, color: color, alpha: alpha, dashed: dashed))
    }

    public mutating func line(
        from: (x: Double, y: Double), to: (x: Double, y: Double),
        color: CGColor, alpha: Double = 1, width: Double = 0.3
    ) {
        shapes.append(.line(x1: from.x, y1: from.y, x2: to.x, y2: to.y, color: color, alpha: alpha, width: width))
    }

    public mutating func rect(
        _ x: Double, _ y: Double, width: Double, height: Double, color: CGColor, alpha: Double = 1
    ) {
        shapes.append(.rect(x: x, y: y, width: width, height: height, color: color, alpha: alpha))
    }

    public mutating func label(
        _ x: Double, _ y: Double, _ text: String, color: CGColor, size: Double = 1.6
    ) {
        shapes.append(.label(x: x, y: y, text: text, color: color, size: size))
    }
}

/// The palette, in one place.
public enum Palette {
    public static let background = CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
    public static let grid = CGColor(red: 0.25, green: 0.35, blue: 0.52, alpha: 1)
    public static let border = CGColor(red: 0.36, green: 0.50, blue: 0.72, alpha: 1)
    public static let text = CGColor(red: 0.85, green: 0.90, blue: 1.00, alpha: 1)
    public static let dim = CGColor(red: 0.52, green: 0.60, blue: 0.75, alpha: 1)
    public static let good = CGColor(red: 0.45, green: 0.88, blue: 0.60, alpha: 1)
    public static let warn = CGColor(red: 1.00, green: 0.78, blue: 0.35, alpha: 1)
    public static let bad = CGColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
    public static let ghost = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    public static let accent = CGColor(red: 0.42, green: 0.72, blue: 1.00, alpha: 1)
}
