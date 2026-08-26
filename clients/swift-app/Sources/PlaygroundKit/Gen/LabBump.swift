// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.19
// 

import Colyseus

public enum LabBump {}

extension LabBump {
    public final class MoveInput: SchemaRef, @unchecked Sendable {
        public var moveX: Double { view["moveX"] }
        public var moveY: Double { view["moveY"] }
    }

    public final class Player: SchemaRef, @unchecked Sendable {
        public var x: Double { view["x"] }
        public var y: Double { view["y"] }
        public var vx: Double { view["vx"] }
        public var vy: Double { view["vy"] }
        public var hue: Double { view["hue"] }
    }

    public final class MoveState: SchemaRef, @unchecked Sendable {
        public var players: MapSchema<Player> { mapOf("players") }
    }

    public final class Bot: SchemaRef, @unchecked Sendable {
        public var x: Double { view["x"] }
        public var y: Double { view["y"] }
        public var vx: Double { view["vx"] }
        public var vy: Double { view["vy"] }
        public var kind: String { view.string("kind") ?? "" }
        public var minX: Double { view["minX"] }
        public var maxX: Double { view["maxX"] }
        public var baseY: Double { view["baseY"] }
        public var phaseMs: Double { view["phaseMs"] }
        public var speed: Double { view["speed"] }
        public var lastTeleport: Double { view["lastTeleport"] }
    }

    public final class BotsState: SchemaRef, @unchecked Sendable {
        public var players: MapSchema<Player> { mapOf("players") }
        public var bots: MapSchema<Bot> { mapOf("bots") }
    }

    public final class BumpPlayer: SchemaRef, @unchecked Sendable {
        public var x: Double { view["x"] }
        public var y: Double { view["y"] }
        public var vx: Double { view["vx"] }
        public var vy: Double { view["vy"] }
        public var hue: Double { view["hue"] }
        public var bumpTicks: Double { view["bumpTicks"] }
        public var bumps: Double { view["bumps"] }
    }

    public final class BumpState: SchemaRef, @unchecked Sendable {
        public var players: MapSchema<BumpPlayer> { mapOf("players") }
        public var bots: MapSchema<Bot> { mapOf("bots") }
    }
}
