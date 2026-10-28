# Session-owned workers sidebar

Two commands, no automatic bottom box:

- **`/workers`** — show only workers associated with the current Pi session.
- **`/workers-all`** — show all saved sessions, the current session, and registered
  worker owners. Expand a session to see its workers; sessions with no workers
  remain visible. Worker conversations are not duplicated as top-level sessions.

Both commands open a right-hand sidebar. The current session starts expanded in
all-sessions mode; other sessions start collapsed. Ownership is by exact session
ID, **not** working directory, process ancestry, most recent run, or inherited
`PI_SESSION_ID`. `/new` and `/fork` do not inherit the previous session's workers.
Resuming the same session retains its associations.

## Sidebar controls

- **↑/↓**, **PgUp/PgDn**, **Home/End**: select/scroll.
- **←/→**, or **Enter** on a session: collapse/expand its worker submenu.
- **Enter** on a worker: open its chat, without sending a prompt.
- **R**: open the selected worker's progress/report view.
- **U**: unload an idle worker chat owned by this Pi window.
- **X**: close this window's loaded worker chats; confirmation is required if busy.
- **Esc**, **Alt+0**: close the sidebar and return to the original editor draft.
- **Alt+W** from the main editor: open/close this session's sidebar.
- **Alt+1 … Alt+9** from the main editor: open that worker of the current session.
  Inside the all-sessions sidebar these keys refer to the selected session;
  inside a worker chat they refer to that chat's owning session.

Worker numbers are stable **per owning session**, across all its runs, polling,
reordering and removal. Removed numbers are not reused until reload/session
replacement. Reports display run-local numbers; their chat shortcuts resolve the
corresponding worker back to its owning session.

The sidebar polls worker state every two seconds. All-sessions mode refreshes
saved session metadata at most every 15 seconds. Missing/broken state is displayed
under its owner, not replaced by older successful state. Invalid ownership is a
visible error in all-sessions mode, never assigned to the current session.

## Creating new workers

Run discovery has no legacy compatibility or automatic import. The default root
is **`~/.pi/agent/workers`** (under Pi's configured agent directory), overridable
with `PI_WORKERS_ROOT`.

Before launching workers, the agent calls the **`register_worker_run`** tool:

```json
{ "run": "20261028T120000Z" }
```

The tool creates a new private run directory and `control/owner.json`, binding it
to `ctx.sessionManager.getSessionId()`. It returns the directory for the supervisor
to use. Existing directories cannot be adopted, overwritten, or reassigned. The
caller must choose a new run ID if it already exists. Merely registering a run
**does not launch workers** or make a model call.

Ownership record:

```json
{
  "version": 1,
  "sessionId": "the-actual-parent-session-id",
  "name": "Parent session name",
  "cwd": "/path/to/project",
  "created": 1793188800000
}
```

The supervisor writes `control/state.json`; a combined quality-phase
`control/dashboard.json` takes precedence when present. The existing supervisor
state contract is:

```json
{
  "run": "20261028T120000Z",
  "provider": "openai-codex",
  "model": "the-selected-model",
  "thinking": "high",
  "updated": 1793188800,
  "tasks": {
    "worker-1": {
      "title": "Investigate the issue",
      "state": "running",
      "session_id": "worker-conversation-id"
    }
  }
}
```

Set each task's `session_id` so its conversation can be nested beneath the parent
rather than duplicated in the saved-session list. Reports live in
`tasks/<id>/PROGRESS.md`, `REPORT.md`, and `stderr.log`.

A run with `owner.json` remains visible before its first state write. Unregistered
folders are ignored, even if they contain old state, manifests or timestamped run
names. There is no “latest run” mode, backward-compatible command parser, legacy
worker migration, or unassigned-worker group. Discovery is bounded to 512 root
entries and reports an error rather than silently omitting runs.

## Worker chats and ownership

Worker chat continuations use a separate long-lived Pi RPC process. Alt+0 detaches
only the foreground surface: the calling agent and loaded workers continue in the
background. Each worker keeps its own editor draft, transcript and streaming state.
Opening a sidebar, expanding a session, reading reports, or loading saved history
never sends a model prompt.

A supervisor-launched JSON worker **cannot be attached while running**. After it
finishes, continuation validates `IDENTITY.json` and `invocation.json` (under the
task's `quality/` directory for the quality phase), terminal state/end timestamp,
original PID/process-group absence, session header, provider/model/reasoning,
isolated `tasks/<id>/worktrees` cwd, tools and appended prompts. The session must be
a regular file inside Pi's session directory, at most 64 MiB. The original task
assignment is never replayed.

An exclusive `.worker-chat.lock` lease prevents two cooperating dashboards from
writing the same worker conversation. A stale lease fails closed and is not
stolen automatically. Independent native Pi sessions do not honor this lease;
do not manually resume a worker already loaded here.

Worker chat controls:

- **Enter**: send; while busy, steer. **Alt+Enter** queues a follow-up.
- **Alt+1 … Alt+9**: switch between workers of this chat's owning session.
- **Alt+W**: return to the sidebar. **Alt+0**, **Ctrl+D**, `/back`: return to caller.
- **PgUp/PgDn**: scroll history. **Ctrl+C**: clear the draft.
- **Esc**, `/abort`: explicitly abort this worker, not the calling agent.
- `/unload`: unload an idle worker and release its lease.

Up to nine worker RPC processes can be loaded per Pi window. Opening another
session's worker in the all-sessions view does not reassign its ownership.

`/new`, `/resume` and `/fork` are blocked while owned worker chats are busy/loading.
Quit, `/reload`, or replacement of an idle session disposes the owned RPC children
and releases leases. Background execution persists across foreground switches,
not across application exit. Shutdown fences pending reads and attachment work;
signals only target processes started by this runtime. There are no automatic
retries, relaunches, merges, deployments or approvals.

## Safety and display

Run state, ownership and report reads are size-bounded and reject escaping paths,
symlinks as final files, non-regular files and oversized inputs. Terminal control
and bidi characters are sanitized. Malformed combined quality state never falls
back to pre-quality state. Unfinished runs with a heartbeat older than 15 seconds
(or over five seconds in the future) are marked **STALE**. Review means a handoff
awaiting review, not accepted/integrated/rollout-approved.

The sidebar and reports use Pi's themed overlay components, fit narrow terminals,
and preserve the native editor. Native model menus, rich tool renderers and image
paste remain in the calling Pi session. No factory-time resources are created;
headless sessions can register runs but never create UI or polling timers.

## Installation and tests

Canonical source: `/etc/nixos/config/pi/worker-dashboard`. `home.nix` installs the
whole extension and its sibling `lib/`. A development symlink to the canonical
source loads changes with **`/reload`**, without a NixOS rebuild.

Typecheck `config/pi/tsconfig.json` and run `config/pi/tests/*.test.ts` against the
installed Pi dependencies. Tests cover ownership creation/refusal, same-directory
session isolation, all-session grouping, no legacy discovery, malformed state,
stable numbering/selection, narrow layouts, polling/shutdown fences, headless
inertness, attachment validation, process leases, RPC routing and uncertain delivery.

Native acceptance uses private sessions, offline fixtures and no real model calls:

```sh
python3 config/pi/tests/worker-dashboard-tui.py
python3 config/pi/tests/multi-session-tui.py
```

The first checks both right-hand sidebars, expansion, reports, draft preservation,
resize, new-session isolation and reload. The second checks real Pi RPC saved
histories plus deterministic concurrent worker/parent streaming and shutdown.
