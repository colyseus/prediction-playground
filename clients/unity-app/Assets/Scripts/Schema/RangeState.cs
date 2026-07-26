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
	public partial class RangeState : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public RangeState() { }
		[Type(0, "map", typeof(MapSchema<RangePlayer>))]
		public MapSchema<RangePlayer> players = null;

		[Type(1, "map", typeof(MapSchema<Bot>))]
		public MapSchema<Bot> bots = null;

		[Type(2, "boolean")]
		public bool lagComp = default(bool);

		[Type(3, "uint32")]
		public uint salt = default(uint);
	}
}
