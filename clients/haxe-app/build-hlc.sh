#!/usr/bin/env bash
#
# Build the WINDOWED client as a native binary via HashLink/C.
#
# Why this exists: HashLink's JIT has no arm64 backend, so `hl playground.hl`
# cannot run on Apple Silicon at all — the alternatives are Rosetta or a
# work-in-progress arm64 JIT. HL/C sidesteps the JIT entirely: Haxe emits C, and
# the system compiler builds it against the arm64 libhl and .hdll natives
# Homebrew ships. (That is also why `brew install hashlink` gives you include/
# and lib/ but no bin/hl on this platform — the JIT binary is not the useful
# artifact here.)
#
#   ./build-hlc.sh && ./bin/hlc-playground      # server up first
#
set -euo pipefail
cd "$(dirname "$0")"

HL_PREFIX="${HL_PREFIX:-/opt/homebrew}"
HL_LIB="$HL_PREFIX/lib"
OUT=bin/hlc-playground

if [ ! -f "$HL_LIB/libhl.dylib" ]; then
  echo "error: no libhl.dylib under $HL_LIB" >&2
  echo "       brew install hashlink   (or set HL_PREFIX)" >&2
  exit 1
fi

echo "==> haxe -> C"
haxe build-hlc.hxml

# The .hdll natives are linked explicitly: they are plain dylibs, and the
# generated code calls straight into them (fmt_*, sdl_*, hl_gl_* ...).
HDLLS=()
for h in fmt sdl openal ui heaps ssl uv; do
  [ -f "$HL_LIB/$h.hdll" ] && HDLLS+=("$HL_LIB/$h.hdll")
done

echo "==> clang -> $OUT"
# Three flags here are load-bearing, each learned the hard way:
#
#   -Wl,-rpath,$HL_LIB  The .hdll natives depend on `@rpath/libhl.dylib`, NOT an
#                       absolute path. Without an rpath the loader falls back to
#                       its default search and can bind a DIFFERENT libhl — a
#                       stale ~/bin/libhl.dylib here, which aborts at startup
#                       with `Symbol not found: _hl_setup_callbacks`. Whether it
#                       works without this is pure search-order luck, so it
#                       "worked" on one machine and aborted on another.
#   -luv                uv.hdll does not re-export uv_default_loop / uv_run.
#   -o bin/hlc-playground   NOT bin/hlc/playground: the `playground` Haxe package
#                       generates a bin/hlc/playground/ directory to collide with.
clang -O2 -o "$OUT" -std=c11 \
  -I bin/hlc -I "$HL_PREFIX/include" \
  bin/hlc/main.c \
  -L"$HL_LIB" -lhl -luv \
  -Wl,-rpath,"$HL_LIB" \
  "${HDLLS[@]}"

echo "==> ok: $OUT"
otool -l "$OUT" | grep -A2 LC_RPATH | grep "path " | sed 's/^/    rpath:/'
