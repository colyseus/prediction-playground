// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class GoalState extends Schema {
	@:type("map", GoalPlayer)
	public var players: MapSchema<GoalPlayer> = new MapSchema<GoalPlayer>();

	@:type("uint8")
	public var denyRate: UInt = 0;

}
