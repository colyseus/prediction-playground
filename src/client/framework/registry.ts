import type { LabEntry } from "./lab.ts";
import { lab as split } from "../labs/00-split/index.ts";
import { lab as feelTheLag } from "../labs/01-feel-the-lag/index.ts";
import { lab as clocks } from "../labs/02-clocks/index.ts";
import { lab as reconcile } from "../labs/03-reconcile/index.ts";
import { lab as interpModes } from "../labs/04-interp-modes/index.ts";
import { lab as deadReckoning } from "../labs/05-dead-reckoning/index.ts";
import { lab as lagComp } from "../labs/06-lag-comp/index.ts";
import { lab as wysiwyg } from "../labs/07-wysiwyg/index.ts";
import { lab as optimisticEvents } from "../labs/08-optimistic-events/index.ts";
import { lab as predictedSpawns } from "../labs/09-predicted-spawns/index.ts";
import { lab as compositeSim } from "../labs/10-composite-sim/index.ts";
import { lab as deterministicRng } from "../labs/11-deterministic-rng/index.ts";

/** Ordered curriculum. Entries without a mount are planned-but-unbuilt (dimmed). */
export const LABS: LabEntry[] = [
  split,
  feelTheLag,
  clocks,
  reconcile,
  interpModes,
  deadReckoning,
  lagComp,
  wysiwyg,
  optimisticEvents,
  predictedSpawns,
  compositeSim,
  deterministicRng,
];
