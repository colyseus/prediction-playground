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
	public partial class Bot : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public Bot() { }
		[Type(0, "number")]
		public float x = default(float);

		[Type(1, "number")]
		public float y = default(float);

		[Type(2, "number")]
		public float vx = default(float);

		[Type(3, "number")]
		public float vy = default(float);

		[Type(4, "string")]
		public string kind = default(string);

		[Type(5, "number")]
		public float minX = default(float);

		[Type(6, "number")]
		public float maxX = default(float);

		[Type(7, "number")]
		public float baseY = default(float);

		[Type(8, "number")]
		public float phaseMs = default(float);

		[Type(9, "number")]
		public float speed = default(float);

		[Type(10, "number")]
		public float lastTeleport = default(float);
	}
}
