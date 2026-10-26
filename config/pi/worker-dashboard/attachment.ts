import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { open, realpath, unlink } from "node:fs/promises";
import { isAbsolute, join, relative, sep } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { bounded, type Snapshot } from "./state.ts";
import type { ProcessSpec } from "./rpc.ts";

export type Attachment = { key: string; id: string; number: number; sessionFile: string; spec: ProcessSpec; release: () => Promise<void> };
const TERMINAL = new Set(["review-required", "failed-review-required", "stopped-review-required", "launch-failed"]);
function within(root: string, target: string): boolean {
  const path = relative(root, target);
  return path !== ".." && !path.startsWith(`..${sep}`) && !isAbsolute(path);
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid worker attachment metadata");
  return value as Record<string, unknown>;
}
function text(value: unknown): string {
  if (typeof value !== "string" || !value || /[\u0000-\u001f\u007f]/.test(value)) throw new Error("Invalid worker attachment string");
  return value;
}
function alive(pid: unknown): boolean {
  if (!Number.isSafeInteger(pid) || (pid as number) <= 0) throw new Error("Missing/invalid original worker PID; cannot establish exclusive ownership");
  // Supervisors launch workers as process-group leaders. A vanished leader does
  // not establish quiescence if its tool processes are still in that group.
  for (const target of [pid as number, -(pid as number)]) {
    try { process.kill(target, 0); return true; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") return true; }
  }
  return false;
}

// This is a deliberate continuation of a completed session, not a second writer
// attached to a running JSON-mode worker. Only an owned RPC child is attachable.
export async function prepareAttachment(snapshot: Snapshot, id: string, number: number, callingSession?: string,
  sessionRoot = process.env.PI_CODING_AGENT_SESSION_DIR || join(getAgentDir(), "sessions")): Promise<Attachment> {
  const task = snapshot.tasks.find(candidate => candidate.id === id);
  if (!task || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(id)) throw new Error("Unknown worker");
  if (!TERMINAL.has(task.state) || task.ended === undefined)
    throw new Error("This legacy worker is not finished. Its JSON process cannot be attached; no duplicate session was opened.");
  if (task.pid !== undefined && alive(task.pid)) throw new Error("Original worker PID is still alive; refusing a second session writer");
  const directory = join(snapshot.directory, "tasks", id);
  const phase = task.phase === "quality" ? join(directory, "quality") : directory;
  const identity = object(JSON.parse(await bounded(snapshot.directory, join(phase, "IDENTITY.json"), 16 * 1024)));
  const invocation = object(JSON.parse(await bounded(snapshot.directory, join(phase, "invocation.json"), 32 * 1024)));
  if (alive(invocation.pid)) throw new Error("Original worker process is still alive; refusing a second session writer");
  const provider = text(identity.provider), model = text(identity.model), thinking = text(identity.reasoning);
  if (provider !== snapshot.provider || model !== snapshot.model || thinking !== snapshot.thinking)
    throw new Error("Worker model/reasoning identity does not match the run");
  const sessionId = text(identity.session_id);
  if (task.sessionId && task.sessionId !== sessionId) throw new Error("Worker session identity mismatch");
  const sessionFile = text(identity.session_file);
  const [base, target, cwd, expectedCwd] = await Promise.all([
    realpath(sessionRoot), realpath(sessionFile), realpath(text(invocation.cwd)), realpath(join(directory, "worktrees")),
  ]);
  if (!within(base, target)) throw new Error("Worker session is outside the configured Pi session directory");
  if (callingSession && target === await realpath(callingSession)) throw new Error("Worker resolves to the calling chat");
  if (cwd !== expectedCwd || !within(await realpath(snapshot.directory), cwd)) throw new Error("Worker cwd does not match its isolated worktree");
  const file = await open(sessionFile, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 64 * 1024 * 1024) throw new Error("Worker session is not a regular file or exceeds 64 MiB");
    const bytes = Buffer.alloc(8192);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    const header = object(JSON.parse(bytes.subarray(0, bytesRead).toString("utf8").split("\n")[0]!));
    if (header.type !== "session" || header.id !== sessionId || await realpath(text(header.cwd)) !== cwd)
      throw new Error("Saved session header does not match worker identity/cwd");
  } finally { await file.close(); }
  if (!Array.isArray(invocation.command) || invocation.command.some(arg => typeof arg !== "string")) throw new Error("Invalid original worker command");
  const command = invocation.command as string[];
  const values = new Map<string, string>();
  const prompts: string[] = [];
  const flags = new Set(["--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-approve"]);
  const valued = new Set(["--provider", "--model", "--thinking", "--mode", "--tools", "--session", "--session-id", "--name", "--append-system-prompt"]);
  for (let index = 1; index < command.length; index++) {
    const arg = command[index]!;
    if (arg.startsWith("@") || flags.has(arg)) continue; // Never replay the original assignment.
    if (!valued.has(arg) || !command[index + 1]) throw new Error(`Unsupported saved worker option: ${arg}`);
    const value = command[++index]!;
    if (arg === "--append-system-prompt") {
      await bounded(snapshot.directory, value, 128 * 1024); // validated regular path inside this run
      prompts.push(await realpath(value));
    } else values.set(arg, value);
  }
  if (values.get("--provider") !== provider || values.get("--model") !== model || values.get("--thinking") !== thinking)
    throw new Error("Original invocation model identity mismatch");
  if ((values.has("--session") && await realpath(values.get("--session")!) !== target)
    || (values.has("--session-id") && values.get("--session-id") !== sessionId)) throw new Error("Original invocation session mismatch");
  const tools = values.get("--tools");
  if (!tools || tools.split(",").some(tool => !["read", "bash", "edit", "write"].includes(tool)) || !prompts.length)
    throw new Error("Worker tool/prompt contract is missing or unsupported");
  const lockPath = `${target}.worker-chat.lock`;
  const token = randomUUID();
  let lock;
  try { lock = await open(lockPath, "wx", 0o600); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error("Worker chat already owned by another runtime (or a crash left a lock). Refusing a second writer.");
    throw error;
  }
  try { await lock.writeFile(JSON.stringify({ pid: process.pid, token })); }
  catch (error) { await lock.close(); await unlink(lockPath); throw error; }
  await lock.close();
  let released = false;
  const release = async () => {
    if (released) return;
    released = true;
    // Never remove somebody else's replacement lock.
    try {
      const data = object(JSON.parse(await bounded(base, lockPath, 4096)));
      if (data.token === token) await unlink(lockPath);
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  };
  const env: NodeJS.ProcessEnv = { ...process.env, ORCHESTRATION_ROOT: snapshot.directory, ORCHESTRATION_TASK_DIR: directory, CARGO_BUILD_JOBS: "2" };
  for (const key of ["PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"]) delete env[key];
  return { key: `${snapshot.run}/${id}`, id, number, sessionFile: target, release,
    spec: { command: "pi", cwd, env,
      args: ["--mode", "rpc", "--provider", provider, "--model", model, "--thinking", thinking,
        ...flags, "--tools", tools, "--session", target, ...prompts.flatMap(path => ["--append-system-prompt", path])] } };
}
