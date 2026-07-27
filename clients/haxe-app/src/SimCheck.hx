/** Runs the shared-sim canary and exits on the failure count. */
class SimCheck {
	static function main() {
		var failed = Sim.selfcheck(Sys.println);
		Sys.println('failed = $failed');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
