import { constants } from "node:fs";
import { open, readFile, readdir, readlink, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { identityKey, object, plain, RECENT_MS, telemetryRow, textContent, type FleetSnapshot, type InstanceRecord, type InstanceRow, type ProcessIdentity } from "./model.ts";
import { records } from "./storage.ts";

export interface LocalProcess extends ProcessIdentity { comm: string; state: string; cwd: string; parentHint?: string }
export function parseStat(text: string): { pid: number; ppid: number; startTicks: string; comm: string; state: string } {
  const end = text.lastIndexOf(")");
  const start = text.indexOf("(");
  const fields = text.slice(end + 2).trim().split(/\s+/);
  const pid = Number(text.slice(0, start).trim());
  if (start < 1 || end < start || !Number.isSafeInteger(pid) || !/^\d+$/.test(fields[19] || "") || !/^\d+$/.test(fields[1] || "")) {
    throw new Error("Invalid process identity");
  }
  return { pid, ppid: Number(fields[1]), startTicks: fields[19]!, comm: text.slice(start + 1, end), state: fields[0]! };
}
export async function ownIdentity(): Promise<ProcessIdentity> {
  const data = parseStat(await readFile(`/proc/${process.pid}/stat`, "utf8"));
  return { pid: data.pid, ppid: data.ppid, startTicks: data.startTicks,
    bootId: (await readFile("/proc/sys/kernel/random/boot_id", "utf8")).trim() };
}
async function prefix(path: string, max: number): Promise<string> {
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    const data = Buffer.alloc(max);
    const { bytesRead } = await file.read(data, 0, max, 0);
    return data.subarray(0, bytesRead).toString("utf8");
  } finally { await file.close(); }
}
export async function discoverProcesses(procRoot = "/proc"): Promise<{ processes: LocalProcess[]; warnings: string[] }> {
  const bootId = (await readFile(join(procRoot, "sys/kernel/random/boot_id"), "utf8")).trim();
  const names = (await readdir(procRoot)).filter(name => /^\d+$/.test(name));
  const processes: LocalProcess[] = [];
  const warnings: string[] = [];
  if (names.length > 16384) warnings.push("Process inventory truncated at 16384 entries");
  let denied = 0;
  for (let offset = 0; offset < Math.min(names.length, 16384); offset += 32) {
    await Promise.all(names.slice(offset, offset + 32).map(async name => {
      try {
        const path = join(procRoot, name);
        if ((await stat(path)).uid !== process.getuid?.()) return;
        const info = parseStat(await readFile(join(path, "stat"), "utf8"));
        if (info.state === "Z" || info.state === "X") return;
        if (info.comm !== "pi") {
          if (!/^(node|bun|pi-coding-agent)$/.test(info.comm)) return;
          const command = (await prefix(join(path, "cmdline"), 16 * 1024)).split("\0");
          if (!command.slice(0, 3).some(arg => /(?:^|\/)pi(?:\.js)?$/.test(arg) || /pi-coding-agent\/(?:dist|src)\/cli\.[jt]s$/.test(arg))) return;
        }
        const cwd = await readlink(join(path, "cwd")).catch(() => "(cwd unavailable)");
        // Inherited PI_SESSION_ID is a LAUNCH hint only, never the child's own identity.
        const environment = await prefix(join(path, "environ"), 64 * 1024).catch(() => "");
        const parentHint = environment.split("\0").find(item => item.startsWith("PI_SESSION_ID="))?.slice(14);
        processes.push({ ...info, bootId, cwd: plain(cwd, 2048), parentHint: plain(parentHint, 200) || undefined });
      } catch (error) {
        if (["EACCES", "EPERM"].includes((error as NodeJS.ErrnoException).code || "")) denied++;
        // Exits during discovery are ordinary; no PID is assumed alive on an error.
      }
    }));
  }
  if (denied) warnings.push(`${denied} process entries inaccessible; inventory may be incomplete`);
  return { processes, warnings };
}

