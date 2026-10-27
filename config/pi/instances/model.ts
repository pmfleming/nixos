import { array, object } from "../lib/data.ts";

export interface ProcessIdentity {
  pid: number;
  ppid: number;
  startTicks: string;
  bootId: string;
}
export interface Activity { at: number; text: string }
export interface InstanceRecord extends ProcessIdentity {
  version: 1;
  token: string;
  registeredAt: number;
  updatedAt: number;
  lastActivityAt: number;
  endedAt?: number;
  sessionId: string;
  sessionFile: string;
  name: string;
  cwd: string;
  mode: string;
  model: string;
  state: "idle" | "working" | "waiting";
  tools: string[];
  turns: number;
  toolCount: number;
  prompt: string;
  progress: string;
  events: Activity[];
}
export interface InstanceRow {
  key: string;
  process: ProcessIdentity;
  source: "telemetry" | "log" | "process";
  status: "idle" | "working" | "waiting" | "stale" | "unknown" | "exited";
  name: string;
  cwd: string;
  sessionId?: string;
  sessionFile?: string;
  model?: string;
  mode?: string;
  activity: string;
  lastActivityAt?: number;
  updatedAt?: number;
  registeredAt?: number;
  prompt?: string;
  progress?: string;
  events: Activity[];
  logPath?: string;
  parentHint?: string;
  parentPid?: number;
  note: string;
}
export interface FleetSnapshot { rows: InstanceRow[]; warnings: string[]; at: number }
export const STALE_MS = 10_000;
export const RECENT_MS = 10 * 60_000;

// Never render terminal controls, escape sequences or bidi overrides from another session.
export function plain(value: unknown, limit = 400): string {
  return typeof value === "string" ? value.slice(0, 8192)
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f]/g, " ")
    .replace(/\s+/g, " ").trim().slice(0, limit) : "";
}
export function textContent(value: unknown): string {
  if (typeof value === "string") return plain(value);
  return plain(array(value).filter(part => object(part).type === "text").slice(0, 8).map(part => object(part).text).join(" "));
}
export function identityKey(identity: ProcessIdentity): string {
  return `${identity.bootId}/${identity.pid}/${identity.startTicks}`;
}
export function decodeRecord(value: unknown): InstanceRecord {
  const v = object(value);
  const integer = (key: string) => {
    const n = v[key];
    if (typeof n !== "number" || !Number.isSafeInteger(n) || n < 0) throw new Error(`Invalid ${key}`);
    return n;
  };
  const state = v.state;
  if (v.version !== 1 || !/^[\w-]{1,80}$/.test(String(v.token))
    || !/^\d{1,30}$/.test(String(v.startTicks)) || !/^[\w-]{1,80}$/.test(String(v.bootId))
    || (state !== "idle" && state !== "working" && state !== "waiting")) throw new Error("Invalid instance record");
  const record: InstanceRecord = {
    version: 1, token: String(v.token), pid: integer("pid"), ppid: integer("ppid"),
    bootId: String(v.bootId), startTicks: String(v.startTicks), registeredAt: integer("registeredAt"),
    updatedAt: integer("updatedAt"), lastActivityAt: integer("lastActivityAt"),
    sessionId: plain(v.sessionId, 200), sessionFile: plain(v.sessionFile, 2048),
    cwd: plain(v.cwd, 2048), name: plain(v.name, 160), mode: plain(v.mode, 40), model: plain(v.model, 160),
    state, tools: array(v.tools).slice(0, 32).map(x => plain(x, 80)),
    turns: integer("turns"), toolCount: integer("toolCount"), prompt: plain(v.prompt), progress: plain(v.progress),
    events: array(v.events).slice(-12).flatMap(raw => {
      const e = object(raw);
      return typeof e.at === "number" && Number.isSafeInteger(e.at) && e.at >= 0 ? [{ at: e.at, text: plain(e.text) }] : [];
    }),
  };
  if (v.endedAt !== undefined) record.endedAt = integer("endedAt");
  return record;
}
export function telemetryRow(record: InstanceRecord, live: boolean, now: number): InstanceRow {
  const stale = now - record.updatedAt > STALE_MS || record.updatedAt > now + 5000 || !!record.endedAt;
  return {
    key: identityKey(record), process: record, source: "telemetry",
    status: !live ? "exited" : stale ? "stale" : record.state,
    name: record.name, cwd: record.cwd, sessionId: record.sessionId, sessionFile: record.sessionFile,
    model: record.model, mode: record.mode, activity: record.tools.length ? record.tools.join(" + ") : record.events.at(-1)?.text || record.state,
    lastActivityAt: record.lastActivityAt, updatedAt: record.updatedAt, registeredAt: record.registeredAt,
    prompt: record.prompt, progress: record.progress, events: record.events,
    note: !live ? "Process no longer present; last reported state, not proof of task completion."
      : stale ? "STALE: process exists, but live activity is unknown. Values below are last reported."
      : "Live extension telemetry. Counters and recent events start at extension load/reload.",
  };
}
export function age(at: number | undefined, now = Date.now()): string {
  if (at === undefined) return "?";
  const seconds = Math.max(0, Math.floor((now - at) / 1000));
  return seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m` : `${Math.floor(seconds / 3600)}h`;
}
