import assert from "node:assert/strict";
import test from "node:test";
import { chmod, mkdir, mkdtemp, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { ExtensionAPI, ExtensionContext, KeybindingsManager, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, visibleWidth } from "@earendil-works/pi-tui";
import extension from "../instances/index.ts";
import { errorCode, isRecord, object, requireObject, strings } from "../lib/data.ts";
import { fitLines, selectTheme, workerShortcut } from "../lib/tui.ts";
import { discoverProcesses, mergeInventory, parseLog, parseStat, type LocalProcess } from "../instances/discovery.ts";
import { decodeRecord, plain, STALE_MS, telemetryRow, textContent, type InstanceRecord, type FleetSnapshot } from "../instances/model.ts";
import { Publisher } from "../instances/publisher.ts";
import { privateDirectory, readRecord, records, writeRecord } from "../instances/storage.ts";
import { InstancesView } from "../instances/view.ts";

const processInfo: LocalProcess = { pid: 123, ppid: 50, startTicks: "123456", bootId: "test-boot", comm: "pi", state: "S", cwd: "/project" };
function record(now = Date.now()): InstanceRecord {
  return { ...processInfo, version: 1, token: "runtime-1", registeredAt: now - 5000, updatedAt: now,
    lastActivityAt: now - 1000, sessionId: "session-one", sessionFile: "/saved/session.jsonl", name: "Fixture 界 🦀", cwd: "/project",
    mode: "tui", model: "fixture/model", state: "working", tools: ["read", "bash"], turns: 4, toolCount: 8,
    prompt: "Investigate the fixture", progress: "Checking tests", events: [{ at: now - 1000, text: "Tool started: read" }] };
}
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "pi-instances-test-"));
  return { root, cleanup: () => rm(root, { recursive: true, force: true }) };
}
const theme = { fg: (_color: string, text: string) => text } as Theme;
const keys = { matches: (data: string, action: string) => {
  const key = ({ "tui.select.up": "up", "tui.select.down": "down", "tui.select.cancel": "escape", "tui.select.confirm": "return" } as Record<string, string>)[action];
  return key ? matchesKey(data, key as Parameters<typeof matchesKey>[1]) : false;
} } as KeybindingsManager;

test("shared guards reject non-records and UI helpers preserve keys, colors and bounds", () => {
  for (const value of [null, undefined, 0, "text", []]) {
    assert.equal(isRecord(value), false); assert.deepEqual(object(value), {});
    assert.throws(() => requireObject(value));
  }
  assert.equal(errorCode(Object.assign(new Error("missing"), { code: "ENOENT" })), "ENOENT");
  assert.equal(errorCode(null), undefined);
  assert.ok(strings(["a", "b"])); assert.ok(!strings(["a", 1]));
  assert.equal(workerShortcut("\x1b9"), 9); assert.equal(workerShortcut("\x1b0"), undefined);
  assert.equal(selectTheme(theme).selectedText("label"), "label");
  assert.ok(fitLines(["界界界", "second"], 3, 1).every(line => visibleWidth(line) <= 3));
});

test("process stat parser handles parentheses/spaces and checks start identity", () => {
  const values = ["S", "50", ...Array(17).fill("0"), "123456", "0"];
  const parsed = parseStat(`123 (pi (worker)) ${values.join(" ")}`);
  assert.equal(parsed.comm, "pi (worker)");
  assert.equal(parsed.startTicks, "123456");
  assert.equal(parsed.ppid, 50);
  assert.throws(() => parseStat("broken"));
});

test("inventory matches boot + PID + start ticks, not inherited session identity", () => {
  const now = Date.now();
  const current = record(now);
  let rows = mergeInventory([{ ...processInfo, parentHint: "parent-session" }], [current], now);
  assert.equal(rows[0]!.sessionId, "session-one");
  assert.equal(rows[0]!.parentHint, "parent-session");
  assert.equal(rows[0]!.status, "working");
  rows = mergeInventory([{ ...processInfo, startTicks: "new-process" }], [current], now);
  assert.equal(rows.find(row => row.status !== "exited")!.source, "process");
  assert.equal(rows.find(row => row.status === "exited")!.sessionId, "session-one");
  rows = mergeInventory([{ ...processInfo, bootId: "new-boot" }], [current], now);
  assert.equal(rows[0]!.sessionId, undefined);
});