export interface LogObservation { sessionId: string; activity: string; progress: string; model: string; events: string[] }
export function parseLog(head: string, tail: string): LogObservation | undefined {
  let header: Record<string, unknown>;
  try { header = object(JSON.parse(head.split("\n")[0] || "")); }
  catch { return undefined; }
  if (header.type !== "session" || typeof header.id !== "string") return undefined;
  const result: LogObservation = { sessionId: plain(header.id, 200), activity: "JSON session log", progress: "", model: "", events: [] };
  for (const line of tail.split("\n").slice(-300)) {
    if (line.length > 24 * 1024) continue;
    try {
      const event = object(JSON.parse(line));
      if (event.type === "tool_execution_start") result.events.push(`Tool started: ${plain(event.toolName, 80)}`);
      else if (event.type === "tool_execution_end") result.events.push(`Tool ${event.isError ? "failed" : "finished"}: ${plain(event.toolName, 80)}`);
      else if (["agent_start", "agent_end", "turn_start"].includes(String(event.type))) result.events.push(plain(event.type));
      else if (event.type === "message_end") {
        const message = object(event.message);
        if (message.role !== "assistant") continue;
        const text = textContent(message.content);
        if (text) result.progress = text;
        result.model = plain(message.model, 160) || result.model;
        if (message.stopReason === "error") result.events.push("Model reported an error");
      }
    } catch { /* Partial writes, oversized records and diagnostic lines are not events. */ }
  }
  result.events = result.events.slice(-8);
  result.activity = result.events.at(-1) || result.activity;
  return result;
}
export async function observeLog(proc: LocalProcess, procRoot = "/proc"): Promise<Partial<InstanceRow> | undefined> {
  const descriptor = join(procRoot, String(proc.pid), "fd/1");
  const path = await readlink(descriptor).catch(() => "");
  if (!path.endsWith(".jsonl")) return undefined;
  // Opening /proc's descriptor does not read a terminal or consume a pipe. Check
  // before AND after open, use nonblocking IO and explicit pread offsets.
  const info = await stat(descriptor).catch(() => undefined);
  if (!info?.isFile() || info.uid !== process.getuid?.()) return undefined;
  const file = await open(descriptor, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    const actual = await file.stat();
    if (!actual.isFile() || actual.uid !== process.getuid?.() || actual.ino !== info.ino || actual.dev !== info.dev) return undefined;
    const head = Buffer.alloc(Math.min(actual.size, 8192));
    const headRead = await file.read(head, 0, head.length, 0);
    const tail = Buffer.alloc(Math.min(actual.size, 96 * 1024));
    const start = Math.max(0, actual.size - tail.length);
    const tailRead = await file.read(tail, 0, tail.length, start);
    let text = tail.subarray(0, tailRead.bytesRead).toString("utf8");
    if (start) text = text.slice(text.indexOf("\n") + 1);
    // Recheck identity after asynchronous IO so PID reuse cannot transfer observations.
    const after = parseStat(await readFile(join(procRoot, String(proc.pid), "stat"), "utf8"));
    if (after.startTicks !== proc.startTicks) return undefined;
    const parsed = parseLog(head.subarray(0, headRead.bytesRead).toString("utf8"), text);
    if (!parsed) return undefined;
    const logName = basename(path, ".jsonl");
    const label = ["events", "stdout", "output"].includes(logName)
      ? `${basename(dirname(dirname(path)))}/${basename(dirname(path))}` : logName;
    return { source: "log", logPath: plain(path, 2048), name: plain(label, 160),
      sessionId: parsed.sessionId, model: parsed.model, activity: parsed.activity, progress: parsed.progress,
      lastActivityAt: actual.mtimeMs,
      note: "Log-only: state unknown. Session ID is from the log header; activity is last observed, not a live heartbeat. Reload/enable the extension for full telemetry." };
  } finally { await file.close(); }
}

export function mergeInventory(processes: LocalProcess[], telemetry: InstanceRecord[], now: number): InstanceRow[] {
  const latest = new Map<string, InstanceRecord>();
  for (const record of telemetry) {
    const key = identityKey(record);
    if (!latest.has(key) || latest.get(key)!.registeredAt < record.registeredAt) latest.set(key, record);
  }
  const rows: InstanceRow[] = processes.map(proc => {
    const key = identityKey(proc);
    const record = latest.get(key);
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
export async function scan(directory: string): Promise<FleetSnapshot> {
  // A failed process scan must not turn every registry entry into a fictitious exit.
  const inventory = await discoverProcesses();
  const warnings = [...inventory.warnings];
  let telemetry: InstanceRecord[] = [];
  try { const result = await records(directory); telemetry = result.records; warnings.push(...result.warnings); }
  catch (error) { warnings.push(`Telemetry unavailable: ${plain(String(error))}`); }
  // A loaded SDK/custom launcher may not use Pi's process title. Verify missing
  // registered identities directly, and never turn permission failures into exits.
  const verified: InstanceRecord[] = [];
  const bootId = inventory.processes[0]?.bootId || (await readFile("/proc/sys/kernel/random/boot_id", "utf8")).trim();
  for (const record of telemetry) {
    if (inventory.processes.some(proc => identityKey(proc) === identityKey(record))) {
      verified.push(record); continue;
    }
    try {
      const info = parseStat(await readFile(`/proc/${record.pid}/stat`, "utf8"));
      const owned = (await stat(`/proc/${record.pid}`)).uid === process.getuid?.();
      if (owned && info.startTicks === record.startTicks && bootId === record.bootId && !["Z", "X"].includes(info.state)) {
        inventory.processes.push({ ...info, bootId, cwd: record.cwd });
      }
      verified.push(record);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT" || (error as NodeJS.ErrnoException).code === "ESRCH") verified.push(record);
      else warnings.push(`Cannot verify PID ${record.pid}; omitted rather than marked exited`);
    }
  }
  const rows = mergeInventory(inventory.processes, verified, Date.now());
  for (const row of rows) {
    if (row.source !== "process") continue;
    const proc = inventory.processes.find(p => identityKey(p) === row.key)!;
    try { Object.assign(row, await observeLog(proc)); }
    catch { row.note += " Output log unavailable."; }
    if (row.parentHint === row.sessionId) row.parentHint = undefined;
  }
  return { rows, warnings, at: Date.now() };
}
