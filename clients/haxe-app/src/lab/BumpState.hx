// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.8
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class BumpState extends Schema {
	@:type("map", BumpPlayer)
	public var players: MapSchema<BumpPlayer> = new MapSchema<BumpPlayer>();

	@:type("map", Bot)
	public var bots: MapSchema<Bot> = new MapSchema<Bot>();

}
