import { mkdir, realpath, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { requireObject } from "../lib/data.ts";
import { bounded, plain } from "./state.ts";

export type Owner = { version: 1; sessionId: string; name: string; cwd: string; created: number };
const ID = /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/;
export function runId(value: string): string {
  if (!ID.test(value)) throw new Error("Invalid worker run identifier");
  return value;
}
export function decodeOwner(value: unknown): Owner {
  const data = requireObject(value);
  if (data.version !== 1 || typeof data.sessionId !== "string" || !ID.test(data.sessionId)
    || typeof data.name !== "string" || typeof data.cwd !== "string"
    || typeof data.created !== "number" || !Number.isFinite(data.created) || data.created < 0)
    throw new Error("Invalid worker run ownership");
  return { version: 1, sessionId: data.sessionId, name: plain(data.name, 160), cwd: plain(data.cwd, 2048), created: data.created };
}
export async function readOwner(root: string, run: string): Promise<Owner> {
  return decodeOwner(JSON.parse(await bounded(root, join(root, runId(run), "control", "owner.json"), 8192)));
}

// Only create new runs: never adopt a legacy run or change another session's owner.
// The caller obtains the session ID from ExtensionContext, never from tool input
// or an inherited PI_SESSION_ID (which may refer to a parent process).
export async function createRun(root: string, run: string, owner: Owner): Promise<string> {
  runId(run);
  const identity = decodeOwner(owner);
  await mkdir(root, { recursive: true, mode: 0o700 });
  const base = await realpath(root);
  const directory = resolve(base, run);
  await mkdir(directory, { mode: 0o700 }); // EEXIST deliberately fails closed.
  await mkdir(join(directory, "control"), { mode: 0o700 });
  await writeFile(join(directory, "control", "owner.json"), JSON.stringify(identity) + "\n", { flag: "wx", mode: 0o600 });
  return directory;
}
