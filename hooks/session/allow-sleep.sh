#!/bin/bash
#
# Re-enable Mac sleep when the last Claude Code session ends.
# Removes this session's marker, then stops the shared caffeinate process
# only when no other session still holds one.
#
# This runs ungated so a session that started with CLAUDE_STAY_AWAKE set
# still cleans up if the variable is missing by the time it ends.

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/../lib/caffeinate-common.sh"

session_key=$(caffeinate_session_key)

rm -f "$CAFFEINATE_SESSION_MARKER_DIR/$session_key"

remaining=$(ls -1 "$CAFFEINATE_SESSION_MARKER_DIR" 2>/dev/null | wc -l | tr -d ' ')

if [ "$remaining" -gt 0 ] 2>/dev/null; then
    exit 0
fi

caffeinate_stop "$CAFFEINATE_SESSION_PID_FILE"
rmdir "$CAFFEINATE_SESSION_MARKER_DIR" 2>/dev/null
