// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class Bot extends Schema {
	@:type("number")
	public var x: Dynamic = 0;

	@:type("number")
	public var y: Dynamic = 0;

	@:type("number")
	public var vx: Dynamic = 0;

	@:type("number")
	public var vy: Dynamic = 0;

	@:type("string")
	public var kind: String = "";

	@:type("number")
	public var minX: Dynamic = 0;

	@:type("number")
	public var maxX: Dynamic = 0;

	@:type("number")
	public var baseY: Dynamic = 0;

	@:type("number")
	public var phaseMs: Dynamic = 0;

	@:type("number")
	public var speed: Dynamic = 0;

	@:type("number")
	public var lastTeleport: Dynamic = 0;

}
