#!/usr/bin/env bash
# Build the raylib playground for the web and serve it.
#
#   ./run-web.sh            debug-ish (-O1) build -> http://localhost:8061
#
# The chain, in order:
#   1. the SDK compiled to wasm static libs (native-sdk root zig build —
#      callback-variant web transport + emscripten_fetch http)
#   2. raylib's prebuilt webassembly release (auto-downloaded once)
#   3. one emcc link of the unity-build main.c against both
#   4. python http.server; the app connects to ws://127.0.0.1:5173
#
# emcc comes from the zig-fetched emsdk (the same one the Godot platform
# build installs); its tooling needs python >= 3.10.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(cd "$HERE/../../../native-sdk" && pwd)"
PORT="${PORT:-8061}"
RAYLIB_VER="6.0"

log() { echo "[run-web] $*"; }
die() { echo "[run-web] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------------ emcc
EMCC="${EMCC:-$(ls "$HOME"/.cache/zig/p/*/upstream/emscripten/emcc 2>/dev/null | head -1)}"
[[ -n "$EMCC" && -x "$EMCC" ]] || die "emcc not found in the zig package cache.
  It is fetched by the Godot platform build:
    cd $SDK/platforms/godot && zig build -Dtarget=wasm32-emscripten
  (or set EMCC=/path/to/emcc)"
EMSDK_DIR="$(dirname "$EMCC")"
if [[ -z "${EMSDK_PYTHON:-}" && -x /opt/homebrew/bin/python3.12 ]]; then
    export EMSDK_PYTHON=/opt/homebrew/bin/python3.12
fi

# ---------------------------------------------------------------- raylib
RAYLIB="$HERE/build/raylib-${RAYLIB_VER}_webassembly"
if [[ ! -f "$RAYLIB/lib/libraylib.web.a" ]]; then
    URL="https://github.com/raysan5/raylib/releases/download/${RAYLIB_VER}/raylib-${RAYLIB_VER}_webassembly.zip"
    log "fetching prebuilt raylib wasm: $URL"
    mkdir -p "$HERE/build"
    curl -sL --max-time 300 -o "$HERE/build/raylib-web.zip" "$URL" \
        || die "download failed — grab $URL and unzip into $HERE/build/"
    (cd "$HERE/build" && unzip -q -o raylib-web.zip)
    [[ -f "$RAYLIB/lib/libraylib.web.a" ]] || die "unexpected zip layout in $RAYLIB"
fi

# --------------------------------------------------------- SDK wasm libs
log "building SDK wasm static libs (zig)..."
# ReleaseFast on purpose: zig's Debug compiles C with UBSan runtime calls
# that nothing provides at the emcc link.
(cd "$SDK" && zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast \
    -Demsdk-sysroot="$EMSDK_DIR/cache/sysroot/include")
# zig-out is shared with native builds — keep a copy the link always trusts
LIBS="$HERE/build/web-libs"
mkdir -p "$LIBS"
cp "$SDK"/zig-out/lib/libcolyseus.a "$SDK"/zig-out/lib/libmsgpack_builder.a \
   "$SDK"/zig-out/lib/libmsgpack_reader.a "$SDK"/zig-out/lib/libstrutil_zig.a "$LIBS/"

# ---------------------------------------------------------------- server
if ! curl -s -o /dev/null --max-time 2 http://localhost:5173/; then
    log "WARNING: playground server not reachable on :5173 — the app will"
    log "         sit at 'connecting...'. Start it with:"
    log "             pnpm dev --host 0.0.0.0    (repo root)"
fi

# ------------------------------------------------------------------ link
OUT="$HERE/build/web"
mkdir -p "$OUT"
log "linking with emcc..."
"$EMCC" "$HERE/main.c" \
    -I"$SDK/include" \
    -I"$SDK/third_party/uthash/src" \
    -I"$SDK/third_party/sds" \
    -I"$SDK/third_party/cJSON" \
    -I"$HERE/../native" \
    -I"$RAYLIB/include" \
    "$LIBS/libcolyseus.a" \
    "$LIBS/libmsgpack_builder.a" \
    "$LIBS/libmsgpack_reader.a" \
    "$LIBS/libstrutil_zig.a" \
    "$RAYLIB/lib/libraylib.web.a" \
    -DPLATFORM_WEB \
    -O1 \
    -sUSE_GLFW=3 \
    -lwebsocket.js \
    -sFETCH \
    -sALLOW_MEMORY_GROWTH \
    -Wl,--allow-multiple-definition \
    -o "$OUT/index.html"

[[ -f "$OUT/index.wasm" ]] || die "link produced no index.wasm"

# ----------------------------------------------------------------- serve
log "serving $OUT at http://localhost:$PORT  (ctrl-c to stop)"
log "the app connects to ws://127.0.0.1:5173 — same rooms as every other lane"
cd "$OUT"
exec python3 -m http.server "$PORT"
