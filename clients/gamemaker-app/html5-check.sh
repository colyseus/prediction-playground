#!/bin/bash
# HTML5 gate: build the export with Igor, refuse the emitter's dead-function
# stubs, then boot it in a headless browser and require a real join.
# Needs the playground server (pnpm dev --host 0.0.0.0) and a macOS licence.
#
#   ./html5-check.sh             against http://127.0.0.1:5173
#   COLYSEUS_PLAYGROUND_ENDPOINT=http://host:port ./html5-check.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo -e "\033[0;32m[HTML5]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; }

./link-sdk.sh --check >/dev/null || { fail "SDK not linked: run ./link-sdk.sh"; exit 1; }
EP="${COLYSEUS_PLAYGROUND_ENDPOINT:-http://127.0.0.1:5173}"
if ! curl -s -o /dev/null --max-time 2 "$EP"; then
  fail "playground server not reachable at $EP (pnpm dev --host 0.0.0.0)"
  exit 2
fi
source tools/igor-env.sh

OUT="$SCRIPT_DIR/output/html5"
rm -rf "$OUT"
mkdir -p .html5-cache .html5-temp
BLOG=$(mktemp -t pt_html5)
log "building HTML5 (runtime=$(basename "$runtime_dir"))"
# `folder` is lowercase for this target, and only --tf names the destination
if ! DOTNET_SYSTEM_NET_DISABLEIPV6=1 "$igor_bin" -j=8 -r=VM \
      -project="$SCRIPT_DIR/PredictionPlayground.yyp" -runtimePath="$runtime_dir" -user="$user_dir" \
      -cache="$SCRIPT_DIR/.html5-cache" -temp="$SCRIPT_DIR/.html5-temp" \
      --tf="$OUT" -- HTML5 folder > "$BLOG" 2>&1; then
  fail "HTML5 build failed, log: $BLOG"; tail -30 "$BLOG"; exit 1
fi
# The emitter writes a syntactically invalid `function name{}` stub for any
# function nothing references, and one stub breaks the whole page.
if grep -qE 'function [A-Za-z_0-9]+\{\}' "$OUT/html5game/PredictionPlayground.js"; then
  fail "emitter stubbed an unreferenced function:"
  grep -oE 'function [A-Za-z_0-9]+\{\}' "$OUT/html5game/PredictionPlayground.js" | sort -u | head
  exit 1
fi
log "compile gate passed; booting in a browser"
exec node html5-check.mjs "$OUT" "$EP"
