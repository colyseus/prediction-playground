import {
  createEndpoint,
  createRouter,
  defineRoom,
  defineServer,
  monitor,
  playground,
  RedisDriver,
  RedisPresence,
} from "colyseus";
import { MoveRoom } from "./rooms/MoveRoom.ts";
import { BotsRoom } from "./rooms/BotsRoom.ts";
import { RangeRoom } from "./rooms/RangeRoom.ts";
import { BumpRoom } from "./rooms/BumpRoom.ts";
import { GoalRoom } from "./rooms/GoalRoom.ts";
import { ProjectileRoom } from "./rooms/ProjectileRoom.ts";
import { HockeyRoom } from "./rooms/HockeyRoom.ts";

// Production shares one box with the other demos, routed by path prefix
// (demos.colyseus.cloud/prediction). Matchmaking state must live in Redis — the
// built-in presence/driver are process-local — on a per-demo DB index, since
// RedisDriver writes to a hardcoded `roomcaches` key that would otherwise be shared.
// Imported from "colyseus" on purpose: @colyseus/core lists the redis packages as
// devDependencies and silently falls back to LocalPresence when the import fails.
const production = process.env.COLYSEUS_CLOUD !== undefined;
const port = 2567 + Number(process.env.NODE_APP_INSTANCE || "0");
// Set per-process in ecosystem.config.cjs. Must carry the path prefix: once a seat
// reservation has a publicAddress the SDK drops its own pathname, and publicAddress
// can't be disabled under COLYSEUS_CLOUD (it falls back to SUBDOMAIN.SERVER_NAME).
const publicAddressBase = process.env.PUBLIC_ADDRESS_BASE ?? "demos.colyseus.cloud/prediction";

export const server = defineServer({
  ...(production && {
    presence: new RedisPresence(process.env.REDIS_URI),
    driver: new RedisDriver(process.env.REDIS_URI),
    publicAddress: `${publicAddressBase}/${port}`,
  }),

  rooms: {
    "lab-move": defineRoom(MoveRoom),
    "lab-bots": defineRoom(BotsRoom),
    "lab-range": defineRoom(RangeRoom),
    "lab-bump": defineRoom(BumpRoom),
    "lab-goal": defineRoom(GoalRoom),
    "lab-projectile": defineRoom(ProjectileRoom),
    "lab-hockey": defineRoom(HockeyRoom),
  },

  // Dev only: monitor() has no production guard and exposes
  // /monitor/api/room/call -> matchMaker.remoteRoomCall(roomId, method, args).
  express: (app) => {
    if (!production) {
      app.use("/playground", playground());
      app.use("/monitor", monitor());
    }
  },

  routes: createRouter({
    health: createEndpoint("/health", { method: "GET" }, async () => {
      return { ok: true, time: Date.now() };
    }),
  }),
});
