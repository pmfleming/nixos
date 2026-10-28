import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { SessionInfo } from "@earendil-works/pi-coding-agent";
import { CatalogMonitor, CatalogSlots, loadCatalog, type Catalog } from "../worker-dashboard/catalog.ts";
import { createRun, readOwner, type Owner } from "../worker-dashboard/ownership.ts";
import { listRuns } from "../worker-dashboard/state.ts";

const owner: Owner = { version: 1, sessionId: "owner-a", name: "Session A", cwd: "/same-project", created: 1 };
const current = { id: owner.sessionId, name: owner.name, cwd: owner.cwd };
function saved(id: string, name: string): SessionInfo {
  return { id, name, path: `/fixture/${id}.jsonl`, cwd: "/same-project", created: new Date(0), modified: new Date(1),
    messageCount: 0, firstMessage: "", allMessagesText: "" };
}
async function state(root: string, run: string, sessionId: string) {
  await writeFile(join(root, run, "control/state.json"), JSON.stringify({ run, updated: Date.now() / 1000,
    tasks: { worker: { title: `${run} worker`, state: "running", session_id: sessionId } } }));
}

test("ownership registration is exclusive, cannot adopt old directories, and rejects path escapes", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-owner-"));
  try {
    await createRun(root, "new-run", owner);
    assert.deepEqual(await readOwner(root, "new-run"), owner);
    await assert.rejects(createRun(root, "new-run", { ...owner, sessionId: "owner-b" }), /EEXIST/);
    await assert.rejects(createRun(root, "../escape", owner), /identifier/);
    await assert.rejects(createRun(root, "bad-owner", { ...owner, sessionId: "" }), /ownership/);
    await mkdir(join(root, "legacy"));
    await assert.rejects(createRun(root, "legacy", owner), /EEXIST/);
    await symlink(join(root, "new-run"), join(root, "alias"));
    assert.deepEqual(await listRuns(root), ["new-run"]);
    const marker = join(root, "new-run/control/owner.json");
    assert.match(await readFile(marker, "utf8"), /owner-a/);
    await rm(marker); await symlink(join(root, "missing"), marker);
    await assert.rejects(readOwner(root, "new-run"), /ENOENT/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("session identity, not cwd/latest run, determines membership; all view includes empty sessions", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-catalog-"));
  try {
    await createRun(root, "a-run", owner); await state(root, "a-run", "worker-a");
    await createRun(root, "z-run", { ...owner, sessionId: "owner-b", name: "Session B" }); await state(root, "z-run", "worker-b");
    await mkdir(join(root, "zz-legacy/control"), { recursive: true }); await state(root, "zz-legacy", "legacy-worker");
    const sessions = [saved("owner-a", "Renamed A"), saved("owner-b", "Renamed B"), saved("owner-c", "Empty"), saved("worker-a", "Child A"), saved("worker-b", "Child B")];
    const slots = new CatalogSlots();
    const local = await loadCatalog(root, current, slots, sessions, "session");
    assert.equal(local.groups.length, 1);
    assert.deepEqual(local.groups[0]!.workers.map(worker => worker.key), ["a-run/worker"]);
    const all = await loadCatalog(root, current, slots, sessions, "all");
    assert.deepEqual(new Set(all.groups.map(group => group.id)), new Set(["owner-a", "owner-b", "owner-c"]));
    assert.equal(all.groups.find(group => group.id === "owner-b")?.name, "Renamed B");
    assert.equal(all.groups.find(group => group.id === "owner-c")?.workers.length, 0);
    assert.equal(all.groups.flatMap(group => group.workers).length, 2);
    const replacement = await loadCatalog(root, { ...current, id: "new-session" }, slots, sessions, "session");
    assert.equal(replacement.groups.length, 1); assert.equal(replacement.groups[0]!.workers.length, 0);
    await createRun(root, "second-a-run", owner); await state(root, "second-a-run", "worker-a2");
    const updated = await loadCatalog(root, current, slots, [], "session");
    assert.deepEqual(updated.groups[0]!.workers.map(worker => worker.number), [1, 2]);
    await rm(join(root, "a-run"), { recursive: true });
    assert.equal((await loadCatalog(root, current, slots, [], "session")).groups[0]!.workers[0]?.number, 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("owned but missing/broken states stay under their owner; malformed ownership is never guessed", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-catalog-errors-"));
  try {
    await createRun(root, "pending", owner);
    await createRun(root, "malformed", owner);
    await writeFile(join(root, "malformed/control/owner.json"), "{");
    const slots = new CatalogSlots();
    let data = await loadCatalog(root, current, slots);
    assert.equal(data.errors.length, 1);
    assert.equal(data.groups[0]!.errors.length, 1);
    assert.equal(data.groups[0]!.workers.length, 0);
    await state(root, "pending", "worker");
    await writeFile(join(root, "pending/control/dashboard.json"), "{");
    data = await loadCatalog(root, current, slots);
    assert.equal(data.groups[0]!.errors.length, 1, "no fallback to pre-quality success");
    assert.equal(data.groups[0]!.workers.length, 0);
    // More than 32 runs must not silently lose another session's workers.
    for (let i = 0; i < 34; i++) await createRun(root, `extra-${i}`, { ...owner, sessionId: "other-owner" });
    assert.equal((await listRuns(root)).length, 36);
    const foreign = (await loadCatalog(root, current, slots)).groups.find(group => group.id === "other-owner");
    assert.equal(foreign?.errors.length, 34);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("catalog polling coalesces reads and fences shutdown completions", async () => {
  let release!: (value: Catalog) => void, reads = 0, notices = 0;
  const monitor = new CatalogMonitor(() => { reads++; return new Promise(resolve => { release = resolve; }); });
  const unsubscribe = monitor.subscribe(() => notices++);
  const pending = monitor.refresh();
  assert.equal(monitor.refresh(), pending); assert.equal(reads, 1);
  monitor.stop(); release({ groups: [], errors: ["late"] }); await pending;
  assert.deepEqual(monitor.value.errors, []); assert.equal(notices, 1);
  const next = monitor.refresh(); release({ groups: [], errors: ["new"] }); await next;
  assert.deepEqual(monitor.value.errors, ["new"]); assert.equal(notices, 2);
  unsubscribe(); monitor.stop();
});
