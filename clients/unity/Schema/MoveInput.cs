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
	public partial class MoveInput : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public MoveInput() { }
		[Type(0, "int8")]
		public sbyte moveX = default(sbyte);

		[Type(1, "int8")]
		public sbyte moveY = default(sbyte);
	}
}