test("reload/session replacement chooses newest registration and cannot claim stale work is live", () => {
  const now = Date.now();
  const current = record(now);
  const replacement = { ...current, token: "new-runtime", registeredAt: now, sessionId: "new-session", state: "idle" as const };
  const rows = mergeInventory([processInfo], [{ ...current, updatedAt: now + 1, endedAt: now }, replacement], now);
  assert.equal(rows.length, 1);
  assert.equal(rows[0]!.sessionId, "new-session");
  assert.equal(rows[0]!.status, "idle");
  assert.equal(telemetryRow(current, true, now + STALE_MS + 1).status, "stale");
  assert.equal(telemetryRow({ ...current, updatedAt: now + 9000 }, true, now).status, "stale");
  assert.equal(telemetryRow({ ...current, endedAt: now }, true, now).status, "stale");
  assert.equal(telemetryRow(current, false, now).status, "exited");
  assert.match(telemetryRow(current, false, now).note, /not proof of task completion/);
  assert.equal(mergeInventory([], [current], now + 11 * 60_000).length, 0);
});

test("sanitization and decoding bound untrusted fields and exclude thinking", () => {
  assert.equal(plain("\x1b]52;c;secret\x07hello\x1b[31m\u202eevil\nworld"), "hello evil world");
  assert.equal(textContent([{ type: "thinking", thinking: "PRIVATE" }, { type: "text", text: "visible" }]), "visible");
  assert.equal(decodeRecord({ ...record(), prompt: "x".repeat(9000) }).prompt.length, 400);
  assert.throws(() => decodeRecord({ ...record(), pid: -1 }));
  assert.throws(() => decodeRecord({ ...record(), updatedAt: Infinity }));
  assert.throws(() => decodeRecord({ ...record(), state: "invented" }));
});

test("private atomic registry validates regular owned bounded files and rejects symlinks", async () => {
  const f = await fixture();
  try {
    await privateDirectory(f.root);
    await writeRecord(f.root, record());
    assert.equal((await records(f.root)).records.length, 1);
    const path = join(f.root, (await readdir(f.root))[0]!);
    await symlink(path, join(f.root, "symlink.json"));
    await assert.rejects(readRecord(join(f.root, "symlink.json")));
    await writeFile(join(f.root, "huge.json"), "x".repeat(33 * 1024), { mode: 0o600 });
    assert.match((await records(f.root)).warnings[0]!, /2 invalid/);
    await chmod(f.root, 0o755);
    await assert.rejects(privateDirectory(f.root), /private/);
  } finally { await f.cleanup(); }
});

test("publisher tracks parallel tools, UI waiting and settlement without exposing tool arguments", async () => {
  const f = await fixture();
  try {
    const publisher = new Publisher(f.root, processInfo, message => assert.fail(message));
    await publisher.start();
    publisher.startRun("The assignment");
    publisher.turn();
    publisher.toolStart("one", "read"); publisher.toolStart("two", "bash");
    publisher.toolEnd("one", "read", false);
    assert.deepEqual(publisher.record.tools, ["bash"]);
    publisher.promptUI(true, false);
    assert.equal(publisher.record.state, "waiting");
    publisher.promptUI(false, false);
    assert.equal(publisher.record.state, "working");
    publisher.stream("Visible commentary");
    publisher.stream(); // Thinking or output liveness only.
    assert.equal(publisher.record.progress, "Visible commentary");
    publisher.settled(true);
    assert.equal(publisher.record.state, "idle");
    assert.deepEqual(publisher.record.tools, []);
    await publisher.flush();
    assert.equal((await records(f.root)).records[0]!.prompt, "The assignment");
    await publisher.stop(); await publisher.stop();
    assert.ok((await records(f.root)).records[0]!.endedAt);
    assert.equal((await readdir(f.root)).filter(name => name.endsWith(".tmp")).length, 0);
  } finally { await f.cleanup(); }
});

