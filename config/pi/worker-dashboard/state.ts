import { constants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { errorCode, requireObject as object } from "../lib/data.ts";

export type Worker = {
  id: string; title: string; state: string; phase: string; modelVerified: boolean;
  started?: number; ended?: number; lastEvent?: number; tools: number; turns: number;
  lastTool: string; failure: string; reportedStatus: string;
  pid?: number; sessionId?: string;
};
export type Snapshot = {
  directory: string; run: string; provider: string; model: string; thinking: string;
  updated: number; stopping: boolean; tasks: Worker[];
};
export type Observation = { snapshot?: Snapshot; error?: string };
export type DetailFile = "PROGRESS.md" | "REPORT.md" | "stderr.log";
const IDENTIFIER = /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/;
const ACTIVE = new Set(["running", "stopping"]);
const TERMINAL = new Set(["review-required", "failed-review-required", "stopped-review-required", "launch-failed", "cancelled-before-launch"]);

// Plain text only: worker-controlled terminal escapes and bidi controls must not
// acquire rendering authority. Newlines are handled separately for file views.
export function plain(value: unknown, limit = 300): string {
  return typeof value === "string"
    ? value.slice(0, limit).replace(/[\u0000-\u001f\u007f-\u009f\u2028-\u202e\u2066-\u2069]/g, " ").trim()
    : "";
}
function number(value: unknown): number;
function number(value: unknown, optional: true): number | undefined;
function number(value: unknown, optional = false): number | undefined {
  if (value === undefined && optional) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER)
    throw new Error("Malformed worker timestamp/count");
  return value;
}
function count(value: unknown): number {
  const result = number(value ?? 0);
  if (!Number.isInteger(result)) throw new Error("Malformed worker count");
  return result;
}
function identifier(value: unknown): string {
  if (typeof value !== "string" || !IDENTIFIER.test(value)) throw new Error("Invalid run/task identifier");
  return value;
}
export function within(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

// Bound bytes before parsing, reject non-regular files and paths escaping the run.
// Never read transcripts, credentials, arbitrary state-provided paths or FIFOs.
export async function bounded(root: string, path: string, limit: number): Promise<string> {
  const [base, target] = await Promise.all([realpath(root), realpath(path)]);
  if (!within(base, target)) throw new Error("Worker file escapes its run directory");
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw new Error("Worker input is not a regular file");
    if (stat.size > limit) throw new Error(`Worker input exceeds ${limit / 1024} KiB display limit`);
    const bytes = Buffer.alloc(limit + 1);
    let length = 0;
    while (length <= limit) {
      const next = await file.read(bytes, length, bytes.length - length, null);
      if (!next.bytesRead) break;
      length += next.bytesRead;
    }
    if (length > limit) throw new Error("Worker input grew beyond display limit");
    return bytes.subarray(0, length).toString("utf8");
  } finally { await file.close(); }
}

export async function listRuns(root: string): Promise<string[]> {
  try {
    const entries = await readdir(root, { withFileTypes: true });
    if (entries.length > 512) throw new Error("Too many orchestration directories; select a narrower PI_WORKERS_ROOT");
    const candidates = entries.filter(entry => entry.isDirectory() && IDENTIFIER.test(entry.name))
      .map(entry => entry.name).sort().reverse();
    const runs: string[] = [];
    for (const name of candidates) {
      // Timestamped supervisor runs count even before their first state write.
      // Named runs must advertise the supervisor format, not merely control/.
      let isRun = /^\d{8}T\d{6}Z$/.test(name);
      for (const marker of ["control/dashboard.json", "control/state.json", "manifest.json"]) {
        if (isRun) break;
        try {
          // Existence, not validity: malformed files and dangling links must
          // remain selectable so observe() reports errors instead of old success.
          await lstat(join(root, name, marker));
          isRun = true;
        } catch (error) {
          if (errorCode(error) !== "ENOENT") throw error;
        }
      }
      if (isRun) runs.push(name);
      if (runs.length === 32) break;
    }
    return runs;
  } catch (error) {
    if (errorCode(error) === "ENOENT") return [];
    throw error;
  }
}

