import CoreGraphics
import Foundation

/// The arena is a fixed 100×60 logical rectangle; the window is whatever the
/// user made it. This letterboxes one into the other.
public struct WorldView: Sendable {
    public private(set) var scale = 1.0
    public private(set) var originX = 0.0
    public private(set) var originY = 0.0
    public private(set) var size = CGSize(width: 100, height: 60)

    public init() {}

    /// Fit the arena into `size`, centred, preserving its aspect ratio.
    public mutating func fit(_ size: CGSize) {
        self.size = size
        scale = min(size.width / Sim.arenaWidth, size.height / Sim.arenaHeight)
        originX = (size.width - Sim.arenaWidth * scale) / 2
        originY = (size.height - Sim.arenaHeight * scale) / 2
    }

    /// World to screen.
    ///
    /// The arena's y grows downward, as it does on a canvas; SpriteKit's grows
    /// upward. Flipping here keeps the layout the same as the web client's
    /// rather than mirroring every lab.
    public func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: originX + x * scale, y: originY + (Sim.arenaHeight - y) * scale)
    }

    public func length(_ world: Double) -> Double { world * scale }

    /// Screen to world — for aiming with a pointer.
    public func worldPoint(_ point: CGPoint) -> (x: Double, y: Double) {
        (x: (point.x - originX) / scale, y: Sim.arenaHeight - (point.y - originY) / scale)
    }

    /// The demo's colour for a player's hue byte, matching the web client's
    /// `hsl(hue / 256 * 360, 72%, 62%)`.
    public static func color(hue: Double) -> CGColor {
        hsl(hue: hue / 256 * 360, saturation: 0.72, lightness: 0.62)
    }

    static func hsl(hue: Double, saturation: Double, lightness: Double) -> CGColor {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2

        let rgb: (Double, Double, Double)
        switch hp {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }

        return CGColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
    }
}
