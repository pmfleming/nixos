import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { visibleWidth } from "@earendil-works/pi-tui";
import extension from "../worker-dashboard/index.ts";
import { WorkerDashboard } from "../worker-dashboard/dashboard.ts";
import { WorkerMonitor } from "../worker-dashboard/monitor.ts";
import { createRun } from "../worker-dashboard/ownership.ts";
const owner = { version: 1 as const, sessionId: "parent-session", name: "Parent", cwd: "/fixture", created: 1 };
import { counts, decodeState, detail, listRuns, observe, plain, stale, summary } from "../worker-dashboard/state.ts";

function state() {
  return { run: "run-1", provider: "openai-codex", model: "gpt-6.1-sol", thinking: "high", updated: 100,
    tasks: { bt: { title: "Bluetooth 界 🦀", state: "running", started: 80, last_event_at: 99, tools: 12, turns: 3, model_verified: true },
      nm: { title: "Networking", state: "queued" },
      clip: { title: "Clipboard", state: "review-required", reported_status: "partial" },
      app: { title: "Application", state: "review-required", reported_status: "blocked" } } };
}
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "pi-workers-"));
  const run = await createRun(root, "run-1", owner);
  await mkdir(join(run, "tasks", "bt"), { recursive: true });
  await writeFile(join(run, "control", "state.json"), JSON.stringify(state()));
  await writeFile(join(run, "tasks", "bt", "PROGRESS.md"), "Inspecting the fixture\nNo live effects.\n");
  return { root, run, cleanup: () => rm(root, { recursive: true, force: true }) };
}

test("counts preserve blocked/partial review and distinguish stale active from completed", () => {
  const snapshot = decodeState(state(), "/fixture/run-1", "run-1");
  assert.deepEqual(counts(snapshot), { running: 1, queued: 1, review: 1, attention: 1 });
  assert.equal(stale(snapshot, 110), false);
  assert.equal(stale(snapshot, 120), true);
  assert.match(summary(snapshot, 120), /STALE.*last reported/);
  assert.equal(stale(snapshot, 90), true, "future timestamps cannot look fresh");
  snapshot.tasks.forEach(task => { task.state = "review-required"; });
  assert.equal(stale(snapshot, 10000), false, "finished supervisor need not heartbeat forever");
  snapshot.tasks[0]!.state = "mystery";
  assert.ok(counts(snapshot).attention > 1);
});

test("strict state validation and terminal control sanitization", () => {
  assert.throws(() => decodeState({ ...state(), run: "other" }, "/fixture", "run-1"), /identity/);
  assert.throws(() => decodeState({ ...state(), updated: NaN }, "/fixture", "run-1"), /timestamp/);
  assert.throws(() => decodeState({ ...state(), tasks: { "../escape": {} } }, "/fixture", "run-1"), /identifier/);
  assert.throws(() => decodeState({ ...state(), tasks: { x: { tools: 1.5 } } }, "/fixture", "run-1"), /count/);
  assert.equal(/[\x00-\x1f\x7f-\x9f\u202e]/.test(plain("\x1b]52;c;secret\x07\r\u202eevil")), false);
  const snapshot = decodeState({ ...state(), tasks: { a: { model_verified: "true" } } }, "/fixture", "run-1");
  assert.equal(snapshot.tasks[0]!.modelVerified, false);
});

