import Foundation

/// The playground's shared simulation.
///
/// A bit-exact f64 transliteration of `src/shared/*.ts`: same operation order,
/// same constants. Determinism across the wire is the whole contract — the
/// server runs the TypeScript original, this runs on the client, and
/// steady-state reconcile corrections have to be exactly zero.
public enum Sim {
    // shared/constants.ts

    public static let tickHz = 20.0
    public static let dt = 1.0 / tickHz
    public static let arenaWidth = 100.0
    public static let arenaHeight = 60.0
    public static let playerHalf = 1.6
    public static let playerAccel = 220.0
    public static let playerMaxSpeed = 34.0
    public static let playerFriction = 0.72
    public static let botRadius = 1.8
    /// Hitscan reach. The client previews its own verdict with the same
    /// ``rayCircle(origin:direction:centre:radius:maxDistance:)`` the server
    /// resolves with, so a different range would show a hit the server denies.
    public static let shotRange = 200.0
    public static let remoteInterpMs = 100.0
    /// A discontinuity further than this renders as a cut, not a glide.
    public static let teleportSnapDistance = 8.0

    /// `Math.SQRT1_2` — the exact double the JavaScript multiplies by.
    public static let sqrt1_2 = 0.70710678118654752440

    /// Anything with a position and a velocity: a player, a bot, a puck.
    public struct Entity: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var vx: Double
        public var vy: Double

