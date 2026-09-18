#!/bin/sh
# scripts/ui.sh <selftest-name> [args...]
# Runs `build/Recorder.app --selftest <name> [args]` through `open`, so macOS applies
# Recorder's own TCC grants (Screen Recording / Accessibility) instead of the shell's.
# Prints the selftest's stdout and exits 0 on an "OK" line, 1 on "failed" or timeout.
set -eu

if [ $# -lt 1 ]; then
    echo "usage: scripts/ui.sh <selftest-name> [args...]" >&2
    exit 1
fi
name="$1"
shift

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$repo_root/build/Recorder.app"
out="$(mktemp "${TMPDIR:-/tmp}/recorder-ui.XXXXXX")"
err="$(mktemp "${TMPDIR:-/tmp}/recorder-ui.XXXXXX")"
trap 'rm -f "$out" "$err"' EXIT

open -n --stdout "$out" --stderr "$err" "$app" --args --selftest "$name" "$@"

deadline=$(($(date +%s) + 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -q "^SELFTEST $name OK" "$out" 2>/dev/null; then
        cat "$out"
        exit 0
    fi
    if grep -q "^SELFTEST $name failed" "$out" 2>/dev/null; then
        cat "$out"
        exit 1
    fi
    sleep 0.2
done

echo "timed out after 60s waiting for SELFTEST $name" >&2
cat "$out"
exit 1
