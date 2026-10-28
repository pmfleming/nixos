import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { visibleWidth, type Component } from "@earendil-works/pi-tui";
import extension from "../worker-dashboard/index.ts";
import { CatalogMonitor, CatalogSlots, type Catalog } from "../worker-dashboard/catalog.ts";
import { createRun } from "../worker-dashboard/ownership.ts";
import { WorkersSidebar, type SidebarAction } from "../worker-dashboard/sidebar.ts";
import { decodeState } from "../worker-dashboard/state.ts";
import { WorkerSlots } from "../worker-dashboard/widget.ts";

const theme = { fg: (_color: unknown, text: string) => `\x1b[36m${text}\x1b[0m` };
function catalog(): Catalog {
  const snapshot = decodeState({ run: "run-1", updated: Date.now() / 1000, tasks: {
    bt: { title: "Bluetooth 界 🦀", state: "running" },
    nm: { title: "Networking", state: "queued" },
  } }, "/fixture/run-1", "run-1");
  return { errors: [], groups: [
    { id: "owner-a", name: "Session A", cwd: "/same-project", current: true, modified: 1, errors: [], workers: snapshot.tasks.map((task, index) =>
      ({ key: `${snapshot.run}/${task.id}`, ownerId: "owner-a", snapshot, task, number: index + 1 })) },
    { id: "owner-b", name: "Session B", cwd: "/same-project", current: false, modified: 1, errors: [], workers: [
      { key: "run-2/b", ownerId: "owner-b", snapshot: { ...snapshot, run: "run-2" }, task: { ...snapshot.tasks[0]!, id: "b", title: "Other worker" }, number: 1 }] },
    { id: "owner-c", name: "Empty session", cwd: "/other", current: false, modified: 1, errors: [], workers: [] },
  ] };
}

test("worker numbers are stable and separate for each owning session", () => {
  const slots = new CatalogSlots();
  assert.equal(slots.number("a", "run-1/a"), 1);
  assert.equal(slots.number("a", "run-2/a"), 2);
  assert.equal(slots.number("b", "run-3/a"), 1);
  assert.equal(slots.number("a", "run-1/a"), 1);
  const run = catalog().groups[0]!.workers[0]!.snapshot;
  const reports = new WorkerSlots(); reports.update(run);
  run.tasks.reverse(); reports.update(run);
  assert.equal(reports.worker(run, 1)?.id, "bt");
});

test("session sidebar excludes other sessions; all view expands each session independently", async () => {
  const data = catalog();
  const monitor = new CatalogMonitor(async () => data);
  await monitor.refresh();
  const actions: SidebarAction[] = [];
  let closed = 0, redraws = 0, height = 24;
  const local = new WorkersSidebar(monitor, "session", "owner-a", theme, () => height, () => redraws++, () => closed++, action => actions.push(action));
  const all = new WorkersSidebar(monitor, "all", "owner-a", theme, () => height, () => redraws++, () => closed++, action => actions.push(action));
  try {
    assert.match(local.render(150).join("\n"), /Bluetooth/);
    assert.doesNotMatch(local.render(150).join("\n"), /Other worker|Session B|Empty session/);
    local.handleInput("\r");
    assert.equal(actions.at(-1)?.kind, "chat");
    assert.equal((actions.at(-1) as { worker: { ownerId: string } }).worker.ownerId, "owner-a");
    let text = all.render(150).join("\n");
    assert.match(text, /Session B/); assert.match(text, /Empty session/);
    assert.doesNotMatch(text, /Other worker/);
    // Collapse A, then expand B. Enter never opens a parent session as a worker.
    all.handleInput("\x1b[D"); all.handleInput("\x1b[B"); all.handleInput("\r");
    text = all.render(150).join("\n");
    assert.match(text, /Other worker/); assert.doesNotMatch(text, /Bluetooth/);
    const before = actions.length;
    assert.equal(before, 1);
    all.handleInput("\x1b[B"); all.handleInput("r");
    assert.equal(actions.at(-1)?.kind, "report");
    assert.equal((actions.at(-1) as { worker: { ownerId: string } }).worker.ownerId, "owner-b");
    data.groups.reverse(); await monitor.refresh();
    all.handleInput("\r");
    assert.equal((actions.at(-1) as { worker: { ownerId: string } }).worker.ownerId, "owner-b", "polling must not redirect the selection");
    for (height of [1, 4, 10, 24]) for (const width of [0, 1, 4, 12, 64, 120]) {
      const lines = all.render(width);
      assert.ok(lines.length <= height);
      for (const line of lines) assert.ok(visibleWidth(line) <= width, `overflow ${width}x${height}`);
    }
    local.handleInput("\x1b"); assert.equal(closed, 1);
    local.dispose(); all.dispose(); const previous = redraws;
    await monitor.refresh(); assert.equal(redraws, previous);
  } finally { local.dispose(); all.dispose(); monitor.stop(); }
});

