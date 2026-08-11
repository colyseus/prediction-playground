#!/bin/bash
# Acceptance checks for the Flutter playground client.
#
# Runs the real app code against the live playground server on macOS.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${PLAYGROUND_PORT:-5173}"

if ! curl -sf --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "The playground server is not answering on :$PORT."
  echo
  echo "  cd $(cd "$SCRIPT_DIR/../.." && pwd)"
  echo "  pnpm dev --host 0.0.0.0"
  echo
  echo "(--host is required: without it Vite binds IPv6 loopback only and"
  echo " native clients cannot reach it.)"
  exit 1
fi

cd "$SCRIPT_DIR"
# Runs on the host VM against the real dylib: same code the app runs, but it
# doesn't need a window, and it doesn't hang on device teardown.
DYLIB="$(cd "$SCRIPT_DIR/../../../../native-sdk/platforms/flutter" && pwd)/zig-out/lib/macos/arm64/libcolyseus_flutter.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "Native library missing. Build it first:"
  echo "  cd native-sdk/platforms/flutter && ./build.sh"
  exit 1
fi

exec env COLYSEUS_LIBRARY_PATH="$DYLIB" \
  flutter test test/acceptance_test.dart --concurrency=1 "$@"
