import Foundation

public extension Sim {
    /// One failed expectation.
    struct CheckFailure: Sendable, CustomStringConvertible {
        public let name: String
        public let detail: String
        public var description: String { "\(name): \(detail)" }
    }

    /// Check that the port still reproduces the reference numbers.
    ///
    /// The values come from running the TypeScript original with the same
    /// inputs, and they are the same ones `clients/native-app/sim.h` pins — so
    /// this Swift port and the C one are held to one standard rather than two.
    ///
    /// This is the load-bearing check for the whole app: if the simulation has
    /// drifted from the server's, every drift reading elsewhere is measuring
    /// that instead of the network.
    static func selfCheck() -> [CheckFailure] {
        var failures: [CheckFailure] = []
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String) {
            if !passed { failures.append(CheckFailure(name: name, detail: detail())) }
        }

        // Five steps of pure-right acceleration from rest at the arena centre.
        do {
            var entity = Entity(x: 50, y: 30)
            for _ in 0 ..< 5 { stepEntity(&entity, moveX: 1, moveY: 0, dt: dt) }
            check("movement/accelerate",
                  entity.vx == playerMaxSpeed && entity.vy == 0 && abs(entity.x - 56.7) < 1e-12,
                  "x=\(entity.x) vx=\(entity.vx), want 56.7 / 34")
        }

        // Diagonal: SQRT1_2 has to match Math.SQRT1_2 to the last bit.
        do {
            var entity = Entity(x: 50, y: 30)
            stepEntity(&entity, moveX: 1, moveY: 1, dt: dt)
            check("movement/diagonal",
                  entity.vx == entity.vy && abs(entity.vx - 7.77817459305202341113) < 1e-15,
                  "vx=\(entity.vx) vy=\(entity.vy)")
        }

        // The wall clamp kills the outward velocity component.
        do {
            var entity = Entity(x: playerHalf + 0.1, y: 30, vx: -30)
            stepEntity(&entity, moveX: 0, moveY: 0, dt: dt)
            check("movement/wall",
                  abs(entity.x - playerHalf) < 1e-12 && entity.vx == 0,
                  "x=\(entity.x) vx=\(entity.vx)")
        }

        // The friction deadzone snaps to a hard zero, with no denormal drift.
        do {
            var entity = Entity(x: 50, y: 30, vx: 0.06)
            stepEntity(&entity, moveX: 0, moveY: 0, dt: dt)
            check("movement/friction", entity.vx == 0, "vx=\(entity.vx), want exactly 0")
        }

        // The circle bot's closed form has to be evaluable at any instant.
        do {
            var bot = Bot()
            bot.x = 50; bot.y = 18; bot.vx = 18
            bot.kind = "circle"
            bot.minX = 22; bot.maxX = 78; bot.baseY = 18; bot.speed = 18
            stepBot(&bot, dt: dt, elapsedMs: 1234)
            check("movers/circle",
                  abs(bot.x - 69.6422100736938887167) < 1e-12
                      && abs(bot.y - 26.5519448209259039118) < 1e-12,
                  "x=\(bot.x) y=\(bot.y)")
        }

        // The teleporter's warp schedule chains within one forward pass.
        do {
            var bot = Bot()
            bot.x = 70; bot.y = 18; bot.vx = 18
            bot.kind = "teleport"
            bot.minX = 22; bot.maxX = 78; bot.baseY = 18; bot.speed = 18; bot.lastTeleport = 1000
            stepBot(&bot, dt: dt, elapsedMs: 7100)
            check("movers/teleport",
                  abs(bot.x - 70.9) < 1e-12 && bot.lastTeleport == 7000,
                  "x=\(bot.x) lastTeleport=\(bot.lastTeleport)")
        }

        // A projectile's wall bounce flips the sign, not the magnitude.
        do {
            var projectile = Entity(x: 99, y: 30, vx: 34)
            stepProjectile(&projectile, dt: dt)
            check("projectile/bounce",
                  projectile.x == arenaWidth && projectile.vx == -34,
                  "x=\(projectile.x) vx=\(projectile.vx)")
        }

