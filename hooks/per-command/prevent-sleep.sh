#!/bin/bash
#
# Prevent the Mac from sleeping while Claude is working on a response.
# Starts caffeinate on each prompt submission; allow-sleep.sh kills it when
# Claude stops.
#
# Each Claude Code session gets its own caffeinate process, keyed by the
# session id in the hook payload, so concurrent sessions never kill each
# other's process.
#
# Adapted from: https://tngranados.com/blog/preventing-mac-sleep-claude-code/

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/../lib/caffeinate-common.sh"

session_key=$(caffeinate_session_key)

caffeinate_init_state

# Session-level caffeinate is a superset, so there is nothing to do here.
if caffeinate_running "$CAFFEINATE_SESSION_PID_FILE"; then
    exit 0
fi

pid_file="$CAFFEINATE_STATE_DIR/cmd-$session_key.pid"

# Clear anything this session left over from a previous prompt.
caffeinate_stop "$pid_file"

caffeinate_prune_stale_commands

# Start caffeinate with a timeout (default: 1 hour).
# $flags is deliberately unquoted so a multi-word CAFFEINATE_FLAGS such as
# "-d -i" reaches caffeinate as separate arguments.
timeout="${CAFFEINATE_TIMEOUT:-3600}"
flags=$(caffeinate_flags)
# shellcheck disable=SC2086
nohup caffeinate $flags -t "$timeout" > /dev/null 2>&1 &
echo $! > "$pid_file"
