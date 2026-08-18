# caffeinate-claude

Stop your Mac falling asleep while [Claude Code](https://code.claude.com/docs) is working.
Wraps the built-in macOS `caffeinate` utility in a set of hooks, shipped as a Claude Code plugin.

Safe to run with several Claude Code sessions open at once. Each session owns its own
`caffeinate` process, so one session finishing never puts the Mac to sleep underneath another.

## Install

### As a plugin (recommended)

This plugin is published through the [clnt marketplace](https://github.com/clnt/cc).

```text
/plugin marketplace add clnt/cc
/plugin install caffeinate-claude@clnt
```

The `owner/repo` shorthand clones over SSH. If you do not have GitHub SSH access, use the
HTTPS URL instead:

```text
/plugin marketplace add https://github.com/clnt/cc.git
```

Restart Claude Code, then check the hooks are registered with `/hooks`. You should see two,
`UserPromptSubmit` and `Stop`.

Per-command protection works from that point on. Nothing else to configure.

### Session-level, as a separate opt-in

The main plugin never registers `SessionStart` or `SessionEnd`. Leaving a session open
overnight cannot hold the Mac awake. Install the companion plugin if you want that behaviour:

```text
/plugin install caffeinate-claude-session@clnt
```

It ships disabled. Turn it on deliberately:

```bash
claude plugin enable caffeinate-claude-session
```

Even then it does nothing until `CLAUDE_STAY_AWAKE` is set on the session, so it takes two
opt-ins before your Mac stays awake while idle.

### Manually

Copy the scripts and wire them up yourself if you would rather not use the plugin system.

```bash
mkdir -p ~/.claude/hooks
cp -R hooks/lib hooks/per-command hooks/session ~/.claude/hooks/
chmod +x ~/.claude/hooks/per-command/*.sh ~/.claude/hooks/session/*.sh
```

The `lib` directory is required. Both strategies source their shared helpers from it.

Then merge one of the example configs into `~/.claude/settings.json`:

- **Per-command only:** [`examples/per-command.json`](examples/per-command.json)
- **Session only:** [`examples/session.json`](examples/session.json)
- **Both:** [`examples/combined.json`](examples/combined.json)

Do not run the plugin and a manual copy at the same time. Both would fire on every event.

## Strategies

### Per-command (on by default)

Keeps the Mac awake only while Claude is working on a response. Useful for autonomous agents
and long-running commands you kick off before stepping away from the machine.

`caffeinate` starts when you submit a prompt and is killed when Claude stops.

- **Hooks:** `UserPromptSubmit` / `Stop`
- **Timeout:** 1 hour by default, set `CAFFEINATE_TIMEOUT` to change it
- **Sleep type:** display, idle, disk and system sleep (`caffeinate -dimsu`), set
  `CAFFEINATE_FLAGS` to change it

### Session-level (opt in, separate plugin)

Keeps the Mac awake for a whole Claude Code session, including idle time. Useful for
[remote-control](https://code.claude.com/docs/en/remote-control) sessions.

- **Hooks:** `SessionStart` / `SessionEnd`, registered by `caffeinate-claude-session` only
- **Gate:** only runs when `CLAUDE_STAY_AWAKE` is set
- **Sleep type:** display, idle, disk and system sleep (`caffeinate -dimsu`), no timeout

Set the variable on the sessions you want it for. A shell alias is the tidiest way:

```bash
# ~/.zshrc or ~/.bashrc
alias claude-remote='CLAUDE_STAY_AWAKE=1 claude --remote-control'
```

### Using both

Install both plugins and per-command runs everywhere while session-level activates only where
you set `CLAUDE_STAY_AWAKE`. When a session-level `caffeinate` is running, the per-command hook
skips its own, because session-level already covers it.

## Concurrent sessions

Both strategies are built for several sessions running at once.

**Per-command** keys its PID file on the session id from the hook payload, so each session
starts and kills only its own `caffeinate`:

```text
/tmp/claude-caffeinate/cmd-<session-id>.pid
```

Session A submitting a prompt does not disturb session B, and session A finishing does not
release session B's `caffeinate`.

**Session-level** shares one `caffeinate` across every session. Each session writes a marker
file, and the process is stopped when the last marker is removed:

```text
/tmp/claude-caffeinate/session.pid
/tmp/claude-caffeinate/sessions/<session-id>
```

Markers are keyed per session, so resuming a session does not register a second claim, and two
sessions starting at the same moment cannot lose each other's claim to a read-modify-write race.

## Configuration

| Variable               | Applies to    | Default                  | Purpose                                          |
| :--------------------- | :------------ | :----------------------- | :----------------------------------------------- |
| `CLAUDE_STAY_AWAKE`    | Session-level | unset                    | Set to any value to turn the session strategy on |
| `CAFFEINATE_TIMEOUT`   | Per-command   | `3600`                   | Seconds before `caffeinate` gives up, per prompt |
| `CAFFEINATE_FLAGS`     | Both          | `-dimsu`                 | Which kinds of sleep to hold off                 |
| `CAFFEINATE_STATE_DIR` | Both          | `/tmp/claude-caffeinate` | Where PID and marker files are kept              |

```bash
# ~/.zshrc or ~/.bashrc
export CAFFEINATE_TIMEOUT=7200  # 2 hours
export CAFFEINATE_FLAGS="-i"    # idle sleep only, let the display turn off
```

### Sleep flags

`CAFFEINATE_FLAGS` is passed straight to `caffeinate`. The default holds off every kind of
sleep the tool can reach.

| Flag | Effect                                                           |
| :--- | :--------------------------------------------------------------- |
| `-d` | Keeps the display awake                                          |
| `-i` | Keeps the system from idle sleeping                              |
| `-m` | Keeps the disk from idle sleeping                                |
| `-s` | Keeps the system from sleeping at all, honoured only on AC power |
| `-u` | Declares the user active, and turns the display on if it is off  |

Write them combined (`-dimsu`) or separated (`-d -i -m -s -u`). Both are accepted.

Two flags are worth a deliberate choice. `-d` holds the screen at full brightness for as long
as the assertion lasts, which costs battery and leaves your work on display. `-u` turns a
blanked screen back on, so a Mac you walked away from lights up again when Claude starts
working. Drop either one if you would rather they did not.

Only assertion flags are accepted. `-t` belongs to `CAFFEINATE_TIMEOUT`, and `-w` would fight
the PID tracking, so both are refused. Anything the hooks do not recognise falls back to the
default rather than starting a `caffeinate` that exits immediately and leaves the Mac
unprotected.

With the session strategy there is no `-t`, and `caffeinate` gives a lone `-u` assertion a
five second life in that case. `-d` is what holds the display awake for the rest of the
session.

## How it works

Both strategies drive macOS [`caffeinate`](https://ss64.com/mac/caffeinate.html) to hold off
sleep, and track the process by PID.

### PID safety

Before killing anything, the scripts confirm the recorded PID still belongs to a `caffeinate`
process. An unrelated process that inherited a recycled PID is left alone:

```bash
ps -p "$pid" -o args= | grep -q '^caffeinate'
```

### Session keys

Every hook receives a JSON payload on stdin containing `session_id`. The scripts read it with
`jq` when it is installed and fall back to text extraction when it is not. The value is stripped
to `A-Za-z0-9_-` before it reaches a filename, so a hostile or malformed id cannot escape the
state directory.

When no session id can be read, the scripts fall back to the key `unknown` and behave like the
original single-session version.

### Stale state

A session killed before its `Stop` hook runs leaves a PID file behind. The per-command hook
prunes dead entries each time it starts, and the `CAFFEINATE_TIMEOUT` ceiling means an orphaned
`caffeinate` exits on its own.

Session-level markers have no such ceiling. A session that dies without firing `SessionEnd`
leaves its marker in place, which holds `caffeinate` open. Clear it by hand if that happens:

```bash
rm -rf /tmp/claude-caffeinate
pkill caffeinate
```

## Tests

`tests/run-tests.sh` drives the hooks with simulated payloads for concurrent sessions, repeat
prompts, crashed sessions, session resume, and payloads with no session id. It runs against an
isolated state directory and only ever kills `caffeinate` processes it started itself.

```bash
./tests/run-tests.sh
```

## Credits

Forked from [bmoeskau/caffeinate-claude](https://github.com/bmoeskau/caffeinate-claude), which
adapted the per-command strategy from
[Preventing Mac Sleep with Claude Code](https://tngranados.com/blog/preventing-mac-sleep-claude-code/)
by Toni Granados.

This fork adds per-session isolation, plugin packaging, and marker-based session tracking.

## License

[MIT](LICENSE)
