#!/bin/bash
#
# Exercises the hooks with simulated concurrent sessions.
# Runs against an isolated state directory and never touches caffeinate
# processes it did not start.
#
# Usage: ./tests/run-tests.sh

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

export CAFFEINATE_STATE_DIR="/tmp/claude-caffeinate-test-$$"
export CAFFEINATE_TIMEOUT=120
unset CLAUDE_STAY_AWAKE

rm -rf "$CAFFEINATE_STATE_DIR"
failures=0

cleanup() {
    local leftover=""

    for leftover in $(cat "$CAFFEINATE_STATE_DIR"/*.pid 2>/dev/null); do
        if ps -p "$leftover" -o args= 2>/dev/null | grep -q '^caffeinate'; then
            kill "$leftover" 2>/dev/null
        fi
    done

    rm -rf "$CAFFEINATE_STATE_DIR"
}

trap cleanup EXIT

# Builds a hook payload. The assistant message carries a decoy session id to
# prove the parser reads the real field rather than message text.
payload() {
    printf '{"session_id":"%s","transcript_path":"/x/y.jsonl","cwd":"/tmp","hook_event_name":"%s","last_assistant_message":"quoting \\"session_id\\": \\"decoy\\" back at you"}' "$1" "$2"
}

pid_in() {
    cat "$CAFFEINATE_STATE_DIR/$1" 2>/dev/null
}

state() {
    if [ -n "$1" ] && ps -p "$1" > /dev/null 2>&1; then
        echo alive
        return
    fi
    echo dead
}

exists() {
    if [ -f "$1" ]; then
        echo present
        return
    fi
    echo absent
}

check() {
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
        return
    fi

    printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
    failures=$((failures + 1))
}

echo "per-command: two concurrent sessions"

payload sessionA UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
pid_a=$(pid_in "cmd-sessionA.pid")
check "session A started its own caffeinate" alive "$(state "$pid_a")"

payload sessionB UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
pid_b=$(pid_in "cmd-sessionB.pid")
check "session B started its own caffeinate" alive "$(state "$pid_b")"
check "session A survives B's prompt" alive "$(state "$pid_a")"
check "the two sessions hold different processes" different \
    "$( [ "$pid_a" != "$pid_b" ] && echo different || echo same )"

payload sessionA Stop | "$repo_dir/hooks/per-command/allow-sleep.sh"
check "session A released its own caffeinate" dead "$(state "$pid_a")"
check "session B survives A's stop" alive "$(state "$pid_b")"
check "session A pid file removed" absent "$(exists "$CAFFEINATE_STATE_DIR/cmd-sessionA.pid")"

payload sessionB Stop | "$repo_dir/hooks/per-command/allow-sleep.sh"
check "session B released on its own stop" dead "$(state "$pid_b")"

echo "per-command: two prompts in one session"

payload sessionC UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
pid_first=$(pid_in "cmd-sessionC.pid")
payload sessionC UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
pid_second=$(pid_in "cmd-sessionC.pid")
check "the earlier process is replaced" dead "$(state "$pid_first")"
check "the newer process runs" alive "$(state "$pid_second")"
payload sessionC Stop | "$repo_dir/hooks/per-command/allow-sleep.sh"

echo "per-command: stale state"

echo 999999 > "$CAFFEINATE_STATE_DIR/cmd-crashed.pid"
payload sessionD UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
check "dead session's pid file pruned" absent "$(exists "$CAFFEINATE_STATE_DIR/cmd-crashed.pid")"
payload sessionD Stop | "$repo_dir/hooks/per-command/allow-sleep.sh"

echo "session-level: gate and shared process"

payload sessionE SessionStart | "$repo_dir/hooks/session/prevent-sleep.sh"
check "gate holds without CLAUDE_STAY_AWAKE" absent "$(exists "$CAFFEINATE_STATE_DIR/session.pid")"

export CLAUDE_STAY_AWAKE=1

payload sessionE SessionStart | "$repo_dir/hooks/session/prevent-sleep.sh"
pid_shared=$(pid_in "session.pid")
check "shared caffeinate started" alive "$(state "$pid_shared")"

payload sessionF SessionStart | "$repo_dir/hooks/session/prevent-sleep.sh"
check "second session reuses the process" "$pid_shared" "$(pid_in "session.pid")"

payload sessionE SessionStart | "$repo_dir/hooks/session/prevent-sleep.sh"
check "resuming a session adds no second claim" 2 \
    "$(ls -1 "$CAFFEINATE_STATE_DIR/sessions" | wc -l | tr -d ' ')"

payload sessionF UserPromptSubmit | "$repo_dir/hooks/per-command/prevent-sleep.sh"
check "per-command defers to session-level" absent "$(exists "$CAFFEINATE_STATE_DIR/cmd-sessionF.pid")"

payload sessionE SessionEnd | "$repo_dir/hooks/session/allow-sleep.sh"
check "shared process survives the first exit" alive "$(state "$pid_shared")"

payload sessionF SessionEnd | "$repo_dir/hooks/session/allow-sleep.sh"
check "shared process stops on the last exit" dead "$(state "$pid_shared")"

unset CLAUDE_STAY_AWAKE

echo "payload without a session id"

printf '{}' | "$repo_dir/hooks/per-command/prevent-sleep.sh"
check "falls back to the unknown key" present "$(exists "$CAFFEINATE_STATE_DIR/cmd-unknown.pid")"
pid_unknown=$(pid_in "cmd-unknown.pid")
printf '{}' | "$repo_dir/hooks/per-command/allow-sleep.sh"
check "unknown key cleans up" dead "$(state "$pid_unknown")"

echo "session id sanitising"

key=$(printf '{"session_id":"../../etc/passwd"}' | (
    . "$repo_dir/hooks/lib/caffeinate-common.sh"
    caffeinate_session_key
))
check "path separators stripped" etcpasswd "$key"

echo
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
    exit 0
fi

echo "$failures check(s) failed."
exit 1
