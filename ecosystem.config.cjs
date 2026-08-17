// PM2 apps for the shared demos box (deploy@91.99.200.149).
// One pm2 app PER PROCESS with a fixed NODE_APP_INSTANCE: @colyseus/tools binds
// /run/colyseus/<2567 + NODE_APP_INSTANCE>.sock, and nginx routes
// /prediction/<port>/ straight at that socket.
//
// NOT `instances: N` + `increment_var`: pm2's reload path re-applies the config
// env to every instance (God/ActionMethods.js), collapsing them all onto the base
// socket. `instance_var` is redirected so pm2's own auto-assigned index can never
// overwrite NODE_APP_INSTANCE either.
const SLUG      = 'prediction';
const BASE      = 63;    // first socket 2567 + 63 = 2630
const INSTANCES = 1;     // reserved decade 2630-2639
const REDIS_DB  = 7;     // RedisDriver's `roomcaches` key is hardcoded, so demos need separate DBs

module.exports = {
  apps: Array.from({ length: INSTANCES }, (_, i) => ({
    name: `${SLUG}-${i}`,
    script: 'dist/server/server.mjs',
    instances: 1,
    exec_mode: 'fork',
    instance_var: 'PM2_INSTANCE_INDEX', // keep pm2's index off NODE_APP_INSTANCE
    wait_ready: true,                   // @colyseus/tools listen() emits process.send('ready')
    listen_timeout: 20000,
    kill_timeout: 15000,                // SIGINT -> graceful room dispose
    max_memory_restart: '400M',
    autorestart: true,
    time: true,
    watch: false,
    env: {
      NODE_ENV: 'production',
      NODE_APP_INSTANCE: String(BASE + i),
      REDIS_URI: `redis://127.0.0.1:6379/${REDIS_DB}`,
      PUBLIC_ADDRESS_BASE: `demos.colyseus.cloud/${SLUG}`,
    },
  })),
};
