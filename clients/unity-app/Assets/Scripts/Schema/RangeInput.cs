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
	public partial class RangeInput : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public RangeInput() { }
		[Type(0, "int8")]
		public sbyte moveX = default(sbyte);

		[Type(1, "int8")]
		public sbyte moveY = default(sbyte);

		[Type(2, "float32")]
		public float aimX = default(float);

		[Type(3, "float32")]
		public float aimY = default(float);

		[Type(4, "boolean")]
		public bool fire = default(bool);

		[Type(5, "boolean")]
		public bool spread = default(bool);
	}
}
