#!/bin/bash
# Build + launch the playground windowed via GameMaker's Igor CLI.
# Needs the playground server: `pnpm dev --host 0.0.0.0` (repo root).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! curl -s -o /dev/null --max-time 2 http://127.0.0.1:5173; then
  echo "[run] playground server not reachable on :5173 (pnpm dev --host 0.0.0.0)"
  exit 2
fi

runtime_dir=$(ls -d /Users/Shared/GameMakerStudio2/Cache/runtimes/runtime-* 2>/dev/null | sort -V | tail -1)
[[ -z "$runtime_dir" ]] && { echo "[run] GameMaker runtime not found"; exit 1; }
igor_bin=""
for c in "$runtime_dir/bin/igor/osx/arm64/Igor" "$runtime_dir/bin/igor/osx/x86_64/Igor"; do
  [[ -x "$c" ]] && { igor_bin="$c"; break; }
done
[[ -z "$igor_bin" ]] && { echo "[run] Igor not found"; exit 1; }
user_dir=""
for d in "$HOME/Library/Application Support/GameMakerStudio2"/*_*/; do
  [[ -f "${d}licence.plist" ]] && { user_dir="${d%/}"; break; }
done
[[ -z "$user_dir" ]] && { echo "[run] GameMaker licence folder not found"; exit 1; }

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
