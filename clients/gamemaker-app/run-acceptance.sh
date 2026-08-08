#!/bin/bash
# Headless acceptance run via GameMaker's Igor CLI (macOS + licence, local
# only — clone of native-sdk/platforms/gamemaker/run-tests.sh).
# Needs the playground server: `pnpm dev --host 0.0.0.0` (repo root).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo -e "\033[0;32m[ACCEPT]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; }

if ! curl -s -o /dev/null --max-time 2 http://127.0.0.1:5173; then
  fail "playground server not reachable on :5173 (pnpm dev --host 0.0.0.0)"
  exit 2
fi

# Find Igor + runtime + user dir (same discovery as the SDK's run-tests.sh)
runtime_dir=$(ls -d /Users/Shared/GameMakerStudio2/Cache/runtimes/runtime-* 2>/dev/null | sort -V | tail -1)
[[ -z "$runtime_dir" ]] && { fail "GameMaker runtime not found"; exit 1; }
igor_bin=""
for c in "$runtime_dir/bin/igor/osx/arm64/Igor" "$runtime_dir/bin/igor/osx/x86_64/Igor"; do
  [[ -x "$c" ]] && { igor_bin="$c"; break; }
done
[[ -z "$igor_bin" ]] && { fail "Igor not found"; exit 1; }
user_dir=""
for d in "$HOME/Library/Application Support/GameMakerStudio2"/*_*/; do
  [[ -f "${d}licence.plist" ]] && { user_dir="${d%/}"; break; }
done
[[ -z "$user_dir" ]] && { fail "GameMaker licence folder not found"; exit 1; }

CACHE_DIR="$SCRIPT_DIR/.accept-cache"
TEMP_DIR="$SCRIPT_DIR/.accept-temp"
mkdir -p "$CACHE_DIR" "$TEMP_DIR"
OUTPUT_FILE=$(mktemp -t colyseus_accept)

log "Building and running acceptance..."
COLYSEUS_ACCEPTANCE=1 DOTNET_SYSTEM_NET_DISABLEIPV6=1 "$igor_bin" \
    -j=8 -r=VM \
    -project="$SCRIPT_DIR/PredictionPlayground.yyp" \
    -runtimePath="$runtime_dir" \
    -user="$user_dir" \
    -cache="$CACHE_DIR" \
    -temp="$TEMP_DIR" \
    -- Mac Run > "$OUTPUT_FILE" 2>&1 &
IGOR_PID=$!

TIMEOUT=180
ELAPSED=0
while kill -0 "$IGOR_PID" 2>/dev/null; do
  if grep -q "ACCEPTANCE FINISHED" "$OUTPUT_FILE" 2>/dev/null; then
    sleep 1
    pkill -P "$IGOR_PID" 2>/dev/null || true
    kill "$IGOR_PID" 2>/dev/null || true
    break
  fi
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    fail "timed out"
    pkill -P "$IGOR_PID" 2>/dev/null || true
    kill "$IGOR_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

grep "ACCEPT " "$OUTPUT_FILE" || true
RESULT=$(grep "ACCEPTANCE FINISHED" "$OUTPUT_FILE" | tail -1)
echo "$RESULT"
if echo "$RESULT" | grep -qE "FINISHED ([0-9]+)/\1$"; then
  log "acceptance passed"
  rm -f "$OUTPUT_FILE"
  exit 0
fi
fail "acceptance failed — full log: $OUTPUT_FILE"
exit 1
