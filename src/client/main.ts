// The debug module is imported UNCONDITIONALLY (unlike the game demos):
// inspection is this app's product — the panel + network simulator must
// survive a deployed docs build.
import "@colyseus/sdk/debug";
import { Client } from "@colyseus/sdk";
import { LABS } from "./framework/registry.ts";
import { isPending, type LabDescriptor, type LabInstance, type LabContext } from "./framework/lab.ts";
import { WorldView, drawArena } from "./framework/draw.ts";
import { ControlsPanel } from "./framework/controls.ts";
import { TelemetryHUD } from "./framework/hud.ts";
import { NetHud } from "./framework/netHud.ts";
import { DocsPanel } from "./framework/docsPanel.ts";

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const g = canvas.getContext("2d")!;
const stageMsgEl = document.getElementById("stage-msg")!;
const labSelectEl = document.getElementById("lab-select") as HTMLSelectElement;

const client = new Client(
  `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`,
);
const view = new WorldView();
const controls = new ControlsPanel(document.getElementById("controls")!);
const hud = new TelemetryHUD(document.getElementById("hud")!);
const netHud = new NetHud(document.getElementById("nethud")!);
const docsPanel = new DocsPanel();

const ctx: LabContext = { client, canvas, g, view, controls, hud };

let active: LabInstance | null = null;
let activeId: string | null = null;
let mountToken = 0;

function stageMsg(text: string | null): void {
  stageMsgEl.style.display = text ? "flex" : "none";
  stageMsgEl.textContent = text ?? "";
}

// ---- Lab navigation ----------------------------------------------------------

// A native <select> in the floating top bar (grouped by phase). The top bar is
// CENTERED so it never mixes with the SDK debug UI — Predict cards dock in the
// viewport's top-left, the room panel in the top-right.
{
  let group: HTMLOptGroupElement | null = null;
  let lastPhase = 0;
  for (const entry of LABS) {
    if (entry.phase !== lastPhase) {
      lastPhase = entry.phase;
      group = document.createElement("optgroup");
      group.label = entry.phase === 1 ? "Fundamentals" : "Advanced";
      labSelectEl.appendChild(group);
    }
    const opt = document.createElement("option");
    opt.value = entry.id;
    opt.textContent = `${String(entry.num).padStart(2, "0")} · ${entry.title}` + (isPending(entry) ? " (soon)" : "");
    opt.title = entry.blurb;
    opt.disabled = isPending(entry);
    group!.appendChild(opt);
  }
  labSelectEl.addEventListener("change", () => { location.hash = labSelectEl.value; });
}

document.getElementById("about-btn")!.addEventListener("click", () => docsPanel.toggle());

function highlight(id: string | null): void {
  if (id) labSelectEl.value = id;
}

// ---- Lab lifecycle ----------------------------------------------------------

async function activate(desc: LabDescriptor): Promise<void> {
  if (desc.id === activeId) return;
  const token = ++mountToken;

  if (active) {
    const prev = active;
    active = null;
    netHud.setRoom(null);
    try { prev.unmount(); } catch (e) { console.warn("unmount failed", e); }
    prev.room.leave().catch(() => {});
  }
  activeId = desc.id;
  highlight(desc.id);
  controls.clear();
  hud.clear();
  docsPanel.set(desc.id, `${String(desc.num).padStart(2, "0")} · ${desc.title}`, desc.docs, desc.source);
  stageMsg("Connecting…");

  try {
    const inst = await desc.mount(ctx);
    if (token !== mountToken) {
      // A newer lab switch raced this mount — discard it.
      try { inst.unmount(); } catch {}
      inst.room.leave().catch(() => {});
      return;
    }
    active = inst;
    netHud.setRoom(inst.room);
    stageMsg(null);

    // Connection lifecycle: the debug panel's "Drop" button (or a real blip)
    // closes the transport; the SDK auto-reconnects while the server holds the
    // seat (each room's onDrop → allowReconnection). The lab re-seeds its
    // predictor in onReconnect — the fresh connection counts inputs from zero.
    inst.room.onDrop(() => {
      if (active === inst) stageMsg("Connection dropped — reconnecting…");
    });
    inst.room.onReconnect(() => {
      if (active !== inst) return;
      stageMsg(null);
      inst.onReconnect?.();
    });
    // Terminal leave (reconnect gave up / the room closed): rejoin fresh.
    inst.room.onLeave(() => {
      if (active !== inst) return;   // deliberate teardown already nulled it
      active = null;
      activeId = null;
      netHud.setRoom(null);
      try { inst.unmount(); } catch {}
      stageMsg("Disconnected — rejoining…");
      setTimeout(() => void activate(labFromHash()), 1200);
    });

    (window as any).__lab = {
      id: desc.id,
      room: inst.room,
      get telemetry() { return inst.debug?.(); },
    };
  } catch (e) {
    if (token === mountToken) {
      stageMsg(`Failed to start "${desc.title}"\n${(e as Error).message}`);
      console.error(e);
    }
  }
}

function labFromHash(): LabDescriptor {
  const id = location.hash.replace(/^#/, "");
  const entry = LABS.find((l) => l.id === id && !isPending(l)) as LabDescriptor | undefined;
  return entry ?? (LABS.find((l) => !isPending(l)) as LabDescriptor);
}

window.addEventListener("hashchange", () => void activate(labFromHash()));

// ---- Frame loop --------------------------------------------------------------

let lastNow = 0;

function frame(now: number): void {
  requestAnimationFrame(frame);
  const dtMs = lastNow ? Math.min(100, now - lastNow) : 16.7;
  lastNow = now;

  // Resize to CSS box × devicePixelRatio; draw in CSS px.
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.clientWidth, cssH = canvas.clientHeight;
  if (canvas.width !== Math.round(cssW * dpr) || canvas.height !== Math.round(cssH * dpr)) {
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
  }
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, cssW, cssH);
  view.fit(cssW, cssH);

  const dbg = (window as any);
  dbg.__shellFrames = (dbg.__shellFrames ?? 0) + 1;
  dbg.__shellActive = !!active;

  if (active) {
    drawArena(g, view);
    try { active.frame(now, dtMs); } catch (e) { console.error(e); }
  }
  netHud.frame(now);
}

requestAnimationFrame(frame);
void activate(labFromHash());
