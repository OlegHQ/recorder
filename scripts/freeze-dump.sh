#!/bin/bash
# T-610 (SPEC §8): a hung Recorder main thread can't run a menu action or a hotkey — this is the
# out-of-process fallback. Finds the running Recorder process (newest PID, or the one given), grabs a
# 3 s `sample` + basic `ps` stats (no sudo, no lsof), writes them into a new folder under the SAME
# ~/Library/Logs/Recorder/Snapshots directory `StateSnapshot.dump()` uses, copies that folder's path
# to the clipboard, and prints it.
#
# Usage: scripts/freeze-dump.sh [pid]
set -euo pipefail

PID="${1:-}"
if [ -z "$PID" ]; then
  PID="$(pgrep -x Recorder | sort -n | tail -1 || true)"
fi
if [ -z "$PID" ]; then
  echo "freeze-dump: no running Recorder process found (pass a PID explicitly to target one)" >&2
  exit 1
fi

SNAPSHOTS_DIR="$HOME/Library/Logs/Recorder/Snapshots"
FOLDER="$SNAPSHOTS_DIR/$(date '+%Y-%m-%d %H.%M.%S') freeze-dump"
mkdir -p "$FOLDER"

# `sample` needs a few seconds to walk the hung thread's stack; a timeout here would defeat the point.
if ! sample "$PID" 3 -file "$FOLDER/sample.txt" >/dev/null 2>&1; then
  echo "freeze-dump: 'sample $PID' failed (process gone, or Full Disk Access/dev tools missing)" >&2
fi
ps -o pid,etime,%cpu,rss,stat -p "$PID" > "$FOLDER/ps.txt" 2>&1 || true

printf '%s' "$FOLDER" | pbcopy
echo "$FOLDER"
