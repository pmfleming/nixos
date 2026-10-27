import { constants } from "node:fs";
import { open, readFile, readdir, readlink, stat, type FileHandle } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { errorCode, object } from "../lib/data.ts";
import { identityKey, plain, RECENT_MS, telemetryRow, textContent, type FleetSnapshot, type InstanceRecord, type InstanceRow, type ProcessIdentity } from "./model.ts";
import { records } from "./storage.ts";

export interface LocalProcess extends ProcessIdentity { comm: string; state: string; cwd: string; parentHint?: string }
export function parseStat(text: string) {
  const end = text.lastIndexOf(")"), start = text.indexOf("(");
  const fields = text.slice(end + 2).trim().split(/\s+/);
  const pid = Number(text.slice(0, start).trim()), ppid = fields[1] ?? "", startTicks = fields[19] ?? "";
  if (start < 1 || end < start || !Number.isSafeInteger(pid) || !/^\d+$/.test(startTicks) || !/^\d+$/.test(ppid)) {
    throw new Error("Invalid process identity");
  }
  return { pid, ppid: Number(ppid), startTicks, comm: text.slice(start + 1, end), state: fields[0] ?? "" };
}
export async function ownIdentity(): Promise<ProcessIdentity> {
  const { pid, ppid, startTicks } = parseStat(await readFile(`/proc/${process.pid}/stat`, "utf8"));
  return { pid, ppid, startTicks, bootId: (await readFile("/proc/sys/kernel/random/boot_id", "utf8")).trim() };
}
async function readSlice(file: FileHandle, max: number, position = 0): Promise<string> {
  const data = Buffer.alloc(max);
  const { bytesRead } = await file.read(data, 0, max, position);
  return data.subarray(0, bytesRead).toString("utf8");
}
async function prefix(path: string, max: number): Promise<string> {
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
  try { return await readSlice(file, max); } finally { await file.close(); }
}
async function isPi(comm: string, path: string): Promise<boolean> {
  if (comm === "pi") return true;
  if (!/^(node|bun|pi-coding-agent)$/.test(comm)) return false;
  return (await prefix(join(path, "cmdline"), 16 * 1024)).split("\0").slice(0, 3)
    .some(arg => /(?:^|\/)pi(?:\.js)?$|pi-coding-agent\/(?:dist|src)\/cli\.[jt]s$/.test(arg));
}
async function inspectProcess(path: string, bootId: string): Promise<LocalProcess | undefined> {
  if ((await stat(path)).uid !== process.getuid?.()) return;
  const info = parseStat(await readFile(join(path, "stat"), "utf8"));
  if (["Z", "X"].includes(info.state) || !await isPi(info.comm, path)) return;
  const cwd = await readlink(join(path, "cwd")).catch(() => "(cwd unavailable)");
  // Inherited PI_SESSION_ID is a LAUNCH hint only, never the child's own identity.
  const environment = await prefix(join(path, "environ"), 64 * 1024).catch(() => "");
  const hint = environment.split("\0").find(item => item.startsWith("PI_SESSION_ID="))?.slice(14);
  return { ...info, bootId, cwd: plain(cwd, 2048), parentHint: plain(hint, 200) || undefined };
}
export async function discoverProcesses(procRoot = "/proc") {
  const bootId = (await readFile(join(procRoot, "sys/kernel/random/boot_id"), "utf8")).trim();
  const names = (await readdir(procRoot)).filter(name => /^\d+$/.test(name));
  const processes: LocalProcess[] = [], warnings: string[] = [];
  if (names.length > 16384) warnings.push("Process inventory truncated at 16384 entries");
  let denied = 0;
  for (let offset = 0; offset < Math.min(names.length, 16384); offset += 32) {
    await Promise.all(names.slice(offset, offset + 32).map(async name => {
      try {
        const proc = await inspectProcess(join(procRoot, name), bootId);
        if (proc) processes.push(proc);
      } catch (error) {
        if (["EACCES", "EPERM"].includes(String(errorCode(error)))) denied++;
        // Exits during discovery are ordinary; no PID is assumed alive on an error.
      }
    }));
  }
  if (denied) warnings.push(`${denied} process entries inaccessible; inventory may be incomplete`);
  return { processes, warnings, bootId };
}