test("legacy JSON log observer ignores incomplete lines, outputs and thinking; never infers idle", () => {
  const header = JSON.stringify({ type: "session", id: "logged-session" }) + "\n";
  const tail = [
    JSON.stringify({ type: "tool_execution_start", toolName: "bash", args: { command: "SECRET" } }),
    JSON.stringify({ type: "message_end", message: { role: "assistant", model: "model", content: [{ type: "thinking", thinking: "PRIVATE" }, { type: "text", text: "Running tests" }] } }),
    JSON.stringify({ type: "agent_end" }), '{"incomplete":',
  ].join("\n");
  const result = parseLog(header, tail)!;
  assert.equal(result.sessionId, "logged-session");
  assert.equal(result.activity, "agent_end");
  assert.equal(result.progress, "Running tests");
  assert.doesNotMatch(JSON.stringify(result), /SECRET|PRIVATE|idle/);
  assert.equal(parseLog("not JSON", tail), undefined);
});

test("process discovery reports all fixture Pi instances including workers and excludes unrelated node", async () => {
  const f = await fixture();
  try {
    await mkdir(join(f.root, "sys/kernel/random"), { recursive: true });
    await writeFile(join(f.root, "sys/kernel/random/boot_id"), "fixture-boot");
    for (const [pid, comm, command] of [[123, "pi", "pi"], [124, "node", "/bin/node\0/pkg/pi-coding-agent/dist/cli.js"], [125, "node", "/bin/node\0/server.js"]] as const) {
      await mkdir(join(f.root, String(pid)));
      await writeFile(join(f.root, String(pid), "stat"), `${pid} (${comm}) S 1 ${Array(17).fill("0").join(" ")} 123456 0`);
      await writeFile(join(f.root, String(pid), "cmdline"), command);
      await writeFile(join(f.root, String(pid), "environ"), "SECRET=never-display\0PI_SESSION_ID=parent-session\0");
      await symlink("/fixture", join(f.root, String(pid), "cwd"));
    }
    const result = await discoverProcesses(f.root);
    assert.deepEqual(result.processes.map(p => p.pid).sort(), [123, 124]);
    assert.ok(result.processes.every(p => p.parentHint === "parent-session"));
    assert.doesNotMatch(JSON.stringify(result), /never-display/);
  } finally { await f.cleanup(); }
});

test("dashboard navigation, fresh updates, Unicode/narrow sizes and disposal fence", async () => {
  const now = Date.now();
  const first = telemetryRow(record(now), true, now);
  let snapshot: FleetSnapshot = { at: now, warnings: [], rows: [first,
    telemetryRow({ ...record(now), pid: 124, name: "Second instance" }, true, now)] };
  let closed = 0, renders = 0;
  let height = 30;
  const view = new InstancesView(theme, keys, () => height, () => renders++, () => closed++, async () => snapshot);
  await view.refresh();
  assert.match(view.render(120).join("\n"), /2 live/);
  view.handleInput("\x1b[B");
  view.handleInput("\r");
  assert.match(view.render(120).join("\n"), /Second instance/);
  snapshot = { ...snapshot, rows: [...snapshot.rows].reverse() };
  await view.refresh();
  assert.match(view.render(120).join("\n"), /Second instance/);
  for (const width of [1, 2, 8, 24, 80, 120]) for (const rows of [1, 4, 12, 30]) {
    height = rows;
    const lines = view.render(width);
    assert.ok(lines.length <= rows);
    assert.ok(lines.every(line => visibleWidth(line) <= width), `width ${width}`);
  }
  view.handleInput("\x1b"); view.handleInput("q");
  assert.equal(closed, 1);
  const before = renders;
  await view.refresh();
  assert.equal(renders, before);
});

test("failed inventory stays visibly unavailable and never relabels previous rows as exited", async () => {
  let fail = false;
  const view = new InstancesView(theme, keys, () => 24, () => {}, () => {}, async () => {
    if (fail) throw new Error("permission denied");
    return { at: Date.now(), warnings: [], rows: [telemetryRow(record(), true, Date.now())] };
  });
  await view.refresh(); fail = true; await view.refresh();
  assert.match(view.render(120).join("\n"), /Inventory unavailable; last snapshot only/);
  assert.doesNotMatch(view.render(120).join("\n"), /EXITED/);
  view.dispose();
});

test("factory has no resources; agent_end is not treated as final idle", () => {
  const handlers = new Map<string, Function>();
  const commands: string[] = [];
  extension({ on: (name: string, fn: Function) => { handlers.set(name, fn); },
    registerCommand: (name: string) => commands.push(name), registerFlag: () => {} } as unknown as ExtensionAPI);
  assert.deepEqual(commands, ["instances"]);
  assert.ok(handlers.has("agent_settled"));
  assert.ok(!handlers.has("agent_end"));
});
