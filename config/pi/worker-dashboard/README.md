# Worker dashboard and multi-session chat runtime

Personal Pi extension for the local orchestration supervisor. It adds a compact
bottom status box, read-only handoff reports, and independently running worker
chats. It coexists with the recent-sessions sidebar.

Run `/reload` to load the extension/update in the calling Pi chat.

## Foreground/background chats

- **Alt+1 … Alt+9**: foreground that worker's actual conversation and input editor.
  The first visit loads its completed session into a separate, long-lived Pi RPC
  process. Later visits reuse that process, including when it is busy.
- **Alt+0**: return to the calling/orchestrator chat. This detaches the worker
  chat surface; it does **not** abort, pause or dispose any loaded worker.
- **Alt+W**: open the read-only worker reports/list. From a worker chat it returns
  to that list without stopping worker activity.
- Each worker retains its own draft, transcript, pending work and history scroll.
  The orchestrator retains its original native editor draft and continues its
  own agent loop behind the foreground worker surface.
- Enter sends to the foreground worker only. During work it steers; Alt+Enter
  queues a follow-up. Sending is never triggered just by opening/switching chats.
- Escape explicitly clears the selected worker's queue and aborts that worker;
  queued text is restored in its draft. It never aborts the orchestrator.
- PageUp/PageDown scroll worker history. Ctrl+C clears its draft; Ctrl+D returns
  to the orchestrator without stopping workers.

This is an extension-hosted multi-session runtime, not native `switchSession()`:
that Pi API disposes the previous agent. A full-window foreground surface presents
worker text, streaming responses, tool activity/results, errors and a multiline
editor while the native calling session stays alive. Native Pi menus, image paste,
rich tool renderers and provider/model selection remain in the orchestrator; they
are not silently forwarded as model prompts in worker chats. The worker surface
supports `/back`, `/abort`, `/unload`.

Nine worker processes can be loaded at once. A loaded idle worker is not executing
another model request. Worker history remains in its saved session; the display
keeps a bounded tail (100 messages / 256K characters, 16K per displayed message).

## Existing workers and ownership

A live legacy `--mode json` worker has no bidirectional control channel. Such a
worker is **refused**, not reopened, stopped or duplicated. Once it has completed,
Alt+number can load its saved conversation. RPC workers already owned by this
runtime can be foregrounded/backgrounded while running.

Loading validates the task/phase identity, session header, provider/model/reasoning,
isolated worktree cwd and original invocation. The terminal state must include an
end timestamp and the original worker PIDs/process groups must no longer exist. The session must
be a regular file inside Pi's configured session directory, at most 64 MiB. A
cooperating-runtime exclusive `.worker-chat.lock` lease prevents two dashboard
instances from owning the same session. Crash-left leases fail closed and require
manual investigation; no age-based lock stealing is used. Native Pi launched
independently does not honor this extension's lease: do not manually resume a
session already loaded here.

RPC launch preserves the worker's provider/model/reasoning, allowed built-in tools,
original appended system prompts and isolated worktree. It reconstructs the
orchestration task/root environment and build-job limit. Parent `PI_SESSION_*`
identity is removed. Extensions, MCP, skills and prompt templates stay disabled,
as in the original workers. The original assignment `@PROMPT.md` is **never
replayed**. No model call happens until you explicitly send a message.

No automatic retries/relaunches, merges, deployment, scope expansion or approvals
are introduced. A prompt with an uncertain acknowledgement is not automatically
resent. Reports and historical supervisor handoff states are not rewritten by the
runtime. Live `Chat running` / `Chat idle` labels are separate from those handoffs.

## Reports, run selection and lifecycle

- `/workers`: read-only live task list; Enter opens progress. `p` progress, `r`
  report, `l` diagnostics; arrows/PageUp/PageDown scroll; Escape goes back/closes.
  Alt+number from the reports opens the corresponding chat.
