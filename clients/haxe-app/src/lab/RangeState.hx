// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class RangeState extends Schema {
	@:type("map", RangePlayer)
	public var players: MapSchema<RangePlayer> = new MapSchema<RangePlayer>();

	@:type("map", Bot)
	public var bots: MapSchema<Bot> = new MapSchema<Bot>();

	@:type("boolean")
	public var lagComp: Bool = false;

	@:type("uint32")
	public var salt: UInt = 0;

}
