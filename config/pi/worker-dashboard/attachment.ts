import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { open, realpath, unlink } from "node:fs/promises";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { errorCode, requireObject as object, strings } from "../lib/data.ts";
import { bounded, within, type Snapshot } from "./state.ts";
import type { ProcessSpec } from "./rpc.ts";

export type Attachment = { key: string; id: string; number: number; sessionFile: string; spec: ProcessSpec; release: () => Promise<void> };
type ModelIdentity = Pick<Snapshot, "provider" | "model" | "thinking">;
const TERMINAL = new Set(["review-required", "failed-review-required", "stopped-review-required", "launch-failed"]);
const FLAGS = ["--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-approve"];
const VALUED = new Set(["--provider", "--model", "--thinking", "--mode", "--tools", "--session", "--session-id", "--name", "--append-system-prompt"]);
function text(value: unknown): string {
  if (typeof value !== "string" || !value || /[\u0000-\u001f\u007f]/.test(value)) throw new Error("Invalid worker attachment string");
  return value;
}
function alive(pid: unknown): boolean {
  if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0) throw new Error("Missing/invalid original worker PID; cannot establish exclusive ownership");
  // A vanished group leader doesn't establish quiescence if tools remain in its group.
  for (const target of [pid, -pid]) {
    try { process.kill(target, 0); return true; }
    catch (error) { if (errorCode(error) !== "ESRCH") return true; }
  }
  return false;
}
function checkModel(actual: ModelIdentity, expected: ModelIdentity, message: string): void {
  if (actual.provider !== expected.provider || actual.model !== expected.model || actual.thinking !== expected.thinking) throw new Error(message);
}
async function verifyHeader(sessionFile: string, sessionId: string, cwd: string): Promise<void> {
  const file = await open(sessionFile, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 64 * 1024 * 1024) throw new Error("Worker session is not a regular file or exceeds 64 MiB");
    const bytes = Buffer.alloc(8192);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    const header = object(JSON.parse(bytes.subarray(0, bytesRead).toString("utf8").split("\n")[0] ?? ""));
    if (header.type !== "session" || header.id !== sessionId || await realpath(text(header.cwd)) !== cwd)
      throw new Error("Saved session header does not match worker identity/cwd");
  } finally { await file.close(); }
}
async function continuationArgs(command: unknown, snapshot: Snapshot, sessionId: string, target: string): Promise<string[]> {
  if (!strings(command)) throw new Error("Invalid original worker command");
  const values = new Map<string, string>(), prompts: string[] = [];
  const args = command.slice(1).values();
  for (const arg of args) {
    if (arg.startsWith("@") || FLAGS.includes(arg)) continue; // Never replay the original assignment.
    const value = args.next().value;
    if (!VALUED.has(arg) || !value) throw new Error(`Unsupported saved worker option: ${arg}`);
    if (arg !== "--append-system-prompt") { values.set(arg, value); continue; }
    await bounded(snapshot.directory, value, 128 * 1024);
    prompts.push(await realpath(value));
  }
  checkModel({ provider: values.get("--provider") ?? "", model: values.get("--model") ?? "", thinking: values.get("--thinking") ?? "" },
    snapshot, "Original invocation model identity mismatch");
  const session = values.get("--session");
  if ((session && await realpath(session) !== target) || (values.has("--session-id") && values.get("--session-id") !== sessionId))
    throw new Error("Original invocation session mismatch");
  const tools = values.get("--tools");
  if (!tools || tools.split(",").some(tool => !["read", "bash", "edit", "write"].includes(tool)) || !prompts.length)
    throw new Error("Worker tool/prompt contract is missing or unsupported");
  return ["--mode", "rpc", "--provider", snapshot.provider, "--model", snapshot.model, "--thinking", snapshot.thinking,
    ...FLAGS, "--tools", tools, "--session", target, ...prompts.flatMap(path => ["--append-system-prompt", path])];
}
async function acquireLease(base: string, target: string): Promise<Attachment["release"]> {
  const lockPath = `${target}.worker-chat.lock`, token = randomUUID();
  const lock = await open(lockPath, "wx", 0o600).catch((error: unknown) => {
    if (errorCode(error) === "EEXIST") throw new Error("Worker chat already owned by another runtime (or a crash left a lock). Refusing a second writer.");
    throw error;
  });
  try { await lock.writeFile(JSON.stringify({ pid: process.pid, token })); }
  catch (error) { await lock.close(); await unlink(lockPath); throw error; }
  await lock.close();
  let released = false;
  return async () => {
    if (released) return;
    released = true;
    // Never remove somebody else's replacement lock.
    try {
      const data = object(JSON.parse(await bounded(base, lockPath, 4096)));
      if (data.token === token) await unlink(lockPath);
    } catch (error) { if (errorCode(error) !== "ENOENT") throw error; }
  };
}

// Deliberate continuation of a completed session, never a second JSON-mode writer.
export async function prepareAttachment(snapshot: Snapshot, id: string, number: number, callingSession?: string,
  sessionRoot = process.env.PI_CODING_AGENT_SESSION_DIR || join(getAgentDir(), "sessions")): Promise<Attachment> {
  const task = snapshot.tasks.find(candidate => candidate.id === id);
  if (!task || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(id)) throw new Error("Unknown worker");
  if (!TERMINAL.has(task.state) || task.ended === undefined)
    throw new Error("This legacy worker is not finished. Its JSON process cannot be attached; no duplicate session was opened.");
  if (task.pid !== undefined && alive(task.pid)) throw new Error("Original worker PID is still alive; refusing a second session writer");
  const directory = join(snapshot.directory, "tasks", id), phase = task.phase === "quality" ? join(directory, "quality") : directory;
  const identity = object(JSON.parse(await bounded(snapshot.directory, join(phase, "IDENTITY.json"), 16 * 1024)));
  const invocation = object(JSON.parse(await bounded(snapshot.directory, join(phase, "invocation.json"), 32 * 1024)));
  if (alive(invocation.pid)) throw new Error("Original worker process is still alive; refusing a second session writer");
  checkModel({ provider: text(identity.provider), model: text(identity.model), thinking: text(identity.reasoning) },
    snapshot, "Worker model/reasoning identity does not match the run");
  const sessionId = text(identity.session_id), sessionFile = text(identity.session_file);
  if (task.sessionId && task.sessionId !== sessionId) throw new Error("Worker session identity mismatch");
  const [base, target, cwd, expectedCwd] = await Promise.all([
    realpath(sessionRoot), realpath(sessionFile), realpath(text(invocation.cwd)), realpath(join(directory, "worktrees")),
  ]);
  if (!within(base, target)) throw new Error("Worker session is outside the configured Pi session directory");
  if (callingSession && target === await realpath(callingSession)) throw new Error("Worker resolves to the calling chat");
  if (cwd !== expectedCwd || !within(await realpath(snapshot.directory), cwd)) throw new Error("Worker cwd does not match its isolated worktree");
  await verifyHeader(sessionFile, sessionId, cwd);
  const args = await continuationArgs(invocation.command, snapshot, sessionId, target);
  const release = await acquireLease(base, target);
  const env: NodeJS.ProcessEnv = { ...process.env, ORCHESTRATION_ROOT: snapshot.directory, ORCHESTRATION_TASK_DIR: directory, CARGO_BUILD_JOBS: "2" };
  for (const key of ["PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"]) delete env[key];
  return { key: `${snapshot.run}/${id}`, id, number, sessionFile: target, release, spec: { command: "pi", cwd, env, args } };
}
