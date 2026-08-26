// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.19
// 

import Colyseus

public enum LabMove {}

extension LabMove {
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
}
