#!/usr/bin/env bash
# Build and deploy this demo's game server to the shared demos box.
#   https://demos.colyseus.cloud/prediction
#
# One box, one nginx vhost, seven independent repos. Each demo owns a decade of
# ports so nginx can route /<slug>/<port>/ at an exact socket. Only the constants
# below differ between repos.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ── per-demo constants ────────────────────────────────────────────────
SLUG=prediction
APP=prediction
BASE=63          # NODE_APP_INSTANCE base -> first socket 2567+BASE (2630)
INSTANCES=1           # MUST match ecosystem.config.cjs
RESERVE=10           # size of this demo's port decade (2630-2639), for stale-app cleanup
EXTRA_DIRS=()           # no runtime disk reads
# ──────────────────────────────────────────────────────────────────────

HOST="${DEPLOY_HOST:-deploy@91.99.200.149}"
APP_DIR="/home/deploy/apps/$APP"
ENDPOINT="https://demos.colyseus.cloud/$SLUG"
SRC_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

npm run build
[ -f dist/server/server.mjs ] || { echo "error: dist/server/server.mjs missing after build" >&2; exit 1; }

echo "--- syncing app"
ssh "$HOST" "mkdir -p $APP_DIR/dist"
rsync -az --delete --exclude .DS_Store dist/server/ "$HOST:apps/$APP/dist/server/"
rsync -az package.json pnpm-lock.yaml ecosystem.config.cjs "$HOST:apps/$APP/"
# not `[ -f .env ] && rsync`: that returns 1 when there is no .env, which under
# `set -e` would abort the deploy of every demo that doesn't have one.
if [ -f .env ]; then rsync -az .env "$HOST:apps/$APP/"; fi
for d in "${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}"; do
  ssh "$HOST" "mkdir -p $APP_DIR/$d"
  rsync -az --delete --exclude .DS_Store "$d/" "$HOST:apps/$APP/$d/"
done

echo "--- installing runtime deps"
ssh "$HOST" "cd $APP_DIR && pnpm install --prod --frozen-lockfile --ignore-scripts"

echo "--- pm2: $SLUG-0..$((INSTANCES-1))  (sockets $((2567+BASE))..$((2567+BASE+INSTANCES-1)))"
# NOT colyseus-post-deploy: it lists ALL pm2 apps on the box, writes every demo's
# sockets into one shared nginx upstream file, and runs `pm2 delete all` whenever
# apps[0].pm_cwd != cwd -- i.e. it would take down the other six demos.
ssh "$HOST" "set -e
  cd $APP_DIR
  for i in \$(seq $INSTANCES $((RESERVE-1))); do pm2 delete ${SLUG}-\$i >/dev/null 2>&1 || true; done
  pm2 startOrReload ecosystem.config.cjs --update-env
  pm2 save"

echo "--- publishing nginx upstream list"
ssh "$HOST" "set -e
  f=/etc/nginx/colyseus_upstreams/prediction.conf
  : > \$f.tmp
  for i in \$(seq 0 $((INSTANCES-1))); do
    echo \"server unix:/run/colyseus/\$((2567 + $BASE + i)).sock;\" >> \$f.tmp
  done
  mv \$f.tmp \$f"   # atomic; fswatch on the dir runs `nginx -t && systemctl reload nginx`

echo "--- health check"
for _ in $(seq 1 30); do
  curl -fsS --max-time 5 "$ENDPOINT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 5 "$ENDPOINT/health" || { echo "error: $ENDPOINT/health never came up" >&2; exit 1; }
echo

echo "Deployed $SLUG@$SRC_SHA -> $ENDPOINT"
