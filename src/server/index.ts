import {
  createEndpoint,
  createRouter,
  defineRoom,
  defineServer,
  monitor,
  playground,
} from "colyseus";
import { MoveRoom } from "./rooms/MoveRoom.ts";
import { BotsRoom } from "./rooms/BotsRoom.ts";
import { RangeRoom } from "./rooms/RangeRoom.ts";
import { BumpRoom } from "./rooms/BumpRoom.ts";
import { GoalRoom } from "./rooms/GoalRoom.ts";
import { ProjectileRoom } from "./rooms/ProjectileRoom.ts";
import { HockeyRoom } from "./rooms/HockeyRoom.ts";

export const server = defineServer({
  rooms: {
    "lab-move": defineRoom(MoveRoom),
    "lab-bots": defineRoom(BotsRoom),
    "lab-range": defineRoom(RangeRoom),
    "lab-bump": defineRoom(BumpRoom),
    "lab-goal": defineRoom(GoalRoom),
    "lab-projectile": defineRoom(ProjectileRoom),
    "lab-hockey": defineRoom(HockeyRoom),
  },

  express: (app) => {
    app.use("/playground", playground());
    app.use("/monitor", monitor());
  },

  routes: createRouter({
    health: createEndpoint("/health", { method: "GET" }, async () => {
      return { ok: true, time: Date.now() };
    }),
  }),
});