test("bounded reader ignores state-provided paths and refuses escaping details", async () => {
  const f = await fixture();
  try {
    const data = state();
    Object.assign(data.tasks.bt, { directory: "/etc" });
    await writeFile(join(f.run, "control", "state.json"), JSON.stringify(data));
    const snapshot = (await observe(f.root)).snapshot!;
    assert.match(await detail(snapshot, "bt", "PROGRESS.md"), /Inspecting the fixture/);
    const outside = join(f.root, "private.txt");
    await writeFile(outside, "must not be displayed");
    await symlink(outside, join(f.run, "tasks", "bt", "REPORT.md"));
    await assert.rejects(detail(snapshot, "bt", "REPORT.md"), /escapes/);
    await assert.rejects(detail(snapshot, "../escape", "PROGRESS.md"), /identifier/);
    await writeFile(join(f.run, "tasks", "bt", "stderr.log"), "x".repeat(32769));
    await assert.rejects(detail(snapshot, "bt", "stderr.log"), /display limit/);
    await writeFile(join(f.run, "control", "state.json"), "x".repeat(262145));
    assert.match((await observe(f.root)).error!, /display limit/);
  } finally { await f.cleanup(); }
});

test("missing/partial/latest-invalid files are explicit, never silently older state", async () => {
  const f = await fixture();
  try {
    assert.deepEqual(await observe(join(f.root, "missing")), {});
    await createRun(f.root, "run-2", owner);
    await writeFile(join(f.root, "run-2", "control", "state.json"), "{");
    const broken = await observe(f.root);
    assert.ok(broken.error); assert.equal(broken.snapshot, undefined);
    assert.equal((await observe(f.root, "run-1")).snapshot?.run, "run-1");
    assert.match((await observe(f.root, "../escape")).error!, /identifier/);
  } finally { await f.cleanup(); }
});

test("discovery ignores unrelated and legacy directories", async () => {
  const f = await fixture();
  try {
    await mkdir(join(f.root, "agenda-20261027", "control"), { recursive: true });
    for (let i = 0; i < 40; i++) await mkdir(join(f.root, `z-unrelated-${i}`));
    assert.deepEqual(await listRuns(f.root), ["run-1"]);
    assert.equal((await observe(f.root)).snapshot?.run, "run-1");
    assert.ok((await observe(f.root, "agenda-20261027")).error,
      "explicit selection of unavailable directories still reports an error");
    await rm(f.run, { recursive: true });
    assert.deepEqual(await observe(f.root), {});
  } finally { await f.cleanup(); }
});

test("owned runs remain discoverable before state exists; timestamps are not ownership", async () => {
  const f = await fixture();
  try {
    await rm(f.run, { recursive: true });
    const oldRun = "20261027T214423Z";
    const newRun = "20261028T010000Z";
    await createRun(f.root, oldRun, owner);
    await writeFile(join(f.root, oldRun, "control", "state.json"), JSON.stringify({ ...state(), run: oldRun }));
    await mkdir(join(f.root, "agenda-20261027", "control"), { recursive: true });
    assert.equal((await observe(f.root)).snapshot?.run, oldRun);
    await mkdir(join(f.root, newRun));
    assert.deepEqual(await listRuns(f.root), [oldRun]);
    await rm(join(f.root, newRun), { recursive: true });
    await createRun(f.root, newRun, owner);
    assert.deepEqual(await listRuns(f.root), [newRun, oldRun]);
    assert.match((await observe(f.root)).error!, /ENOENT/);
    assert.equal((await observe(f.root, oldRun)).snapshot?.run, oldRun);
  } finally { await f.cleanup(); }
});

test("owned named runs with broken state are not silently skipped", async () => {
  const f = await fixture();
  try {
    const run = await createRun(f.root, "run-2", owner);
    assert.deepEqual(await listRuns(f.root), ["run-2", "run-1"]);
    assert.match((await observe(f.root)).error!, /ENOENT/);
    for (const name of ["state.json", "dashboard.json"]) {
      const path = join(run, "control", name);
      await symlink(join(run, "missing.json"), path);
      assert.deepEqual(await listRuns(f.root), ["run-2", "run-1"]);
      assert.match((await observe(f.root)).error!, /ENOENT/);
      await rm(path);
    }
    await writeFile(join(run, "control", "dashboard.json"), JSON.stringify({ ...state(), run: "run-2" }));
    assert.equal((await observe(f.root)).snapshot?.run, "run-2", "dashboard-only named runs are supported");
  } finally { await f.cleanup(); }
});

