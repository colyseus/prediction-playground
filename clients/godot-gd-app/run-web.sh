#!/usr/bin/env bash
# Export the GDScript playground for the web and serve it.
#
#   ./run-web.sh            debug export  -> http://localhost:8060
#   ./run-web.sh --release  release export
#
# The chain this script validates, in order:
#   1. the GDExtension wasm side-module (built from native-sdk/platforms/godot)
#   2. dlink-enabled export templates in Godot's standard template folder
#      (the ONE piece not produced by this repo — build instructions below)
#   3. the playground server on :5173 (ws:// target of the exported app)
#
# Web caveats (by design): the SDK's auto-reconnect is a no-op on Emscripten,
# so the D key drops the room without recovery; re-join by switching labs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"   # NON-mono
PORT="${PORT:-8060}"

MODE="debug"
[[ "${1:-}" == "--release" ]] && MODE="release"

log()  { echo "[run-web] $*"; }
die()  { echo "[run-web] ERROR: $*" >&2; exit 1; }

[[ -x "$GODOT" ]] || die "Godot not found at $GODOT (set GODOT=...)"

# ---------------------------------------------------------------- 1. wasm
WASM="$HERE/addons/colyseus/bin/libcolyseus_godot.web.wasm32.$MODE.wasm"
if [[ ! -f "$WASM" ]]; then
    die "extension wasm missing: $WASM
  build it:  cd native-sdk/platforms/godot && \\
             EMSDK_PYTHON=/opt/homebrew/bin/python3.12 \\
             zig build -Dtarget=wasm32-emscripten$([[ $MODE == release ]] && echo ' -Doptimize=ReleaseFast')
  (emcc's tooling needs python >= 3.10 — the default macOS python3 is too old)"
fi

# ----------------------------------------------------------- 2. templates
VERSION_LINE="$("$GODOT" --version 2>/dev/null | head -1)"          # e.g. 4.6.1.stable.official.14d19694e
VERSION_DIR="$(echo "$VERSION_LINE" | cut -d. -f1-3).stable"        # -> 4.6.1.stable
TPL_DIR="$HOME/Library/Application Support/Godot/export_templates/$VERSION_DIR"
TPL="$TPL_DIR/web_dlink_nothreads_$MODE.zip"
if [[ ! -f "$TPL" ]]; then
    die "dlink export template missing: $TPL
  The official templates do NOT support GDExtensions. Build them once,
  matching the editor version EXACTLY:
    git clone -b ${VERSION_DIR%.stable}-stable --depth 1 https://github.com/godotengine/godot /tmp/godot-src
    cd /tmp/godot-src
    scons platform=web dlink_enabled=yes threads=no target=template_debug
    scons platform=web dlink_enabled=yes threads=no target=template_release
    mkdir -p \"$TPL_DIR\"
    cp bin/godot.web.template_debug.wasm32.nothreads.dlink.zip   \"$TPL_DIR/web_dlink_nothreads_debug.zip\"
    cp bin/godot.web.template_release.wasm32.nothreads.dlink.zip \"$TPL_DIR/web_dlink_nothreads_release.zip\"
  (needs scons + the emsdk version Godot $VERSION_DIR pins — see
   https://docs.godotengine.org/en/stable/contributing/development/compiling/compiling_for_web.html)"
fi

# -------------------------------------------------------------- 3. server
if ! curl -s -o /dev/null --max-time 2 http://localhost:5173/; then
    log "WARNING: playground server not reachable on :5173 — the exported"
    log "         app will sit at 'connecting...'. Start it with:"
    log "             pnpm dev --host 0.0.0.0    (repo root)"
fi

# ---------------------------------------------------------------- export
log "importing project (headless)..."
"$GODOT" --headless --path "$HERE" --import > /dev/null 2>&1 || true

OUT="$HERE/build/web"
mkdir -p "$OUT"
log "exporting ($MODE)..."
if [[ "$MODE" == "release" ]]; then
    "$GODOT" --headless --path "$HERE" --export-release "Web" "$OUT/index.html"
else
    "$GODOT" --headless --path "$HERE" --export-debug "Web" "$OUT/index.html"
fi

[[ -f "$OUT/index.html" ]] || die "export produced no index.html — check the log above"
# the extension wasm must have been packed alongside the engine's
ls "$OUT"/*.wasm >/dev/null 2>&1 || die "no .wasm landed in $OUT — extension not exported?"

# ----------------------------------------------------------------- serve
log "serving $OUT at http://localhost:$PORT  (ctrl-c to stop)"
log "the app connects to ws://localhost:5173 — same rooms as every other lane"
cd "$OUT"
exec python3 -m http.server "$PORT"
