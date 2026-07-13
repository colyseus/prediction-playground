import { Room, type Client, type StepContext } from "@colyseus/core";
import { BotsState, Bot, Player, MoveInput } from "../schema/bots.ts";
import { stepEntity } from "../../shared/movement.ts";
import { stepBot, WANDER_TURN_MS, type BotKind } from "../../shared/movers.ts";
import { mulberry32 } from "../../shared/random.ts";
import { TICK_HZ, ARENA_W, ARENA_H } from "../../shared/constants.ts";

const KINDS: ReadonlySet<string> = new Set(["patrol", "circle", "wander", "teleport"]);

/**
 * One pattern bot + WASD players. Serves Labs 04 (interpolation modes) and
 * 05 (dead reckoning). The bot advances through the SHARED stepBot each tick;
 * "wander" additionally re-rolls its heading here with a server-side seeded
 * RNG — the part dead reckoning cannot predict, by design.
 */
export class BotsRoom extends Room<{ state: BotsState; input: MoveInput }> {
  state = new BotsState();
  maxClients = 8;

  inputs = this.defineInput(MoveInput, {
    bufferMaxSize: 64,
    sanitize: { moveX: [-1, 1], moveY: [-1, 1] },
  });

  private joinCount = 0;
  private nextTurnAt = 0;
  private rng = mulberry32(0xB07B07);

  messages = {
    /** Switch the bot's movement pattern (room-wide — labs note this). */
    pattern: (_client: Client, msg: unknown) => {
      const kind = (msg as { kind?: string })?.kind ?? "";
      if (!KINDS.has(kind)) return;
      const bot = this.state.bots.get("bot1");
      if (!bot) return;
      this.resetBot(bot, kind as BotKind);
    },
  };

  onCreate() {
    const bot = new Bot({
      x: 50, y: 18, vx: 0, vy: 0, kind: "patrol",
      minX: 22, maxX: 78, baseY: 18, phaseMs: 0, speed: 18,
      lastTeleport: 0,
    });
    this.resetBot(bot, "patrol");
    this.state.bots.set("bot1", bot);

    this.setFixedTimestep((ctx) => this.step(ctx), TICK_HZ);
  }

  onJoin(client: Client) {
    const n = this.joinCount++;
    this.state.players.set(client.sessionId, new Player({
      x: ARENA_W / 2 + Math.cos(n * 2.399963) * 12,
      y: ARENA_H * 0.72 + Math.sin(n * 2.399963) * 6,
      vx: 0, vy: 0,
      hue: (n * 67) % 256,
    }));
  }

  onDrop(client: Client) {
    // Hold the seat through a transport drop (the debug panel's "Drop" button,
    // a network blip): the SDK auto-reconnects and the lab re-seeds its
    // predictor in room.onReconnect.
    this.allowReconnection(client, 10);
  }

  onLeave(client: Client) {
    this.state.players.delete(client.sessionId);
  }

  private resetBot(bot: Bot, kind: BotKind): void {
    bot.kind = kind;
    bot.x = (bot.minX + bot.maxX) / 2;
    bot.y = bot.baseY;
    bot.vx = bot.speed;
    bot.vy = 0;
    bot.phaseMs = 0;
    bot.lastTeleport = kind === "teleport" ? this.clock.elapsedTime : 0;
    this.nextTurnAt = 0;
  }

  private step(ctx: StepContext) {
    for (const [sid, p] of this.state.players) {
      const channel = this.inputs.get(sid);
      if (!channel) continue;
      for (const inp of channel) stepEntity(p, inp, ctx.dt);
    }

    const elapsed = this.clock.elapsedTime;
    for (const [, bot] of this.state.bots) {
      if (bot.kind === "wander" && elapsed >= this.nextTurnAt) {
        // Heading changes are a server-side secret: the client's dead
        // reckoning extrapolates straight through them and gets corrected.
        const a = this.rng() * Math.PI * 2;
        bot.vx = Math.cos(a) * bot.speed;
        bot.vy = Math.sin(a) * bot.speed;
        this.nextTurnAt = elapsed + WANDER_TURN_MS;
      }
      stepBot(bot, ctx.dt, elapsed);
    }
  }
}
