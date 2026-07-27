/**
 * What the shell needs from a lab. The shell owns the room and hands it over;
 * labs never join and never leave.
 */
interface Lab {
	var id(default, null): String;
	var num(default, null): Int;
	var title(default, null): String;
	var blurb(default, null): String;
	/** The lab paints its own background, so the shell skips the shared arena. */
	var ownArena(default, null): Bool;
	/** Which room to join. */
	var roomName(default, null): String;
	/**
	 * Join this lab's room. The lab does it rather than the shell because the
	 * SDK's join is generic over the state class and only the lab knows that
	 * type — routing it through Dynamic instead costs the static typing AND
	 * trips neko's exact-arity rule for dynamic calls.
	 */
	function join(app: App, cb: (Dynamic, Dynamic) -> Void): Void;

	/** What must be decoded before this lab can wire up — the web build's waitFor. */
	function ready(room: Dynamic): Bool;
	/** Wire up against a joined, decoded room. */
	function mount(app: App, room: Dynamic): Bool;
	/** Send inputs, advance prediction. */
	function frame(app: App, now: Float, dtMs: Float): Void;
	/** Draw the arena overlay and the HUD. */
	function render(g: Gfx): Void;
	/** Dispose predicts/reconcilers. Do NOT leave the room (the shell does). */
	function unmount(): Void;
	/**
	 * After the SDK auto-reconnects a dropped transport. The reconnected room
	 * counts inputs from ZERO — reconcilers MUST reset here, or every reconcile
	 * replays the stale pre-drop backlog.
	 */
	function onReconnect(): Void;
	/** The joined room, for the shell to leave. */
	function roomRef(): Dynamic;
}
