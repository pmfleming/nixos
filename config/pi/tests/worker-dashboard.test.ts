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
import { counts, decodeState, detail, observe, plain, stale, summary } from "../worker-dashboard/state.ts";

function state() {
  return { run: "run-1", provider: "openai-codex", model: "gpt-6.1-sol", thinking: "high", updated: 100,
    tasks: { bt: { title: "Bluetooth 界 🦀", state: "running", started: 80, last_event_at: 99, tools: 12, turns: 3, model_verified: true },
      nm: { title: "Networking", state: "queued" },
      clip: { title: "Clipboard", state: "review-required", reported_status: "partial" },
      app: { title: "Application", state: "review-required", reported_status: "blocked" } } };
}
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "pi-workers-"));
  const run = join(root, "run-1");
  await mkdir(join(run, "control"), { recursive: true });
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
    await mkdir(join(f.root, "run-2", "control"), { recursive: true });
    await writeFile(join(f.root, "run-2", "control", "state.json"), "{");
    const broken = await observe(f.root);
    assert.ok(broken.error); assert.equal(broken.snapshot, undefined);
    assert.equal((await observe(f.root, "run-1")).snapshot?.run, "run-1");
    assert.match((await observe(f.root, "../escape")).error!, /identifier/);
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
  const api = { registerCommand: (name: string) => { commands.push(name); },
    registerShortcut: (key: string, options: { handler: (ctx: ExtensionContext) => unknown }) => { shortcuts.set(key, options); },
    on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); } };
  extension(api as unknown as ExtensionAPI);
  assert.deepEqual(commands, ["workers"]);
  assert.equal(shortcuts.size, 11);
  for (const mode of ["json", "print", "rpc"]) {
    const ctx = { mode, ui: new Proxy({}, { get: () => { throw new Error("headless UI accessed"); } }) };
    handlers.get("session_start")!({}, ctx as unknown as ExtensionContext);
    for (const shortcut of shortcuts.values()) await shortcut.handler(ctx as unknown as ExtensionContext);
    handlers.get("session_shutdown")!({}, ctx as unknown as ExtensionContext);
  }
});
