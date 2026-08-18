#!/bin/bash
#
# Shared helpers for the caffeinate hooks. Source this file, do not run it.

CAFFEINATE_STATE_DIR="${CAFFEINATE_STATE_DIR:-/tmp/claude-caffeinate}"
CAFFEINATE_SESSION_PID_FILE="$CAFFEINATE_STATE_DIR/session.pid"
CAFFEINATE_SESSION_MARKER_DIR="$CAFFEINATE_STATE_DIR/sessions"
CAFFEINATE_DEFAULT_FLAGS="-dimsu"

caffeinate_init_state() {
    mkdir -p "$CAFFEINATE_STATE_DIR" 2>/dev/null
}

# Succeeds when the word is a bare caffeinate assertion flag, such as -i or
# -dims. -t and -w are rejected on purpose: the timeout belongs to
# CAFFEINATE_TIMEOUT, and -w would fight the pid tracking.
caffeinate_valid_flag() {
    local word="$1"

    case "$word" in
        -*) ;;
        *) return 1 ;;
    esac

    case "${word#-}" in
        "" | *[!dimsu]*) return 1 ;;
    esac

    return 0
}

# Prints the assertion flags to start caffeinate with. Reads CAFFEINATE_FLAGS,
# falling back to the default when it is unset, empty, or holds anything that
# is not an assertion flag, so a typo cannot silently leave the Mac unprotected.
caffeinate_flags() {
    local flags="${CAFFEINATE_FLAGS:-}"
    local word=""

    if [ -z "$flags" ]; then
        printf '%s' "$CAFFEINATE_DEFAULT_FLAGS"
        return
    fi

    for word in $flags; do
        if caffeinate_valid_flag "$word"; then
            continue
        fi

        printf '%s' "$CAFFEINATE_DEFAULT_FLAGS"
        return
    done

    printf '%s' "$flags"
}

# Reads the hook payload from stdin and prints a filename-safe session key.
# Prints "unknown" when no session id is available. Consumes stdin, so call
# this at most once per hook run.
caffeinate_session_key() {
    local payload=""
    local session_id=""

    if [ -t 0 ]; then
        payload=""
    else
        payload=$(cat 2>/dev/null | tr -d '\n')
    fi

    if [ -n "$payload" ]; then
        if command -v jq > /dev/null 2>&1; then
            session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
        fi

        # Fall back to text extraction when jq is missing or the payload is
        # not valid JSON. The first match wins, so message text that happens
        # to contain the key cannot override the real field.
        if [ -z "$session_id" ]; then
            session_id=$(printf '%s' "$payload" \
                | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | head -1 \
                | cut -d'"' -f4)
        fi
    fi

    session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)

    if [ -z "$session_id" ]; then
        session_id="unknown"
    fi

    printf '%s' "$session_id"
}

# Succeeds when the pid recorded in the given file is a live caffeinate
# process. The command name is checked so a recycled pid belonging to an
# unrelated process is never treated as ours.
caffeinate_running() {
    local pid_file="$1"
    local pid=""

    [ -f "$pid_file" ] || return 1

    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] || return 1

    ps -p "$pid" > /dev/null 2>&1 || return 1
    ps -p "$pid" -o args= | grep -q '^caffeinate'
}

# Kills the caffeinate process recorded in the given file, then removes the file.
caffeinate_stop() {
    local pid_file="$1"
    local pid=""

    if caffeinate_running "$pid_file"; then
        pid=$(cat "$pid_file" 2>/dev/null)
        kill "$pid" 2>/dev/null
    fi

    rm -f "$pid_file"
}

# Removes per-command pid files whose caffeinate process has gone. Cleans up
# after sessions that were killed before their Stop hook could run.
caffeinate_prune_stale_commands() {
    local pid_file=""

    for pid_file in "$CAFFEINATE_STATE_DIR"/cmd-*.pid; do
        [ -e "$pid_file" ] || continue
        caffeinate_running "$pid_file" || rm -f "$pid_file"
    done
}
