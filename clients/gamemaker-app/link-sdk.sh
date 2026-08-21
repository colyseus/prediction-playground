#!/usr/bin/env bash
# Wire this project to the sibling native-sdk checkout: the .gml wrappers and
# the extension binaries are linked, Colyseus_SDK.yy is generated against
# this .yyp. Nothing linked is committed, so the pair cannot drift apart.
#
#   ./link-sdk.sh            link
#   ./link-sdk.sh --check    verify every artefact resolves and matches
#   ./link-sdk.sh --copy     copy instead of linking
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="$DIR/../../../../native-sdk/platforms/gamemaker"
[[ -x "$SDK/link-sdk.sh" ]] || { echo "[link-sdk] native-sdk not found at $SDK" >&2; exit 1; }
exec "$SDK/link-sdk.sh" "$@" "$DIR" PredictionPlayground.yyp
