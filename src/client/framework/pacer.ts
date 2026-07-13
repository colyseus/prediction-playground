/**
 * Fixed-step accumulator for labs WITHOUT a reconciler (`predict.tick()` only
 * paces once a reconciler adopts the fixed step; a prediction-free client
 * still has to send one input per server tick).
 */
export class FixedStepPacer {
  private acc = 0;
  private last = -1;

  constructor(private stepMs: number) {}

  steps(now: number): number {
    if (this.last < 0) { this.last = now; return 0; }
    this.acc += now - this.last;
    this.last = now;
    let n = Math.floor(this.acc / this.stepMs);
    if (n > 5) { n = 5; this.acc = 0; }   // hitch (tab switch): drop the backlog
    else this.acc -= n * this.stepMs;
    return n;
  }

  reset(): void { this.acc = 0; this.last = -1; }
}