        // The RNG: uint32 integer maths, the one module that is not a straight
        // f64 transliteration.
        do {
            var state: UInt32 = 0xB0_7B07
            let first = mulberry32(&state)
            let second = mulberry32(&state)
            let third = mulberry32(&state)
            check("random/mulberry32",
                  abs(first - 0.00975770130753517150879) < 1e-18
                      && abs(second - 0.220020313980057835579) < 1e-15
                      && abs(third - 0.457878412213176488876) < 1e-15,
                  "\(first) \(second) \(third)")
            check("random/seeds",
                  splitmix32(1) == 1_580_013_426 && shotSeed(seq: 7, salt: 12345) == 1_994_071_465,
                  "splitmix32(1)=\(splitmix32(1)) shotSeed(7,12345)=\(shotSeed(seq: 7, salt: 12345))")
        }

        // The shotgun fan rides entirely on that stream.
        do {
            let fan = spreadAngles(base: 0.5, seq: 7, salt: 12345)
            check("spread/fan",
                  abs(fan[0] - 0.599485442587174510720) < 1e-15
                      && abs(fan[1] - 0.672593814930878552971) < 1e-15,
                  "\(fan[0]) \(fan[1])")
        }

        // A seed ABOVE 2^31. Both vectors above stay under it, so between them
        // they only exercise the half of the input space where a 32-bit seed
        // still fits a signed int — the Haxe port shipped a collapse in the
        // other half and its canary passed anyway. Real salts are uniform over
        // the whole u32 range, so half of all shots land here.
        do {
            let seed = shotSeed(seq: 50, salt: 3_004_265_928)
            let fan = spreadAngles(base: 0.5, seq: 50, salt: 3_004_265_928)
            check("random/wide seed",
                  seed == 2_712_337_003
                      && abs(fan[0] - 0.558667531493119873254) < 1e-15
                      && abs(fan[5] - 0.613833207678981085387) < 1e-15,
                  "shotSeed=\(seed) \(fan[0]) \(fan[5])")
        }

        // Hitscan: a tangent-free hit at 8, and a clean miss past the radius.
        do {
            let hit = rayCircle(originX: 0, originY: 0, dirX: 1, dirY: 0,
                                centreX: 10, centreY: 0, radius: 2, maxDistance: 100)
            let miss = rayCircle(originX: 0, originY: 0, dirX: 1, dirY: 0,
                                 centreX: 10, centreY: 5, radius: 2, maxDistance: 100)
            check("hitscan/ray", hit == 8.0 && miss == nil,
                  "hit=\(hit as Any) miss=\(miss as Any)")
        }

        // Hockey: damping applies BEFORE integration.
        do {
            var puck = Entity(x: 50, y: 30, vx: 20)
            stepPuck(&puck, dt: dt)
            check("hockey/puck",
                  abs(puck.x - 50.985) < 1e-12 && abs(puck.vx - 19.7) < 1e-12,
                  "x=\(puck.x) vx=\(puck.vx)")
        }

        // A contact snaps the puck out to the contact circle.
        do {
            var puck = Entity(x: 52, y: 30)
            let touched = collidePaddlePuck(paddleX: 50, paddleY: 30, paddleVx: 10, paddleVy: 0, puck: &puck)
            check("hockey/contact",
                  touched && abs(puck.x - 53.6) < 1e-12 && puck.vx == 17.5,
                  "hit=\(touched) x=\(puck.x) vx=\(puck.vx)")
        }

        // A paddle squeezing the puck against a wall keeps it inside.
        do {
            var puck = Entity(x: 50, y: 59)
            let touched = collidePaddlePuck(paddleX: 50, paddleY: 58, paddleVx: 0, paddleVy: 20, puck: &puck)
            check("hockey/wall pinch",
                  touched && abs(puck.y - (arenaHeight - puckRadius)) < 1e-12
                      && abs(puck.vy + 24.84) < 1e-12,
                  "y=\(puck.y) vy=\(puck.vy)")
        }

        return failures
    }
}
