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
	public partial class MoveState : Schema {
#if UNITY_5_3_OR_NEWER
[Preserve]
#endif
public MoveState() { }
		[Type(0, "map", typeof(MapSchema<Player>))]
		public MapSchema<Player> players = null;
	}
}
