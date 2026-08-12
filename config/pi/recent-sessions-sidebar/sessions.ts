import { existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { SessionManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { run } from "./shell.ts";
import type { ProjectInfo, RecentContext, SessionGroup, SessionInfo, SessionRow } from "./types.ts";

export const BRANCH_ENTRY_TYPE = "recent-sessions-sidebar.branch";
export const PIN_ENTRY_TYPE = "recent-sessions-sidebar.pin";
const recordedBranches = new Map<string, string>();
type StoredMetadata = { mtimeMs: number; size: number; branch?: string; pinned: boolean; userTurns: number };
const storedMetadataCache = new Map<string, StoredMetadata>();

type StoredBranchData = { branch?: unknown };
type StoredPinData = { pinned?: unknown };

function clean(value?: string): string {
  return (value ?? "").replace(/\s+/g, " ").trim();
}

function storedMetadata(sessionPath: string): StoredMetadata {
  try {
    const { mtimeMs, size } = statSync(sessionPath);
    const cached = storedMetadataCache.get(sessionPath);
    if (cached?.mtimeMs === mtimeMs && cached.size === size) return cached;

    let branch: string | undefined;
    let pinned = false;
    let userTurns = 0;
    for (const entry of SessionManager.open(sessionPath).getEntries()) {
      if (entry.type === "message" && entry.message.role === "user") userTurns++;
      if (entry.type !== "custom") continue;
      if (entry.customType === BRANCH_ENTRY_TYPE) {
        const data = entry.data as StoredBranchData | undefined;
        if (typeof data?.branch === "string" && data.branch) branch = data.branch;
      } else if (entry.customType === PIN_ENTRY_TYPE) {
        const data = entry.data as StoredPinData | undefined;
        if (typeof data?.pinned === "boolean") pinned = data.pinned;
      }
    }

    const metadata = { mtimeMs, size, branch, pinned, userTurns };
    storedMetadataCache.set(sessionPath, metadata);
    return metadata;
  } catch {
    // A concurrently removed or malformed session should not break the sidebar.
    storedMetadataCache.delete(sessionPath);
    return { mtimeMs: 0, size: 0, pinned: false, userTurns: 0 };
  }
}

export function invalidateSessionMetadata(sessionPath: string): void {
  storedMetadataCache.delete(sessionPath);
}

function currentBranch(cwd: string): string | undefined {
  const branch = run("git", ["branch", "--show-current"], cwd);
  if (branch) return branch;
  const commit = run("git", ["rev-parse", "--short", "HEAD"], cwd);
  return commit ? `detached@${commit}` : undefined;
}

export function recordCurrentBranch(pi: ExtensionAPI, cwd: string, sessionPath?: string): void {
  if (!sessionPath) return;
  const branch = currentBranch(cwd);
  if (!branch) return;

  const previous = recordedBranches.get(sessionPath) ?? storedMetadata(sessionPath).branch;
  if (previous === branch) {
    recordedBranches.set(sessionPath, branch);
    return;
  }

  pi.appendEntry(BRANCH_ENTRY_TYPE, { branch });
  recordedBranches.set(sessionPath, branch);
  storedMetadataCache.delete(sessionPath);
}

export function sessionTitle(session: SessionInfo): string {
  return clean(session.name || session.firstMessage) || "(empty chat)";
}

export function formatDate(date: Date): string {
  return date.toLocaleString(undefined, { month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

function gitProject(cwd?: string): ProjectInfo | undefined {
  if (!cwd) return undefined;
  const topLevel = run("git", ["rev-parse", "--show-toplevel"], cwd);
  if (!topLevel) return undefined;
  return { key: `git:${topLevel}`, label: basename(topLevel) || topLevel, cwd: topLevel, kind: "git" };
}

function projectFor(session: SessionInfo, cache: Map<string, ProjectInfo>): ProjectInfo {
  if (!session.cwd) return { key: "__chats__", label: "Chats", kind: "chats" };

  const cached = cache.get(session.cwd);
  if (cached) return cached;

  const project = gitProject(session.cwd) ?? {
    key: `dir:${session.cwd}`,
    label: basename(session.cwd) || session.cwd,
    cwd: session.cwd,
    kind: "folder" as const,
  };
  cache.set(session.cwd, project);
  return project;
}

function enrich(session: SessionInfo, projectCache: Map<string, ProjectInfo>): SessionRow {
  const metadata = storedMetadata(session.path);
  return {
    ...session,
    project: projectFor(session, projectCache),
    branch: metadata.branch,
    pinned: metadata.pinned,
    userTurns: metadata.userTurns,
    size: metadata.size,
  };
}

export function buildGroups(sessions: SessionRow[], current?: string): SessionGroup[] {
  const groups = new Map<string, SessionGroup>();

  for (const session of sessions) {
    const existing = groups.get(session.project.key);
    if (existing) {
      existing.sessions.push(session);
      existing.latestMs = Math.max(existing.latestMs, session.modified.getTime());
      existing.hasCurrent ||= session.path === current;
    } else {
      groups.set(session.project.key, {
        ...session.project,
        latestMs: session.modified.getTime(),
        sessions: [session],
        hasCurrent: session.path === current,
      });
    }
  }

  return [...groups.values()]
    .map((group) => ({ ...group, sessions: group.sessions.sort((a, b) => b.modified.getTime() - a.modified.getTime()) }))
    .sort((a, b) => b.latestMs - a.latestMs || a.label.localeCompare(b.label));
}

export async function loadGroups(current?: string): Promise<SessionGroup[]> {
  const projectCache = new Map<string, ProjectInfo>();
  const sessions = (await SessionManager.listAll())
    .map((session) => enrich(session, projectCache))
    .sort((a, b) => b.modified.getTime() - a.modified.getTime());
  return buildGroups(sessions, current);
}

function compactPath(path?: string): string {
  return path?.replace(homedir(), "~") ?? "";
}

export function projectIcon(kind: ProjectInfo["kind"]): string {
  return kind === "git" ? "" : kind === "folder" ? "📁" : "💬";
}

export function groupLabel(group: SessionGroup): string {
  const active = group.hasCurrent ? "●" : " ";
  const icon = projectIcon(group.kind);
  const cwd = group.cwd ? ` — ${compactPath(group.cwd)}` : "";
  return `${active} ${icon} ${group.label} (${group.sessions.length}) · ${formatDate(new Date(group.latestMs))}${cwd}`;
}

export function sessionSummary(session: SessionRow): string {
  const branch = session.branch ? `  ${session.branch} ·` : "";
  return `Chat · ${formatDate(session.modified)} ·${branch} ${sessionTitle(session)}`;
}

export function sessionLabel(session: SessionRow, current?: string): string {
  const active = session.path === current ? "●" : session.pinned ? "◆" : " ";
  return `${active} ${sessionSummary(session)}`;
}

export function choiceMap<T>(items: T[], label: (item: T) => string): Map<string, T> {
  const seen = new Map<string, number>();
  return new Map(
    items.map((item) => {
      const base = label(item);
      const count = seen.get(base) ?? 0;
      seen.set(base, count + 1);
      return [count === 0 ? base : `${base} #${count + 1}`, item];
    }),
  );
}

export async function pickGroup(ctx: RecentContext): Promise<SessionGroup | undefined> {
  const groups = await loadGroups(ctx.sessionManager.getSessionFile());
  if (groups.length === 0) {
    ctx.ui.notify("No saved chats found", "warning");
    return undefined;
  }
  const choices = choiceMap(groups, groupLabel);
  const choice = await ctx.ui.select("Recent chats by project", [...choices.keys(), "Cancel"]);
  return choice ? choices.get(choice) : undefined;
}

const DAY_MS = 24 * 60 * 60 * 1000;
const TRASH_ROOT = join(homedir(), ".pi", "agent", "session-trash");
const MAINTENANCE_MARKER = join(TRASH_ROOT, ".last-maintenance");

function positiveNumber(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function positiveInteger(name: string, fallback: number): number {
  return Math.max(1, Math.floor(positiveNumber(name, fallback)));
}

export const DISPLAY_LIMIT = positiveInteger("PI_RECENT_SESSIONS_DISPLAY_PER_PROJECT", 5);

const retentionPolicy = {
  maxTotal: positiveInteger("PI_RECENT_SESSIONS_MAX_TOTAL", 100),
  maxPerProject: positiveInteger("PI_RECENT_SESSIONS_MAX_PER_PROJECT", 20),
  maxBytes: positiveNumber("PI_RECENT_SESSIONS_MAX_MIB", 200) * 1024 * 1024,
  protectRecentMs: positiveNumber("PI_RECENT_SESSIONS_PROTECT_DAYS", 7) * DAY_MS,
  trashRetentionMs: positiveNumber("PI_RECENT_SESSIONS_TRASH_DAYS", 7) * DAY_MS,
};

export type RetentionResult = {
  archived: number;
  archivedBytes: number;
  purged: number;
  errors: number;
  remaining: number;
  remainingBytes: number;
  limitedByProtection: boolean;
};

function protectedSession(session: SessionRow, current: string | undefined, now: number): boolean {
  return (
    session.path === current ||
    session.pinned ||
    Boolean(session.name?.trim()) ||
    now - session.modified.getTime() < retentionPolicy.protectRecentMs
  );
}

function removalOrder(a: SessionRow, b: SessionRow): number {
  const aTrivial = a.userTurns <= 1 ? 0 : 1;
  const bTrivial = b.userTurns <= 1 ? 0 : 1;
  return aTrivial - bTrivial || a.modified.getTime() - b.modified.getTime();
}

function archivePath(sessionPath: string, now: number): string {
  const projectDir = basename(dirname(sessionPath));
  const targetDir = join(TRASH_ROOT, projectDir);
  mkdirSync(targetDir, { recursive: true });
  return join(targetDir, `${now}--${basename(sessionPath)}`);
}

function purgeExpiredTrash(now: number): number {
  if (!existsSync(TRASH_ROOT)) return 0;
  let purged = 0;

  for (const project of readdirSync(TRASH_ROOT, { withFileTypes: true })) {
    if (!project.isDirectory()) continue;
    const projectPath = join(TRASH_ROOT, project.name);
    for (const entry of readdirSync(projectPath, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const trashedAt = Number(entry.name.match(/^(\d+)--/)?.[1]);
      if (!Number.isFinite(trashedAt) || now - trashedAt < retentionPolicy.trashRetentionMs) continue;
      rmSync(join(projectPath, entry.name), { force: true });
      purged++;
    }
    if (readdirSync(projectPath).length === 0) rmSync(projectPath, { recursive: true, force: true });
  }

  return purged;
}

function maintenanceDue(now: number): boolean {
  try {
    return now - statSync(MAINTENANCE_MARKER).mtimeMs >= DAY_MS;
  } catch {
    return true;
  }
}

function archiveExcess(groups: SessionGroup[], current: string | undefined, now: number): Omit<RetentionResult, "purged"> {
  const sessions = groups.flatMap((group) => group.sessions);
  const remaining = new Map(sessions.map((session) => [session.path, session]));
  let archived = 0;
  let archivedBytes = 0;
  let errors = 0;

  const archive = (session: SessionRow): boolean => {
    if (!remaining.has(session.path)) return false;
    try {
      renameSync(session.path, archivePath(session.path, now));
      remaining.delete(session.path);
      invalidateSessionMetadata(session.path);
      archived++;
      archivedBytes += session.size;
      return true;
    } catch {
      errors++;
      return false;
    }
  };

  for (const group of groups) {
    let excess = group.sessions.filter((session) => remaining.has(session.path)).length - retentionPolicy.maxPerProject;
    if (excess <= 0) continue;
    const candidates = group.sessions
      .filter((session) => !protectedSession(session, current, now))
      .sort(removalOrder);
    for (const session of candidates) {
      if (excess <= 0) break;
      if (archive(session)) excess--;
    }
  }

  const globalCandidates = [...remaining.values()]
    .filter((session) => !protectedSession(session, current, now))
    .sort(removalOrder);
  let remainingBytes = [...remaining.values()].reduce((sum, session) => sum + session.size, 0);

  for (const session of globalCandidates) {
    if (remaining.size <= retentionPolicy.maxTotal && remainingBytes <= retentionPolicy.maxBytes) break;
    if (archive(session)) remainingBytes -= session.size;
  }

  remainingBytes = [...remaining.values()].reduce((sum, session) => sum + session.size, 0);
  const projectLimitExceeded = groups.some(
    (group) => group.sessions.filter((session) => remaining.has(session.path)).length > retentionPolicy.maxPerProject,
  );
  const limitedByProtection =
    projectLimitExceeded || remaining.size > retentionPolicy.maxTotal || remainingBytes > retentionPolicy.maxBytes;
  return { archived, archivedBytes, errors, remaining: remaining.size, remainingBytes, limitedByProtection };
}

/** Run at most daily unless forced. Limits are soft when protected sessions alone exceed them. */
export async function enforceRetention(current?: string, force = false): Promise<RetentionResult | undefined> {
  const now = Date.now();
  if (!force && !maintenanceDue(now)) return undefined;

  mkdirSync(TRASH_ROOT, { recursive: true });
  // Claim today's maintenance before scanning so concurrently opened pi windows back off.
  writeFileSync(MAINTENANCE_MARKER, new Date(now).toISOString());

  const purged = purgeExpiredTrash(now);
  const groups = await loadGroups(current);
  return { ...archiveExcess(groups, current, now), purged };
}
