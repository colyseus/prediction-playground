/**
 * Lab 00 runs Lab 03's netcode VERBATIM — re-exported, not copied.
 *
 * The split screen is a render-layer choice, not a different protocol: both
 * lanes draw the same entity in the same `lab-move` room. The top lane reads
 * the raw decoded server state (what Lab 01 draws); the bottom lane reads the
 * reconciler's predicted pose (what Lab 03 draws). Prediction is a client-side
 * choice over the same authority.
 */
export { connect, makeReconciler, PREDICTED_FIELDS } from "../03-reconcile/net.ts";
