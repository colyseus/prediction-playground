// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

package lab;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.*;

class RangeInput extends Schema {
	@:type("int8")
	public var moveX: Int = 0;

	@:type("int8")
	public var moveY: Int = 0;

	@:type("float32")
	public var aimX: Float = 0;

	@:type("float32")
	public var aimY: Float = 0;

	@:type("boolean")
	public var fire: Bool = false;

	@:type("boolean")
	public var spread: Bool = false;

}
