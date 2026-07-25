// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 

using Colyseus.Schema;
#if UNITY_5_3_OR_NEWER
using UnityEngine.Scripting;
#endif

namespace PredictProbe.LabSchema {
	public partial class RangePlayer : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public RangePlayer() { }
		[Type(0, "number")]
		public float x = default(float);

		[Type(1, "number")]
		public float y = default(float);

		[Type(2, "number")]
		public float vx = default(float);

		[Type(3, "number")]
		public float vy = default(float);

		[Type(4, "uint8")]
		public byte hue = default(byte);

		[Type(5, "uint16")]
		public ushort shots = default(ushort);

		[Type(6, "uint16")]
		public ushort hits = default(ushort);
	}
}