export interface LogObservation { sessionId: string; activity: string; progress: string; model: string; events: string[] }
function logRecord(line = ""): Record<string, unknown> {
  if (line.length > 24 * 1024) return {};
  try { return object(JSON.parse(line)); } catch { return {}; } // Partial writes/diagnostics aren't events.
}
function logActivity(event: Record<string, unknown>): string {
  switch (event.type) {
    case "tool_execution_start": return `Tool started: ${plain(event.toolName, 80)}`;
    case "tool_execution_end": return `Tool ${event.isError ? "failed" : "finished"}: ${plain(event.toolName, 80)}`;
    case "agent_start": case "agent_end": case "turn_start": return event.type;
    default: return "";
  }
}
export function parseLog(head: string, tail: string): LogObservation | undefined {
  const header = logRecord(head.split("\n")[0]);
  if (header.type !== "session" || typeof header.id !== "string") return;
  const result: LogObservation = { sessionId: plain(header.id, 200), activity: "JSON session log", progress: "", model: "", events: [] };
  for (const line of tail.split("\n").slice(-300)) {
    const event = logRecord(line), activity = logActivity(event);
    if (activity) result.events.push(activity);
    const message = object(event.message);
    if (event.type !== "message_end" || message.role !== "assistant") continue;
    result.progress = textContent(message.content) || result.progress;
    result.model = plain(message.model, 160) || result.model;
    if (message.stopReason === "error") result.events.push("Model reported an error");
  }
  result.events = result.events.slice(-8);
  result.activity = result.events.at(-1) || result.activity;
  return result;
}
async function observeLog(proc: LocalProcess): Promise<Partial<InstanceRow> | undefined> {
  const descriptor = `/proc/${proc.pid}/fd/1`, path = await readlink(descriptor).catch(() => "");
  if (!path.endsWith(".jsonl")) return;
  // Never consume a pipe/terminal: check before AND after nonblocking open, use pread.
  const info = await stat(descriptor).catch(() => undefined);
  if (!info?.isFile() || info.uid !== process.getuid?.()) return;
  const file = await open(descriptor, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    const actual = await file.stat();
    if (!actual.isFile() || actual.uid !== process.getuid?.() || actual.ino !== info.ino || actual.dev !== info.dev) return;
    const head = await readSlice(file, 8192), start = Math.max(0, actual.size - 96 * 1024);
    let tail = await readSlice(file, 96 * 1024, start);
    if (start) tail = tail.slice(tail.indexOf("\n") + 1);
    // PID reuse cannot transfer observations after asynchronous IO.
    if (parseStat(await readFile(`/proc/${proc.pid}/stat`, "utf8")).startTicks !== proc.startTicks) return;
    const parsed = parseLog(head, tail);
    if (!parsed) return;
    const name = basename(path, ".jsonl");
    const label = ["events", "stdout", "output"].includes(name) ? `${basename(dirname(dirname(path)))}/${basename(dirname(path))}` : name;
    return { source: "log", logPath: plain(path, 2048), name: plain(label, 160), sessionId: parsed.sessionId,
      model: parsed.model, activity: parsed.activity, progress: parsed.progress, lastActivityAt: actual.mtimeMs,
      note: "Log-only: state unknown. Session ID is from the log header; activity is last observed, not a live heartbeat. Reload/enable the extension for full telemetry." };
  } finally { await file.close(); }
}
export function mergeInventory(processes: LocalProcess[], telemetry: InstanceRecord[], now: number): InstanceRow[] {
  const latest = new Map<string, InstanceRecord>();
  for (const record of telemetry) {
    const key = identityKey(record), previous = latest.get(key);
    if (!previous || previous.registeredAt < record.registeredAt) latest.set(key, record);
  }
  const rows: InstanceRow[] = processes.map(proc => {
    const key = identityKey(proc), record = latest.get(key);
    latest.delete(key);
    const row: InstanceRow = record ? telemetryRow(record, true, now) : {
      key, process: proc, source: "process", status: "unknown", name: "Uninstrumented Pi", cwd: proc.cwd,
      activity: "Activity unknown", events: [], note: "Process detected, but no telemetry. Run /reload in this instance when safe. Extensions-disabled workers require an explicit extension on their next launch.",
    };
    if (proc.parentHint && proc.parentHint !== row.sessionId) row.parentHint = proc.parentHint;
    if (processes.some(parent => parent.pid === proc.ppid)) row.parentPid = proc.ppid;
    return row;
  });
  for (const record of latest.values()) {
    if (record.updatedAt <= now + 5000 && now - record.updatedAt < RECENT_MS) rows.push(telemetryRow(record, false, now));
  }
  return rows.sort((a, b) => Number(a.status === "exited") - Number(b.status === "exited") || a.cwd.localeCompare(b.cwd) || a.process.pid - b.process.pid);
}
async function verifyRegistered(record: InstanceRecord, inventory: Awaited<ReturnType<typeof discoverProcesses>>): Promise<boolean> {
  if (inventory.processes.some(proc => identityKey(proc) === identityKey(record))) return true;
  try {
    const info = parseStat(await readFile(`/proc/${record.pid}/stat`, "utf8"));
    const owned = (await stat(`/proc/${record.pid}`)).uid === process.getuid?.();
    if (owned && info.startTicks === record.startTicks && inventory.bootId === record.bootId && !["Z", "X"].includes(info.state)) {
      inventory.processes.push({ ...info, bootId: inventory.bootId, cwd: record.cwd });
    }
    return true;
  } catch (error) {
    if (["ENOENT", "ESRCH"].includes(String(errorCode(error)))) return true;
    inventory.warnings.push(`Cannot verify PID ${record.pid}; omitted rather than marked exited`);
    return false;
  }
}
export async function scan(directory: string): Promise<FleetSnapshot> {
  // A failed process scan must not turn every registry entry into a fictitious exit.
  const inventory = await discoverProcesses();
  const telemetry = await records(directory).catch((error: unknown) => ({ records: [], warnings: [`Telemetry unavailable: ${plain(String(error))}`] }));
  inventory.warnings.push(...telemetry.warnings);
  const verified: InstanceRecord[] = [];
  // SDK/custom launchers may lack Pi's process title; permission failures aren't exits.
  for (const record of telemetry.records) if (await verifyRegistered(record, inventory)) verified.push(record);
  const rows = mergeInventory(inventory.processes, verified, Date.now());
  const processes = new Map(inventory.processes.map(proc => [identityKey(proc), proc]));
  for (const row of rows) {
    const proc = processes.get(row.key);
    if (row.source !== "process" || !proc) continue;
    try { Object.assign(row, await observeLog(proc)); } catch { row.note += " Output log unavailable."; }
    if (row.parentHint === row.sessionId) row.parentHint = undefined;
  }
  return { rows, warnings: inventory.warnings, at: Date.now() };
}
