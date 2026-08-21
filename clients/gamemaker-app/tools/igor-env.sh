# Locate Igor, the runtime and the licence folder. Sourced by run.sh,
# run-acceptance.sh and html5-check.sh.
# Same discovery the SDK's run-tests.sh uses.
#
# Every guard is a full `if` — a trailing `[[ ]] && { }` would return 1 when the
# guard passes, and `set -e` in the caller reads that as a failed `source`.
runtime_dir=$(ls -d /Users/Shared/GameMakerStudio2/Cache/runtimes/runtime-* 2>/dev/null | sort -V | tail -1)
if [[ -z "$runtime_dir" ]]; then
  echo "[igor] runtime not found — open GameMaker once to install one" >&2; exit 1
fi

igor_bin=""
for c in "$runtime_dir/bin/igor/osx/arm64/Igor" "$runtime_dir/bin/igor/osx/x86_64/Igor"; do
  if [[ -x "$c" ]]; then igor_bin="$c"; break; fi
done
if [[ -z "$igor_bin" ]]; then
  echo "[igor] Igor not found under $runtime_dir" >&2; exit 1
fi

user_dir=""
for d in "$HOME/Library/Application Support/GameMakerStudio2"/*_*/; do
  if [[ -f "${d}licence.plist" ]]; then user_dir="${d%/}"; break; fi
done
if [[ -z "$user_dir" ]]; then
  echo "[igor] GameMaker licence folder not found" >&2; exit 1
fi