test("two commands use right sidebars with no bottom box; registration binds the actual session", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-navigation-"));
  const previousRoot = process.env.PI_WORKERS_ROOT;
  process.env.PI_WORKERS_ROOT = root;
  type Handler = (ctx: ExtensionContext) => Promise<void> | void;
  const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
  const shortcuts = new Map<string, { handler: Handler }>();
  const commands = new Map<string, { handler: (args: string, ctx: ExtensionContext) => Promise<void> }>();
  let registerTool: { execute: (...args: any[]) => Promise<unknown> } | undefined;
  const panels: Component[] = [], notices: string[] = [], options: any[] = [];
  let sessionId = "owner-a";
  const ctx = { mode: "tui", cwd: "/fixture", sessionManager: {
    getSessionFile: () => undefined, getSessionId: () => sessionId, getSessionName: () => "Fixture",
  }, ui: {
    setStatus: (_key: string, value: unknown) => assert.equal(value, undefined),
    setWidget: (_key: string, value: unknown) => assert.equal(value, undefined, "no bottom widget"),
    notify: (text: string) => { notices.push(text); },
    custom: (factory: (tui: unknown, theme: unknown, keys: unknown, done: () => void) => Component, opts: unknown) =>
      new Promise<void>(resolve => {
        let view: Component;
        view = factory({ requestRender: () => {}, terminal: { rows: 32 } }, theme, {}, () => { (view as Component & { dispose?: () => void }).dispose?.(); resolve(); });
        panels.push(view); options.push(opts);
      }),
  } } as unknown as ExtensionContext;
  const api = { registerCommand: (name: string, options: any) => commands.set(name, options),
    registerTool: (tool: any) => { registerTool = tool; },
    registerShortcut: (key: string, options: { handler: Handler }) => shortcuts.set(key, options),
    on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => handlers.set(name, handler),
  } as unknown as ExtensionAPI;
  const waitFor = async (predicate: () => boolean) => {
    for (let i = 0; i < 200 && !predicate(); i++) await new Promise(resolve => setTimeout(resolve, 5));
    assert.ok(predicate(), "timed out waiting for UI");
  };
  try {
    extension(api);
    assert.deepEqual([...commands.keys()], ["workers", "workers-all"]);
    await registerTool!.execute("id", { run: "run-a" }, undefined, undefined, ctx);
    await writeFile(join(root, "run-a/control/state.json"), JSON.stringify({ run: "run-a", updated: Date.now() / 1000, tasks: { bt: { state: "running", title: "A_WORKER" } } }));
    await createRun(root, "run-b", { version: 1, sessionId: "owner-b", name: "B", cwd: "/fixture", created: 1 });
    await writeFile(join(root, "run-b/control/state.json"), JSON.stringify({ run: "run-b", updated: Date.now() / 1000, tasks: { bt: { state: "running", title: "B_WORKER" } } }));
    handlers.get("session_start")!({}, ctx);
    const opening = commands.get("workers")!.handler("", ctx);
    await waitFor(() => panels.length === 1);
    assert.equal(options[0].overlayOptions.anchor, "right-center");
    assert.match(panels[0]!.render(120).join("\n"), /A_WORKER/);
    assert.doesNotMatch(panels[0]!.render(120).join("\n"), /B_WORKER/);
    shortcuts.get("alt+0")!.handler(ctx); await opening;
    await shortcuts.get("alt+9")!.handler(ctx);
    assert.match(notices.join("\n"), /not associated/);
    const pending = commands.get("workers")!.handler("", ctx);
    await handlers.get("session_shutdown")!({}, ctx); await pending;
    assert.equal(panels.length, 1, "shutdown fences pending sidebar creation");
    sessionId = "owner-b";
    handlers.get("session_start")!({}, ctx);
    const second = commands.get("workers")!.handler("", ctx);
    await waitFor(() => panels.length === 2);
    assert.match(panels[1]!.render(120).join("\n"), /B_WORKER/);
    assert.doesNotMatch(panels[1]!.render(120).join("\n"), /A_WORKER/);
    await handlers.get("session_shutdown")!({}, ctx); await second;
  } finally {
    await handlers.get("session_shutdown")?.({}, ctx);
    if (previousRoot === undefined) delete process.env.PI_WORKERS_ROOT; else process.env.PI_WORKERS_ROOT = previousRoot;
    await rm(root, { recursive: true, force: true });
  }
});
