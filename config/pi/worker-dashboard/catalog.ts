import type { SessionInfo } from "@earendil-works/pi-coding-agent";
import { readOwner, type Owner } from "./ownership.ts";
import { listRuns, observe, plain, type Snapshot, type Worker } from "./state.ts";

export type SessionIdentity = { id: string; name: string; cwd: string };
export type WorkerEntry = { key: string; ownerId: string; snapshot: Snapshot; task: Worker; number: number };
export type SessionGroup = SessionIdentity & { current: boolean; modified: number; workers: WorkerEntry[]; errors: string[] };
export type Catalog = { groups: SessionGroup[]; errors: string[] };
export type Scope = "session" | "all";

// Numbers are per owning session, stable across polling and run/task reordering.
// A removed worker's number is never reused for another worker in this runtime.
export class CatalogSlots {
  private sessions = new Map<string, Map<string, number>>();
  number(ownerId: string, key: string): number {
    let ids = this.sessions.get(ownerId);
    if (!ids) { ids = new Map(); this.sessions.set(ownerId, ids); }
    let number = ids.get(key);
    if (number === undefined) { number = ids.size + 1; ids.set(key, number); }
    return number;
  }
}

export async function loadCatalog(root: string, current: SessionIdentity, slots: CatalogSlots,
  sessions: readonly SessionInfo[] = [], scope: Scope = "all"): Promise<Catalog> {
  const groups = new Map<string, SessionGroup>();
  const errors: string[] = [];
  const add = (identity: SessionIdentity, modified: number) => {
    const group: SessionGroup = { ...identity, name: plain(identity.name, 160) || identity.id,
      cwd: plain(identity.cwd, 2048), current: identity.id === current.id, modified, workers: [], errors: [] };
    groups.set(identity.id, group);
    return group;
  };
  if (scope === "all") for (const session of sessions) {
    const modified = session.modified.getTime();
    if ((groups.get(session.id)?.modified ?? -1) > modified) continue;
    add({ id: session.id, name: session.name || session.firstMessage || session.id, cwd: session.cwd }, modified);
  }
  const savedCurrent = groups.get(current.id);
  add({ ...current, name: current.name === current.id ? savedCurrent?.name || current.name : current.name }, savedCurrent?.modified ?? Date.now());
  const childIds = new Set<string>();
  const owners = new Set<string>();
  let runs: string[];
  try { runs = await listRuns(root); }
  catch (error) { return { groups: [...groups.values()], errors: [plain(String(error), 1024)] }; }
  for (const run of runs.sort()) {
    let owner: Owner;
    try { owner = await readOwner(root, run); }
    catch (error) {
      // Unknown ownership is never guessed into the current session.
      if (scope === "all") errors.push(`${run}: ${plain(String(error), 500)}`);
      continue;
    }
    owners.add(owner.sessionId);
    if (scope === "session" && owner.sessionId !== current.id) continue;
    const group = groups.get(owner.sessionId) ?? add({ id: owner.sessionId, name: owner.name, cwd: owner.cwd }, owner.created);
    const observation = await observe(root, run);
    if (!observation.snapshot) {
      group.errors.push(`${run}: ${observation.error || "Worker state not written yet"}`);
      continue;
    }
    const snapshot = observation.snapshot;
    group.modified = Math.max(group.modified, snapshot.updated * 1000);
    for (const task of [...snapshot.tasks].sort((a, b) => a.id.localeCompare(b.id))) {
      const key = `${run}/${task.id}`;
      group.workers.push({ key, ownerId: owner.sessionId, snapshot, task, number: slots.number(owner.sessionId, key) });
      if (task.sessionId) childIds.add(task.sessionId);
    }
  }
  // Worker conversations live under their parent, not twice as top-level chats.
  // A worker that owns a run of its own remains an expandable parent session.
  return { groups: [...groups.values()].filter(group => group.current || owners.has(group.id) || !childIds.has(group.id))
    .sort((a, b) => Number(b.current) - Number(a.current) || b.modified - a.modified || a.id.localeCompare(b.id)), errors };
}

// Poll only one read at a time; replacement and disposal fence late results.
export class CatalogMonitor {
  value: Catalog = { groups: [], errors: [] };
  private listeners = new Set<() => void>();
  private timer?: ReturnType<typeof setInterval>;
  private pending?: Promise<void>;
  private generation = 0;
  private read: () => Promise<Catalog>;
  constructor(read: () => Promise<Catalog>) { this.read = read; }
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener); listener();
    return () => { this.listeners.delete(listener); };
  }
  start(): void {
    this.stop(); void this.refresh();
    this.timer = setInterval(() => { void this.refresh(); }, 2000);
    this.timer.unref();
  }
  stop(): void {
    this.generation++; clearInterval(this.timer); this.timer = undefined; this.pending = undefined;
  }
  refresh(): Promise<void> {
    if (this.pending) return this.pending;
    const generation = this.generation;
    const pending = this.read().catch(error => ({ groups: [], errors: [plain(String(error), 1024)] })).then(value => {
      if (generation !== this.generation) return;
      this.value = value;
      for (const listener of this.listeners) listener();
    }).finally(() => { if (this.pending === pending) this.pending = undefined; });
    this.pending = pending;
    return pending;
  }
}
