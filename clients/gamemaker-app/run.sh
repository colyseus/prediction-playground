#!/bin/bash
# Build + launch the playground windowed via GameMaker's Igor CLI.
# Needs the playground server: `pnpm dev --host 0.0.0.0` (repo root).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

./link-sdk.sh --check >/dev/null || { echo "[run] SDK not linked: run ./link-sdk.sh" >&2; exit 1; }

EP="${COLYSEUS_PLAYGROUND_ENDPOINT:-http://127.0.0.1:5173}"
export COLYSEUS_PLAYGROUND_ENDPOINT="$EP"
if ! curl -s -o /dev/null --max-time 2 "$EP"; then
  echo "[run] playground server not reachable at $EP (pnpm dev --host 0.0.0.0)"
  exit 2
fi

source tools/igor-env.sh

mkdir -p .accept-cache .accept-temp
echo "[run] building + launching (close the window or Cmd+Q to quit)..."
DOTNET_SYSTEM_NET_DISABLEIPV6=1 "$igor_bin" \
    -j=8 -r=VM \
    -project="$SCRIPT_DIR/PredictionPlayground.yyp" \
    -runtimePath="$runtime_dir" \
    -user="$user_dir" \
    -cache="$SCRIPT_DIR/.accept-cache" \
    -temp="$SCRIPT_DIR/.accept-temp" \
    -- Mac Run
