import { statSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import { SessionManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { run } from "./shell.ts";
import type { ProjectInfo, RecentContext, SessionGroup, SessionInfo, SessionRow } from "./types.ts";

const BRANCH_ENTRY_TYPE = "recent-sessions-sidebar.branch";
const recordedBranches = new Map<string, string>();
const storedBranchCache = new Map<string, { mtimeMs: number; size: number; branch?: string }>();

type StoredBranchData = { branch?: unknown };

function clean(value?: string): string {
  return (value ?? "").replace(/\s+/g, " ").trim();
}

function storedBranch(sessionPath: string): string | undefined {
  try {
    const { mtimeMs, size } = statSync(sessionPath);
    const cached = storedBranchCache.get(sessionPath);
    if (cached?.mtimeMs === mtimeMs && cached.size === size) return cached.branch;

    let branch: string | undefined;
    const entries = SessionManager.open(sessionPath).getEntries();
    for (let index = entries.length - 1; index >= 0; index--) {
      const entry = entries[index];
      if (entry?.type !== "custom" || entry.customType !== BRANCH_ENTRY_TYPE) continue;
      const data = entry.data as StoredBranchData | undefined;
      if (typeof data?.branch === "string" && data.branch) {
        branch = data.branch;
        break;
      }
    }

    storedBranchCache.set(sessionPath, { mtimeMs, size, branch });
    return branch;
  } catch {
    // A concurrently removed or malformed session should not break the sidebar.
    storedBranchCache.delete(sessionPath);
    return undefined;
  }
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

  const previous = recordedBranches.get(sessionPath) ?? storedBranch(sessionPath);
  if (previous === branch) {
    recordedBranches.set(sessionPath, branch);
    return;
  }

  pi.appendEntry(BRANCH_ENTRY_TYPE, { branch });
  recordedBranches.set(sessionPath, branch);
  storedBranchCache.delete(sessionPath);
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
  return {
    ...session,
    project: projectFor(session, projectCache),
    branch: storedBranch(session.path),
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
  const active = session.path === current ? "●" : " ";
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
