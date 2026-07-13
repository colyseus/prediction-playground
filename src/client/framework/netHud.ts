import type { Room } from "@colyseus/sdk";

/**
 * Passive net readouts for the bottom bar: live RTT / jitter / patch-age of
 * the active room. READ-ONLY on purpose — latency/jitter SIMULATION belongs
 * to the SDK debug panel (the Colyseus logo panel, top-right: its menu has
 * the latency slider; `__net(delay, jitter)` is the console equivalent).
 */
export class NetHud {
  private room: Room | null = null;
  private rttEl: HTMLElement;
  private jitEl: HTMLElement;
  private ageEl: HTMLElement;
  private lastUpdate = 0;

  constructor(root: HTMLElement) {
    root.innerHTML = `
      <div class="stat"><span class="lbl">rtt</span><span class="val" data-k="rtt">—</span></div>
      <div class="stat"><span class="lbl">jitter</span><span class="val" data-k="jit">—</span></div>
      <div class="stat"><span class="lbl">patch age</span><span class="val" data-k="age">—</span></div>`;
    this.rttEl = root.querySelector('[data-k="rtt"]')!;
    this.jitEl = root.querySelector('[data-k="jit"]')!;
    this.ageEl = root.querySelector('[data-k="age"]')!;
  }

  setRoom(room: Room | null): void { this.room = room; }

  frame(now: number): void {
    if (now - this.lastUpdate < 150) return;
    this.lastUpdate = now;
    const clock = (this.room as any)?.clock;
    if (!clock) {
      this.rttEl.textContent = this.jitEl.textContent = this.ageEl.textContent = "—";
      return;
    }
    this.rttEl.textContent = `${clock.smoothedRtt().toFixed(0)} ms`;
    this.jitEl.textContent = `${clock.jitter().toFixed(0)} ms`;
    const last = clock.lastServerTime();
    this.ageEl.textContent = last > 0 ? `${Math.max(0, clock.serverNow() - last).toFixed(0)} ms` : "—";
  }
}
