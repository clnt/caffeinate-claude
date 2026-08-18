#!/bin/bash
#
# Prevent the Mac from sleeping while any Claude Code session is running.
# All sessions share one caffeinate process. Each session registers a marker
# file, and allow-sleep.sh stops caffeinate once the last marker is gone.

[ -z "$CLAUDE_STAY_AWAKE" ] && exit 0

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/../lib/caffeinate-common.sh"

session_key=$(caffeinate_session_key)

caffeinate_init_state
mkdir -p "$CAFFEINATE_SESSION_MARKER_DIR" 2>/dev/null

# One marker per session. Resuming a session rewrites its own marker rather
# than registering a second claim on the shared process.
touch "$CAFFEINATE_SESSION_MARKER_DIR/$session_key"

# Another session has already started caffeinate.
if caffeinate_running "$CAFFEINATE_SESSION_PID_FILE"; then
    exit 0
fi

rm -f "$CAFFEINATE_SESSION_PID_FILE"

# Start caffeinate with no timeout (runs until killed).
# $flags is deliberately unquoted so a multi-word CAFFEINATE_FLAGS such as
# "-d -i" reaches caffeinate as separate arguments.
flags=$(caffeinate_flags)
# shellcheck disable=SC2086
nohup caffeinate $flags > /dev/null 2>&1 &
echo $! > "$CAFFEINATE_SESSION_PID_FILE"