test("quality view takes precedence and cannot fall back to pre-quality completion", async () => {
  const f = await fixture();
  try {
    const data = state();
    Object.assign(data.tasks.bt, { phase: "quality", state: "queued", model_verified: false });
    const path = join(f.run, "control", "dashboard.json");
    await writeFile(path, JSON.stringify(data));
    const snapshot = (await observe(f.root)).snapshot!;
    assert.equal(snapshot.tasks[0]!.phase, "quality");
    assert.equal(snapshot.tasks[0]!.state, "queued");
    assert.equal(snapshot.tasks[0]!.modelVerified, false);
    await writeFile(path, "{");
    assert.ok((await observe(f.root)).error, "invalid quality state must remain visible");
    await rm(path);
    await symlink(join(f.run, "missing-dashboard.json"), path);
    assert.ok((await observe(f.root)).error, "dangling combined-state link cannot hide required quality work");
  } finally { await f.cleanup(); }
});

test("monitor coalesces reads and fences shutdown/replacement completions", async () => {
  let release!: (value: {}) => void;
  let reads = 0;
  const monitor = new WorkerMonitor(() => { reads++; return new Promise(resolve => { release = resolve; }); });
  let publications = 0;
  const unsubscribe = monitor.subscribe(() => { publications++; });
  const first = monitor.refresh();
  assert.equal(monitor.refresh(), first); assert.equal(reads, 1);
  monitor.stop(); release({}); await first;
  assert.equal(publications, 1, "only subscription's initial value, no late publication");
  const second = monitor.refresh(); release({}); await second;
  assert.equal(publications, 2);
  unsubscribe(); monitor.stop();
});

test("dashboard resizes, sanitizes and reads details without resuming a session", async () => {
  const f = await fixture();
  try {
    const monitor = new WorkerMonitor(() => observe(f.root));
    await monitor.refresh();
    let rows = 28;
    let redraws = 0;
    let closed = 0;
    const panel = new WorkerDashboard(monitor, { fg: (_color, text) => `\x1b[36m${text}\x1b[0m` },
      () => { redraws++; }, () => rows, () => { closed++; });
    for (const width of [1, 8, 24, 80, 120]) {
      for (const line of panel.render(width)) assert.ok(visibleWidth(line) <= width, `overflow at ${width}`);
    }
    panel.handleInput("\r");
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.match(panel.render(120).join("\n"), /Inspecting the fixture/);
    rows = 6;
    assert.ok(panel.render(20).length <= 4);
    panel.handleInput("\x1b"); // back from details
    panel.handleInput("\x1b"); // close dashboard
    assert.equal(closed, 1);
    panel.dispose(); monitor.stop();
    const before = redraws;
    await monitor.refresh();
    assert.equal(redraws, before, "disposed panel cannot receive late updates");
  } finally { await f.cleanup(); }
});

test("extension remains inert in non-TUI lifecycle modes", async () => {
  const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
  const commands: string[] = [];
  const shortcuts = new Map<string, { handler: (ctx: ExtensionContext) => unknown }>();
  const api = { registerTool: () => {}, registerCommand: (name: string) => { commands.push(name); },
    registerShortcut: (key: string, options: { handler: (ctx: ExtensionContext) => unknown }) => { shortcuts.set(key, options); },
    on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); } };
  extension(api as unknown as ExtensionAPI);
  assert.deepEqual(commands, ["workers", "workers-all"]);
  assert.equal(shortcuts.size, 11);
  for (const mode of ["json", "print", "rpc"]) {
    const ctx = { mode, ui: new Proxy({}, { get: () => { throw new Error("headless UI accessed"); } }) };
    handlers.get("session_start")!({}, ctx as unknown as ExtensionContext);
    for (const shortcut of shortcuts.values()) await shortcut.handler(ctx as unknown as ExtensionContext);
    handlers.get("session_shutdown")!({}, ctx as unknown as ExtensionContext);
  }
});
