import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodeRecord, type InstanceRecord } from "./model.ts";
import { errorCode } from "../lib/data.ts";

export function registryPath(): string {
  return process.env.PI_INSTANCES_DIR || join(process.env.XDG_RUNTIME_DIR || tmpdir(), `pi-instances-${process.getuid?.() ?? "user"}`);
}
export async function privateDirectory(directory: string, create = false): Promise<void> {
  if (create) await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077)) {
    throw new Error("Instance registry must be an owned, private (0700), non-symlink directory");
  }
}
export async function readRecord(path: string): Promise<InstanceRecord> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o077) || info.size > 32 * 1024) {
      throw new Error("Unsafe or oversized instance record");
    }
    const data = Buffer.alloc(32 * 1024 + 1);
    const { bytesRead } = await file.read(data, 0, data.length, 0);
    if (bytesRead > 32 * 1024) throw new Error("Instance record grew beyond limit");
    return decodeRecord(JSON.parse(data.subarray(0, bytesRead).toString("utf8")));
  } finally { await file.close(); }
}
export async function records(directory: string): Promise<{ records: InstanceRecord[]; warnings: string[] }> {
  try { await privateDirectory(directory); }
  catch (error) {
    if (errorCode(error) === "ENOENT") return { records: [], warnings: [] };
    throw error;
  }
  const names = (await readdir(directory)).filter(name => /^[\w-]+\.json$/.test(name));
  if (names.length > 2048) throw new Error("Instance registry exceeds 2048 records; remove old records before continuing");
  const result: InstanceRecord[] = [];
  let rejected = 0;
  for (const name of names) {
    try { result.push(await readRecord(join(directory, name))); }
    catch (error) { if (errorCode(error) !== "ENOENT") rejected++; }
  }
  return { records: result, warnings: rejected ? [`${rejected} invalid/unreadable telemetry record(s) ignored`] : [] };
}
export async function writeRecord(directory: string, record: InstanceRecord): Promise<void> {
  const destination = join(directory, `${record.pid}-${record.startTicks}-${record.token}.json`);
  const temporary = `${destination}.tmp`;
  const file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    await file.writeFile(JSON.stringify(record));
    await file.close();
    await rename(temporary, destination);
  } finally {
    await file.close();
    await unlink(temporary).catch(() => {});
  }
}
export async function pruneRecords(directory: string, now = Date.now()): Promise<void> {
  // Only expired validated records, never arbitrary files or another process's fresh heartbeat.
  for (const name of (await readdir(directory)).slice(0, 2048)) {
    if (!/^[\w-]+\.json$/.test(name)) continue;
    try {
      const record = await readRecord(join(directory, name));
      if (now - record.updatedAt > 24 * 3600_000) await unlink(join(directory, name));
    } catch { /* Invalid records remain visible as a dashboard warning. */ }
  }
}