        public init(x: Double = 0, y: Double = 0, vx: Double = 0, vy: Double = 0) {
            self.x = x
            self.y = y
            self.vx = vx
            self.vy = vy
        }
    }

    // MARK: - shared/movement.ts

    /// The single deterministic movement step, run identically by the server
    /// once per received input and by the reconciler on every prediction and
    /// rollback replay. Multiply, add and square root only.
    public static func stepEntity(_ entity: inout Entity, moveX: Double, moveY: Double, dt: Double) {
        var ax = moveX
        var ay = moveY
        if ax != 0, ay != 0 {
            ax *= sqrt1_2
            ay *= sqrt1_2
        }

        if ax != 0 || ay != 0 {
            entity.vx += ax * playerAccel * dt
            entity.vy += ay * playerAccel * dt
        } else {
            entity.vx *= playerFriction
            entity.vy *= playerFriction
            if entity.vx > -0.05, entity.vx < 0.05 { entity.vx = 0 }
            if entity.vy > -0.05, entity.vy < 0.05 { entity.vy = 0 }
        }

        let squared = entity.vx * entity.vx + entity.vy * entity.vy
        if squared > playerMaxSpeed * playerMaxSpeed {
            let scale = playerMaxSpeed / squared.squareRoot()
            entity.vx *= scale
            entity.vy *= scale
        }

        entity.x += entity.vx * dt
        entity.y += entity.vy * dt

        let minX = playerHalf, maxX = arenaWidth - playerHalf
        let minY = playerHalf, maxY = arenaHeight - playerHalf
        if entity.x < minX { entity.x = minX; if entity.vx < 0 { entity.vx = 0 } }
        else if entity.x > maxX { entity.x = maxX; if entity.vx > 0 { entity.vx = 0 } }
        if entity.y < minY { entity.y = minY; if entity.vy < 0 { entity.vy = 0 } }
        else if entity.y > maxY { entity.y = maxY; if entity.vy > 0 { entity.vy = 0 } }
    }

    // MARK: - shared/goal.ts

    public static let goalZone = (x: arenaWidth - 8.0, y: arenaHeight / 2 - 9.0, width: 8.0, height: 18.0)
    /// Re-entry lockout, in fixed steps. Reconciled tick state on both sides.
    public static let scoreCooldownTicks = 50

    /// The scoring gate. A pure function of predicted state, so it is
    /// deterministic under rollback replay: true on the entry EDGE, the step
    /// that crossed into the zone with the gate open.
    ///
    /// Whether the goal is AWARDED stays server-only, which is why the gate
    /// itself never mispredicts.
    public static func scoreGate(x: Double, y: Double, scoreTicks: inout Int) -> Bool {
        if scoreTicks > 0 {
            scoreTicks -= 1
            return false
        }
        if x >= goalZone.x, y >= goalZone.y, y <= goalZone.y + goalZone.height {
            scoreTicks = scoreCooldownTicks
            return true
        }
        return false
    }

    // MARK: - shared/projectile.ts

    public static let projectileSpeed = 34.0
    public static let projectileRadius = 0.7
    public static let projectileTtlMs = 2600.0

    /// Constant-velocity flight with wall bounces.
    public static func stepProjectile(_ projectile: inout Entity, dt: Double) {
        projectile.x += projectile.vx * dt
        projectile.y += projectile.vy * dt
        if projectile.x < 0 { projectile.x = 0; projectile.vx = abs(projectile.vx) }
        else if projectile.x > arenaWidth { projectile.x = arenaWidth; projectile.vx = -abs(projectile.vx) }
        if projectile.y < 0 { projectile.y = 0; projectile.vy = abs(projectile.vy) }
        else if projectile.y > arenaHeight { projectile.y = arenaHeight; projectile.vy = -abs(projectile.vy) }
    }

    // MARK: - shared/movers.ts

    public static let teleportPeriodMs = 3000.0
    /// How often a wandering bot picks a new heading — a server-side secret.
    public static let wanderTurnMs = 900.0

    /// A bot, with the fields its pattern reads.
    ///
    /// The reckon scratch is a full copy of the entity, so the non-attached
    /// fields are readable inside the step.
    public struct Bot: Equatable, Sendable {
        public var x = 0.0
        public var y = 0.0
        public var vx = 0.0
        public var vy = 0.0
        public var kind = "patrol"
        public var minX = 0.0
        public var maxX = 0.0
        public var baseY = 0.0
        public var phaseMs = 0.0
        public var speed = 0.0
        public var lastTeleport = 0.0

        public init() {}
    }

    /// Horizontal ping-pong between minX and maxX.
    static func patrol(_ bot: inout Bot, dt: Double) {
        bot.x += bot.vx * dt
        bot.y = bot.baseY
        if bot.x < bot.minX { bot.x = bot.minX; bot.vx = abs(bot.vx) }
        else if bot.x > bot.maxX { bot.x = bot.maxX; bot.vx = -abs(bot.vx) }
    }

    /// Run by the server every fixed tick, and by the client's reckon mode to
    /// forward-simulate from the latest snapshot to now.
    ///
    /// `elapsedMs` is the shared server-clock timeline, which is what makes
    /// time-sampled motion — the circle, the teleport schedule — evaluable at
    /// any instant rather than only on a tick boundary.
    ///
    /// `wander` is deliberately only partly predictable: it integrates
    /// velocity, but its heading changes come from a seed only the server has.
    /// That error is the lesson, not a bug.
    public static func stepBot(_ bot: inout Bot, dt: Double, elapsedMs: Double) {
        switch bot.kind {
        case "circle":
            let centreX = (bot.minX + bot.maxX) / 2
            let radiusX = (bot.maxX - bot.minX) / 2
            let radiusY = min(12.0, arenaHeight / 2 - botRadius - 2)
            let omega = bot.speed / radiusX
            let t = (elapsedMs + bot.phaseMs) / 1000.0
            bot.x = centreX + radiusX * cos(omega * t)
            bot.y = bot.baseY + radiusY * sin(omega * t)
            bot.vx = -radiusX * omega * sin(omega * t)
            bot.vy = radiusY * omega * cos(omega * t)

        case "teleport":
            patrol(&bot, dt: dt)
            // The warp is predictable from the synced schedule: half the
            // patrol span, wrapping, every period — a constant, visible cut.
            while bot.lastTeleport > 0, elapsedMs - bot.lastTeleport >= teleportPeriodMs {
                let span = bot.maxX - bot.minX
                bot.x = bot.minX + (bot.x - bot.minX + span / 2).truncatingRemainder(dividingBy: span)
                bot.lastTeleport += teleportPeriodMs
            }

        case "wander":
            bot.x += bot.vx * dt
            bot.y += bot.vy * dt
            let minimum = botRadius
            let maxX = arenaWidth - botRadius
            let maxY = arenaHeight - botRadius
            if bot.x < minimum { bot.x = minimum; bot.vx = abs(bot.vx) }
            else if bot.x > maxX { bot.x = maxX; bot.vx = -abs(bot.vx) }
            if bot.y < minimum { bot.y = minimum; bot.vy = abs(bot.vy) }
            else if bot.y > maxY { bot.y = maxY; bot.vy = -abs(bot.vy) }

        default:
            patrol(&bot, dt: dt)
        }
    }

    // MARK: - shared/hitscan.ts

    /// Ray against circle. Returns the distance along a unit direction to the
    /// nearest intersection, or nil on a miss.
    ///
    /// Shared so the client's shot preview and the server's resolution cannot
    /// drift apart.
    public static func rayCircle(
        originX: Double, originY: Double,
        dirX: Double, dirY: Double,
        centreX: Double, centreY: Double,
        radius: Double, maxDistance: Double
    ) -> Double? {
        let mx = originX - centreX
        let my = originY - centreY
        let b = mx * dirX + my * dirY
        let c = mx * mx + my * my - radius * radius
        if c > 0, b > 0 { return nil }  // outside, pointing away

        let discriminant = b * b - c
        if discriminant < 0 { return nil }

        let t = -b - discriminant.squareRoot()
        let hit = t < 0 ? 0 : t  // starting inside the circle is a hit at zero
        return hit <= maxDistance ? hit : nil
    }

    // MARK: - shared/bump.ts

    /// Post-bump immunity, in fixed steps. A reconciled tick gate: both sides
    /// run the identical countdown, so "can I be bumped?" never mispredicts.
    public static let bumpCooldownTicks = 12
    public static let bumpSpeed = 48.0

    /// The cooldown countdown, run BEFORE the movement step on both sides.
    public static func stepBumpGate(_ bumpTicks: inout Int) {
        if bumpTicks > 0 { bumpTicks -= 1 }
    }

    /// Player against bot at an agreed bot position.
    ///
    /// Returns the knockback velocity on a hit. The caller applies it and
    /// re-arms the immunity — on the client that happens inside the reconciler
    /// step, so the whole outcome rides adopt and replay.
    public static func collideBot(
        playerX: Double, playerY: Double, bumpTicks: Int,
        botX: Double, botY: Double
    ) -> (vx: Double, vy: Double)? {
        if bumpTicks > 0 { return nil }

        let dx = playerX - botX
        let dy = playerY - botY
        let radius = playerHalf + botRadius
        let squared = dx * dx + dy * dy
        if squared >= radius * radius { return nil }

        var distance = squared.squareRoot()
        if distance == 0 { distance = 1e-6 }
        return (vx: dx / distance * bumpSpeed, vy: dy / distance * bumpSpeed)
    }

    // MARK: - shared/random.ts

    /// One-shot avalanche of a 32-bit seed into a well-mixed word.
    ///
    /// UInt32 throughout, matching JavaScript's `| 0`, `>>> 0` and `Math.imul`
    /// exactly. This is the module that breaks on 31-bit integers.
    public static func splitmix32(_ seed: UInt32) -> UInt32 {
        let a = seed &+ 0x9e37_79b9
        var t = a ^ (a >> 16)
        t = t &* 0x21f0_aaad
        t = t ^ (t >> 15)
        t = t &* 0x735a_2d97
        return t ^ (t >> 15)
    }

    /// A tiny seeded PRNG. Advances `state` and returns a value in [0, 1).
    public static func mulberry32(_ state: inout UInt32) -> Double {
        state = state &+ 0x6d2b_79f5
        let a = state
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }

    /// The per-shot seed, from the input sequence and a synced per-round salt.
    /// The stream itself never goes on the wire.
    public static func shotSeed(seq: Int, salt: UInt32) -> UInt32 {
        splitmix32(UInt32(truncatingIfNeeded: seq) ^ (salt &* 0x85eb_ca6b))
    }

    // MARK: - shared/spread.ts

    public static let pellets = 6
    public static let spreadRadians = 0.38

    /// The shotgun fan. The same derivation on both sides, with nothing random
    /// on the wire: client and server roll identical pellets for one shot.
    public static func spreadAngles(base: Double, seq: Int, salt: UInt32) -> [Double] {
        var state = shotSeed(seq: seq, salt: salt)
        return (0 ..< pellets).map { _ in
            base + (mulberry32(&state) - 0.5) * spreadRadians
        }
    }

    // MARK: - shared/hockey.ts

    public static let paddleRadius = 2.2
    public static let puckRadius = 1.4
    /// Per-tick puck damping. dt is fixed, so this is a literal constant.
    public static let puckFriction = 0.985
    public static let puckRestitution = 0.92
    public static let puckPushMin = 14.0

    /// The session id of the server-driven paddle in `lab-hockey`.
    public static let hockeyBotId = "bot"

    /// Puck free flight: bleed speed, integrate, bounce off the walls.
    public static func stepPuck(_ puck: inout Entity, dt: Double) {
        puck.vx *= puckFriction
        puck.vy *= puckFriction
        puck.x += puck.vx * dt
        puck.y += puck.vy * dt

        let minimum = puckRadius
        let maxX = arenaWidth - puckRadius
        let maxY = arenaHeight - puckRadius
        if puck.x < minimum { puck.x = minimum; puck.vx = abs(puck.vx) * puckRestitution }
        else if puck.x > maxX { puck.x = maxX; puck.vx = -abs(puck.vx) * puckRestitution }
        if puck.y < minimum { puck.y = minimum; puck.vy = abs(puck.vy) * puckRestitution }
        else if puck.y > maxY { puck.y = maxY; puck.vy = -abs(puck.vy) * puckRestitution }
    }

    /// Paddle against puck: push the puck out along the contact normal and
    /// give it the paddle's velocity plus a minimum separation speed.
    ///
    /// The push-out then resolves against the walls, so a puck squeezed
    /// between a paddle and a wall stays inside the arena rather than being
    /// ejected past it. Order-dependent: both sides must resolve paddles in
    /// the same order, which is the players-map iteration order.
    @discardableResult
    public static func collidePaddlePuck(
        paddleX: Double, paddleY: Double,
        paddleVx: Double, paddleVy: Double,
        puck: inout Entity
    ) -> Bool {
        let dx = puck.x - paddleX
        let dy = puck.y - paddleY
        let radius = paddleRadius + puckRadius
        let squared = dx * dx + dy * dy
        if squared >= radius * radius { return false }

        var distance = squared.squareRoot()
        if distance == 0 { distance = 1e-6 }
        let nx = dx / distance, ny = dy / distance

        puck.x = paddleX + nx * radius
        puck.y = paddleY + ny * radius

        let along = paddleVx * nx + paddleVy * ny
        let speed = along > puckPushMin ? along : puckPushMin
        puck.vx = nx * speed + paddleVx * 0.35
        puck.vy = ny * speed + paddleVy * 0.35

        let minimum = puckRadius
        let maxX = arenaWidth - puckRadius
        let maxY = arenaHeight - puckRadius
        if puck.x < minimum { puck.x = minimum; puck.vx = abs(puck.vx) * puckRestitution }
        else if puck.x > maxX { puck.x = maxX; puck.vx = -abs(puck.vx) * puckRestitution }
        if puck.y < minimum { puck.y = minimum; puck.vy = abs(puck.vy) * puckRestitution }
        else if puck.y > maxY { puck.y = maxY; puck.vy = -abs(puck.vy) * puckRestitution }
        return true
    }

    /// The bot paddle's steering, quantised to the same tri-state move input a
    /// human sends.
    ///
    /// A server-owned decision, but a pure function of synced state — the puck
    /// it chases and whether it is enabled — so a predicting client derives it
    /// exactly. The bot is remote but not unpredictable, which is the whole
    /// point of lab 10.
    public static func botInput(
        botX: Double, botY: Double,
        puckX: Double, puckY: Double,
        enabled: Bool
    ) -> (moveX: Double, moveY: Double) {
        let chase = enabled && puckY < arenaHeight / 2
        let targetX = chase ? puckX : arenaWidth / 2
        let targetY = chase ? puckY : arenaHeight * 0.2
        return (
            moveX: targetX - botX > 1 ? 1 : (targetX - botX < -1 ? -1 : 0),
            moveY: targetY - botY > 1 ? 1 : (targetY - botY < -1 ? -1 : 0)
        )
    }
}
