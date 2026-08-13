#!/bin/bash
#
# Re-enable Mac sleep after Claude finishes working on a response.
# Only touches the caffeinate process belonging to this session.
#
# Adapted from: https://tngranados.com/blog/preventing-mac-sleep-claude-code/

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/../lib/caffeinate-common.sh"

session_key=$(caffeinate_session_key)

caffeinate_stop "$CAFFEINATE_STATE_DIR/cmd-$session_key.pid"
