# Local Pi instance overview

A separate, read-only dashboard for **all Pi processes belonging to this Unix
user on this Linux machine**, not just one orchestration run. Independent of the
existing `/workers` dashboard. No process control, session takeover, prompt
submission, model calls, or changes to other sessions/transcripts.

## Open it

Run in a new terminal:

```sh
pi-instances
```

Alternatively start a normal Pi and enter `/instances`. The launcher starts an
offline, tool-free Pi with only this extension and automatically opens the view.
Escape/q closes the view and exits a dedicated `--instances` invocation; when
opened through `/instances`, it returns to that Pi's editor.

- Up/Down, PageUp/PageDown: select an instance (or scroll details).
- Enter: toggle details, including session ID/path, model, activity and previews.
- `a`: include registered processes that exited within the last ten minutes.
- `r`: refresh now; otherwise refreshes every two seconds while open.
- Escape/q: back from details, then close.

The list contains PID, project/session name, state, last activity age and latest
observed action. Details include bounded recent events, latest request and recent
assistant text. Tool arguments/results and thinking content are not captured.

## Visibility and adoption

The global extension automatically publishes telemetry on new Pi launches.
Existing **interactive** sessions can run `/reload` when it is safe to do so.
Do not interrupt working sessions just to instrument them: `/reload` can dispose
other extensions' owned worker chats. Loading this extension does not restart or
replay any work.

States are deliberately distinct:

- **WORKING / IDLE / WAITING**: a matching live process and fresh telemetry.
  Waiting means a blocking extension UI, including this dashboard or a dialog;
  it is not necessarily an approval request. Final idle comes from
  `agent_settled`, not `agent_end` (which may be followed by retries/queued work).
- **STALE**: process exists, heartbeat is missing/old/future-dated, or the
  previous extension runtime ended. Displayed fields are last reported only.
- **LOG-ONLY**: extensions-disabled JSON workers can expose a regular `.jsonl`
  stdout file. The dashboard reads a bounded tail without consuming pipes or
  terminals. Activity is last observed; current busy/idle state is **unknown**.
  Log-header session identity is labelled as such, not treated as a verified
  live session. It does not infer completion from `agent_end`.
- **UNKNOWN**: process detected but no telemetry or supported log available.
- **EXITED**: registered process identity no longer present; not proof that its
  assignment finished successfully. These rows are hidden unless `a` is enabled.

Workers launched with `--no-extensions` remain log-only/unknown. For telemetry on
**future** worker launches, retain isolation and explicitly add:

```sh
pi --no-extensions --extension ~/.pi/agent/extensions/instances ...
```

This works in JSON, print, RPC and interactive modes. It does not enable other
personal extensions or add model tools. No existing worker launchers are changed.

PID identity includes Linux boot ID and process start ticks, preventing PID reuse
from borrowing another session's telemetry. A session's identity comes from
`ctx.sessionManager`, never its inherited `PI_SESSION_ID`. Direct Pi OS parents
are identified in details. An inherited session ID is shown only as an explicitly
unverified launch hint: detached supervisor workers cannot reliably be grouped
under a live orchestrator without an explicit ownership contract. No alphabetical
"latest run" selection and no guesses based on shared working directories.

## Storage and privacy

Registry: `$XDG_RUNTIME_DIR/pi-instances-$UID`, or the same basename in the OS temp
directory. `PI_INSTANCES_DIR` overrides it for every participating process (use
the same value in observers and viewer). The registry must be an owned, non-symlink
0700 directory; atomic JSON snapshots are 0600. Heartbeats are written every two
seconds; event callbacks only update bounded in-memory state. Observer resources
start at `session_start`, and shutdown/reload fences pending writes and marks that
runtime ended. Valid records older than 24 hours are pruned on observer startup.
No growing event log. Limits and malformed/unreadable input are visible warnings.

Prompt and assistant-text previews can contain sensitive project information.
They stay in this user's local registry, are limited to 400 characters each, and
are **not uploaded or sent to the dashboard's model**. Full transcripts, credentials,
tool arguments, tool results and thinking text are not copied. Legacy log reading
necessarily parses a bounded portion of the existing stdout log; only the permitted
summary fields are displayed. Terminal controls/bidi overrides are sanitized.

Scope: one local Linux user. No remote hosts or other users. Process inventory
requires `/proc` visibility; inaccessible entries are reported, not silently
claimed idle. Processes with unusual launchers/titles require the extension.
Counters, event history and observer-attached time start at each extension load,
not the beginning of a resumed conversation. An uninstrumented process that exits
has no durable dashboard history. The view is intentionally observational: errors
and last activity do not establish whether a task is blocked or completed.

## Installation and tests

Canonical source: `/etc/nixos/config/pi/instances`. Home Manager installs that
directory and `config/scripts/pi-instances.sh` as `~/.local/bin/pi-instances`.
Development symlinks allow immediate use without a NixOS rebuild.

Typecheck `config/pi/tsconfig.json` and run `config/pi/tests/instances.test.ts`
against the installed Pi dependencies. Native offline acceptance:

```sh
python3 config/pi/tests/instances-tui.py
```

The native test boots two real Pi processes, checks separate session identities,
heartbeat/idle/waiting state, read-only navigation, resize, process exit visibility
and orderly shutdown with zero model turns/tools. Unit tests cover PID reuse,
reload selection, stale state, concurrent tools, bounds, private files, Unicode,
process/log discovery and UI lifetime. Tests do not certify every terminal or
provider, and do not connect to real model APIs.