- `/workers chat N`: foreground a worker, including numbers beyond 9.
- `/workers unload N`: close an idle worker chat and release its lease. A busy
  worker must be explicitly aborted first.
- `/workers close-chats`: dispose all owned RPC workers; asks for confirmation if
  activity/startup is in progress. This is different from Alt+0.
- `/workers hide` / `/workers show`: disable/enable the automatic bottom box.
  It appears only while workers are running/stopping or loaded chats are opening/running;
  queued-only, completed, idle, missing and unavailable runs do not keep it visible.
  Reports and chat shortcuts remain available when the box is hidden.
- `/workers runs`, `/workers latest`, `/workers RUN-ID`: select a run. Unknown or
  unavailable IDs leave selection unchanged. Unload/close loaded chats first.

Numbers remain stable across polling/reordering/insertion while following a run;
a new run/reload assigns from sorted task IDs. Reports and chat headers include
the original task ID. The box limits rows and shows a `+N more` hint as needed.
Its labels refresh every two seconds; loaded chat activity also updates immediately.
The box omits the summary heading, duplicate footer counts and worker/list shortcut
hints, retaining only numbered states and the Alt+0 orchestrator hint. Review never means accepted/integrated/rollout-approved.

Native `/new`, `/resume` and `/fork` are blocked while workers are busy/loading.
**Quit, `/reload`, or replacement of an idle calling session ends this runtime**:
all owned children are disposed and leases released. Background persistence means
across Alt+number/Alt+0 switches, not across application exit/reload. Pending
startup/read completions are fenced. EOF requests orderly RPC shutdown; bounded
TERM/KILL escalation targets only owned process groups. Unexpected child exits do
not exit the orchestrator. Nothing sends signals to legacy supervisor workers.

## Source contract

`PI_WORKERS_ROOT` selects the orchestration parent directory; default:
`~/Projects/shelllist-orchestration`. Newest run directory is selected by name
unless pinned. Each supplies supervisor `control/state.json`; combined quality
`control/dashboard.json` takes precedence when present. Malformed/latest missing
state is unavailable, never silently replaced by older/pre-quality success.

An unfinished run with heartbeat older than 15 seconds, or over five seconds in
the future, is marked **STALE / last reported**. Terminal handoffs need no continuing
heartbeat. Report views read bounded task `PROGRESS.md`, `REPORT.md`, `stderr.log`;
chat loading additionally reads validated identity/invocation/session-header
metadata and obtains conversation history through its RPC child. Arbitrary
state-provided paths, escaping symlinks, non-regular files and oversized input are
rejected. Worker-controlled terminal/bidi controls are sanitized for display.
Credentials are not read or displayed by the extension; the normal Pi child
resolves its own configured authentication. Resource acquisition is TUI-only.

## Installation and tests

Canonical source: `/etc/nixos/config/pi/worker-dashboard`. The personal development
symlink loads it immediately after `/reload`; `home.nix` declares the whole
extension directory for Home Manager. No NixOS rebuild is needed for that symlink.

Typecheck `config/pi/tsconfig.json` and run `config/pi/tests/*.test.ts` against the
installed Pi package's dependencies, not another npm version. Tests cover bounded
filesystem reads, attachment metadata, ownership leases, legacy-live refusal,
headless inertness, stable numbering, RPC framing/response correlation, uncertain
delivery, per-chat routing/drafts, background streaming, fast settlement,
startup/shutdown fences and narrow Unicode layouts.

Explicit native acceptance (private fixtures, no real model calls):

```sh
python3 config/pi/tests/worker-dashboard-tui.py
python3 config/pi/tests/multi-session-tui.py
```

The latter boots real Pi RPC children to check saved-history loading, process reuse,
foreground switching and drafts, then deterministic RPC workers and a local fake
provider to exercise the calling agent's real loop continuing behind worker chats,
concurrent background completion and selected-chat-only prompt routing. These
checks do not certify every terminal emulator, provider or real worker task.
