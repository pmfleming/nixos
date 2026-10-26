import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { visibleWidth } from "@earendil-works/pi-tui";
import extension from "../worker-dashboard/index.ts";
import { WorkerDashboard } from "../worker-dashboard/dashboard.ts";
import { WorkerMonitor } from "../worker-dashboard/monitor.ts";
import { decodeState } from "../worker-dashboard/state.ts";
import { renderWorkerBox, WorkerSlots, workerState } from "../worker-dashboard/widget.ts";

const theme = { fg: (_color: unknown, text: string) => `\x1b[36m${text}\x1b[0m` };
function snapshot() {
  return decodeState({ run: "run-1", updated: Date.now() / 1000, tasks: {
    bt: { title: "Bluetooth 界 🦀", state: "running" },
    app: { state: "review-required", reported_status: "blocked" },
    nm: { state: "review-required", reported_status: "partial" },
  } }, "/fixture/run-1", "run-1");
}

test("worker numbers survive reorder, insertion and removal without reuse", () => {
  const slots = new WorkerSlots();
  const run = snapshot();
  slots.update(run);
  assert.equal(slots.number("app"), 1);
  assert.equal(slots.number("bt"), 2);
  run.tasks.reverse();
  run.tasks.push({ ...run.tasks[0]!, id: "aaa" });
  slots.update(run);
  assert.equal(slots.number("aaa"), 4);
  assert.equal(slots.worker(run, 2)?.id, "bt");
  run.tasks = run.tasks.filter(task => task.id !== "bt");
  assert.equal(slots.worker(run, 2), undefined);
  assert.equal(slots.number("nm"), 3);
  slots.update({ ...run, run: "run-2" });
  assert.equal(slots.number("aaa"), 1);
});

test("bottom box shows numbered states, bounded layout, stale/blocked/partial truth", () => {
  const run = snapshot();
  const slots = new WorkerSlots();
  const lines = renderWorkerBox({ snapshot: run }, slots, theme, 100).join("\n");
  assert.match(lines, /1 - Attention/);
  assert.match(lines, /2 - Running/);
  assert.match(lines, /3 - Review \(partial\)/);
  assert.match(lines, /Alt\+0 orchestrator/);
  assert.equal(workerState({ ...run.tasks[0]!, state: "failed-review-required" }), "Failed / Review");
  for (let i = 0; i < 61; i++) run.tasks.push({ ...run.tasks[0]!, id: `extra-${i}` });
  run.updated = 1;
  for (const width of [0, 1, 2, 3, 4, 8, 24, 80, 120]) {
    const rendered = renderWorkerBox({ snapshot: run }, slots, theme, width);
    assert.ok(rendered.length <= 7);
    for (const line of rendered) assert.ok(visibleWidth(line) <= width, `overflow at ${width}`);
  }
  assert.match(renderWorkerBox({ snapshot: run }, slots, theme, 100).join("\n"), /STALE.*last reported/);
  assert.match(renderWorkerBox({ error: "bad state" }, slots, theme, 100).join("\n"), /Unavailable: bad state/);
  assert.deepEqual(renderWorkerBox({}, slots, theme, 100), []);
});

test("direct worker view and local hotkeys switch details and return in one key", async () => {
  const run = snapshot();
  const monitor = new WorkerMonitor(async () => ({ snapshot: run }));
  await monitor.refresh();
  let closed = 0;
  const panel = new WorkerDashboard(monitor, theme, () => {}, () => 32, () => { closed++; }, { worker: 2 });
  try {
    assert.match(panel.render(120).join("\n"), /Worker 2 · bt/);
    panel.handleInput("\x1b3");
    assert.match(panel.render(120).join("\n"), /Worker 3 · nm/);
    panel.handleInput("\x1b9"); // unavailable number does not change selection
    assert.match(panel.render(120).join("\n"), /Worker 3 · nm/);
    panel.handleInput("\x1b0");
    assert.equal(closed, 1, "one key returns from details, not just to the list");
    const before = panel.render(120).join("\n");
    run.tasks.reverse();
    await monitor.refresh();
    assert.match(panel.render(120).join("\n"), /Worker 3 · nm/);
    assert.match(before, /read-only/);
  } finally { panel.dispose(); monitor.stop(); }
});

test("shortcut UI uses below-editor box, preserves editor, fences shutdown and concurrent opens", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-navigation-"));
  const previousRoot = process.env.PI_WORKERS_ROOT;
  process.env.PI_WORKERS_ROOT = root;
  const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
  const shortcuts = new Map<string, { handler: (ctx: ExtensionContext) => Promise<void> | void }>();
  const placements: unknown[] = [];
  const panels: WorkerDashboard[] = [];
  const notices: string[] = [];
  const ctx = { mode: "tui", sessionManager: { getSessionFile: () => undefined }, ui: {
    setStatus: () => {},
    setWidget: (_key: string, _content: unknown, options?: unknown) => { if (options) placements.push(options); },
    notify: (text: string) => { notices.push(text); },
    // There is deliberately no editor/session control API on this mock.
    custom: (factory: (tui: unknown, theme: unknown, keys: unknown, done: () => void) => WorkerDashboard) =>
      new Promise<void>(resolve => {
        let view: WorkerDashboard;
        view = factory({ requestRender: () => {}, terminal: { rows: 32 } }, theme, {}, () => { view.dispose(); resolve(); });
        panels.push(view);
      }),
  } } as unknown as ExtensionContext;
  const api = { registerCommand: () => {},
    registerShortcut: (key: string, options: { handler: (ctx: ExtensionContext) => Promise<void> | void }) => { shortcuts.set(key, options); },
    on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); },
  } as unknown as ExtensionAPI;
  const waitFor = async (predicate: () => boolean) => {
    for (let i = 0; i < 100 && !predicate(); i++) await new Promise(resolve => setTimeout(resolve, 5));
    assert.ok(predicate(), "timed out waiting for UI");
  };
  try {
    await mkdir(join(root, "run-1", "control"), { recursive: true });
    await writeFile(join(root, "run-1", "control", "state.json"), JSON.stringify({ run: "run-1", updated: Date.now() / 1000,
      tasks: { bt: { state: "running" } } }));
    extension(api);
    handlers.get("session_start")!({}, ctx);
    const opening = shortcuts.get("alt+1")!.handler(ctx);
    const duplicate = shortcuts.get("alt+1")!.handler(ctx);
    await duplicate;
    await waitFor(() => panels.length === 1);
    assert.deepEqual(placements[0], { placement: "belowEditor" });
    assert.match(panels[0]!.render(120).join("\n"), /JSON process cannot be attached/);
    shortcuts.get("alt+0")!.handler(ctx);
    await opening;
    await shortcuts.get("alt+9")!.handler(ctx);
    assert.match(notices.join("\n"), /Worker 9 is not available/);
    const pending = shortcuts.get("alt+w")!.handler(ctx);
    handlers.get("session_shutdown")!({}, ctx);
    await pending;
    assert.equal(panels.length, 1, "shutdown fences a pending open");
    handlers.get("session_start")!({}, ctx);
    const reopened = shortcuts.get("alt+w")!.handler(ctx);
    await waitFor(() => panels.length === 2);
    handlers.get("session_shutdown")!({}, ctx);
    await reopened;
  } finally {
    handlers.get("session_shutdown")?.({}, ctx);
    if (previousRoot === undefined) delete process.env.PI_WORKERS_ROOT;
    else process.env.PI_WORKERS_ROOT = previousRoot;
    await rm(root, { recursive: true, force: true });
  }
});
