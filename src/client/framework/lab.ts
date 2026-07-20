import type { Client, Room } from "@colyseus/sdk";
import type { WorldView } from "./draw.ts";
import type { ControlsPanel } from "./controls.ts";
import type { TelemetryHUD } from "./hud.ts";

/** Everything the shell hands a lab on mount. Controls/HUD are cleared by the
 *  shell on lab switch; the lab only builds, never tears down panel DOM. */
export interface LabContext {
  client: Client;
  canvas: HTMLCanvasElement;
  g: CanvasRenderingContext2D;
  view: WorldView;
  controls: ControlsPanel;
  hud: TelemetryHUD;
}

export interface LabInstance {
  /** The lab's room — the shell binds the Net HUD to it and leaves it on unmount. */
  room: Room<any>;
  /** Called from the shell's single rAF loop (arena already drawn). */
  frame(now: number, dtMs: number): void;
  /** Dispose Predicts, key handlers, listeners. Do NOT leave the room (shell does). */
  unmount(): void;
  /**
   * Called by the shell after the SDK auto-reconnects a dropped transport.
   * The reconnected room counts inputs from ZERO — reconcilers/sims must
   * `reset()` here, or every reconcile replays the stale pre-drop backlog.
   */
  onReconnect?(): void;
  /** Optional live telemetry for headless probes (read via window.__lab.telemetry). */
  debug?(): Record<string, unknown>;
}

export interface LabDescriptor {
  /** Stable id — doubles as the location.hash deep link. */
  id: string;
  num: number;
  title: string;
  /** One-line concept shown in the sidebar. */
  blurb: string;
  phase: 1 | 2;
  /** docs.md?raw */
  docs: string;
  /** net.ts?raw — the lab's ACTUAL executed netcode, shown in the docs panel. */
  source?: string;
  /** false = skip the docs panel's first-visit auto-expand (hero lab). */
  autoExpandDocs?: boolean;
  /** The lab draws its own background — the shell skips the shared drawArena. */
  ownArena?: boolean;
  mount(ctx: LabContext): Promise<LabInstance>;
}

/** A curriculum slot that isn't built yet — rendered dimmed in the sidebar. */
export interface PlannedLab {
  id: string;
  num: number;
  title: string;
  blurb: string;
  phase: 1 | 2;
  pending: true;
}

export type LabEntry = LabDescriptor | PlannedLab;

export function isPending(e: LabEntry): e is PlannedLab {
  return (e as PlannedLab).pending === true;
}

/** Poll for a decoded state entry (the initial full sync races the join promise). */
export function waitFor<T>(fn: () => T | undefined, timeoutMs = 5000): Promise<T> {
  return new Promise((resolve, reject) => {
    const t0 = performance.now();
    const poll = () => {
      const v = fn();
      if (v !== undefined) return resolve(v);
      if (performance.now() - t0 > timeoutMs) return reject(new Error("timed out waiting for state"));
      setTimeout(poll, 40);
    };
    poll();
  });
}
