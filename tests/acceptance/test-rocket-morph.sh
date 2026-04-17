#!/usr/bin/env bash
# test-rocket-morph.sh
# Verifies hot-switching and rocket state sequence.
# Requires buddy app running (test is skipped with informational exit if not).
set -euo pipefail

SOCKET="/tmp/claude-buddy.sock"
if [ ! -S "$SOCKET" ]; then
    echo "SKIP: buddy app not running (socket $SOCKET absent)"
    exit 0
fi

BUDDY="${BUDDY:-buddy}"
if ! command -v "$BUDDY" >/dev/null 2>&1; then
    # Fall back to local build
    BUDDY="$(pwd)/.build/debug/buddy-cli"
    if [ ! -x "$BUDDY" ]; then
        echo "SKIP: buddy CLI not found"
        exit 0
    fi
fi

SID="debug-accept-$(date +%s)"

"$BUDDY" session start --id "$SID" --cwd /tmp
sleep 1

# --- cat phase ---
"$BUDDY" morph cat
sleep 2
"$BUDDY" emit thinking --id "$SID"
sleep 1

# --- switch to rocket ---
"$BUDDY" morph rocket
sleep 2

# state replayed; rocket should be in systemsCheck / cruising
"$BUDDY" emit tool_start --id "$SID" --tool Read
sleep 2
"$BUDDY" emit task_complete --id "$SID"
sleep 3  # propulsive landing animation
"$BUDDY" emit tool_start --id "$SID" --tool Write
sleep 2

# --- switch back to cat mid-cruise ---
"$BUDDY" morph cat
sleep 2

"$BUDDY" session end --id "$SID"
sleep 1

echo "PASS: rocket morph acceptance"
