// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class ProjectileState extends Schema {
	@:type("map", Player)
	public var players: MapSchema<Player> = new MapSchema<Player>();

	@:type("map", Projectile)
	public var projectiles: MapSchema<Projectile> = new MapSchema<Projectile>();

}