export function decodeState(value: unknown, directory: string, expectedRun: string): Snapshot {
  const data = object(value);
  if (identifier(data.run) !== expectedRun) throw new Error("Worker run identity mismatch");
  const entries = Object.entries(object(data.tasks));
  if (entries.length > 64) throw new Error("Worker state exceeds 64 tasks");
  const tasks = entries.map(([id, raw]): Worker => {
    identifier(id);
    const task = object(raw);
    return {
      id, title: plain(task.title), state: plain(task.state) || "unknown", phase: plain(task.phase, 80),
      modelVerified: task.model_verified === true,
      started: number(task.started, true), ended: number(task.ended, true),
      lastEvent: number(task.last_event_at, true), tools: count(task.tools), turns: count(task.turns),
      lastTool: plain(task.last_tool, 80), failure: plain(task.failure, 2048), reportedStatus: plain(task.reported_status),
      pid: number(task.pid, true), sessionId: plain(task.session_id) || undefined,
    };
  });
  return { directory, run: expectedRun, provider: plain(data.provider), model: plain(data.model), thinking: plain(data.thinking),
    updated: number(data.updated), stopping: data.stopping === true, tasks };
}

export async function observe(root: string, selected?: string): Promise<Observation> {
  try {
    const run = selected ? identifier(selected) : (await listRuns(root))[0];
    if (!run) return {};
    const directory = resolve(root, run);
    // A later quality coordinator publishes the combined view without racing the
    // implementation supervisor's ledger. A broken combined view must not silently
    // fall back to obsolete pre-quality completion claims.
    let path = join(directory, "control", "dashboard.json");
    try { await lstat(path); }
    catch (error) {
      if (errorCode(error) !== "ENOENT") throw error;
      path = join(directory, "control", "state.json");
    }
    const contents = await bounded(root, path, 256 * 1024);
    return { snapshot: decodeState(JSON.parse(contents), directory, run) };
  } catch (error) {
    return { error: plain(error instanceof Error ? error.message : String(error), 1024) };
  }
}

export async function detail(snapshot: Snapshot, id: string, file: DetailFile): Promise<string> {
  identifier(id);
  if (!snapshot.tasks.some(task => task.id === id)) throw new Error("Unknown worker");
  if (!["PROGRESS.md", "REPORT.md", "stderr.log"].includes(file)) throw new Error("Unsupported detail file");
  const contents = await bounded(snapshot.directory, join(snapshot.directory, "tasks", id, file), 32 * 1024);
  return contents.split("\n").map(line => plain(line, 4096)).join("\n");
}

export function stale(snapshot: Snapshot, now = Date.now() / 1000): boolean {
  return snapshot.tasks.some(task => !TERMINAL.has(task.state))
    && (now - snapshot.updated > 15 || snapshot.updated - now > 5);
}
export function counts(snapshot: Snapshot): { running: number; queued: number; review: number; attention: number } {
  return {
    running: snapshot.tasks.filter(task => ACTIVE.has(task.state)).length,
    queued: snapshot.tasks.filter(task => task.state === "queued").length,
    review: snapshot.tasks.filter(task => task.state === "review-required" && !task.failure && task.reportedStatus !== "blocked").length,
    attention: snapshot.tasks.filter(task => !!task.failure || task.reportedStatus === "blocked"
      || ["failed-review-required", "stopped-review-required", "launch-failed"].includes(task.state)
      || (!ACTIVE.has(task.state) && !TERMINAL.has(task.state) && task.state !== "queued")).length,
  };
}
export function summary(snapshot: Snapshot, now = Date.now() / 1000): string {
  const c = counts(snapshot);
  return `${stale(snapshot, now) ? "STALE · last reported: " : ""}${c.running} running · ${c.queued} queued · ${c.review} review · ${c.attention} attention`;
}
export function age(timestamp: number | undefined, now = Date.now() / 1000): string {
  if (timestamp === undefined) return "—";
  const seconds = Math.max(0, Math.floor(now - timestamp));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
}
