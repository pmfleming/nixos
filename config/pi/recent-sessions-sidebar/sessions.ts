import { homedir } from "node:os";
import { basename } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { run } from "./shell.ts";
import type { ProjectInfo, RecentContext, SessionGroup, SessionInfo, SessionRow } from "./types.ts";

function clean(value?: string): string {
  return (value ?? "").replace(/\s+/g, " ").trim();
}

export function sessionTitle(session: SessionInfo): string {
  return clean(session.name || session.firstMessage) || "(empty chat)";
}

export function formatDate(date: Date): string {
  return date.toLocaleString(undefined, { month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

function gitProject(cwd?: string): { project: ProjectInfo; branch?: string } | undefined {
  if (!cwd) return undefined;
  const topLevel = run("git", ["rev-parse", "--show-toplevel"], cwd);
  if (!topLevel) return undefined;
  const branch = run("git", ["branch", "--show-current"], cwd) || undefined;
  return {
    project: { key: `git:${topLevel}`, label: basename(topLevel) || topLevel, cwd: topLevel, kind: "git" },
    branch,
  };
}

function projectFor(session: SessionInfo): { project: ProjectInfo; branch?: string } {
  const git = gitProject(session.cwd);
  if (git) return git;
  if (session.cwd) {
    return {
      project: { key: `dir:${session.cwd}`, label: basename(session.cwd) || session.cwd, cwd: session.cwd, kind: "folder" },
    };
  }
  return { project: { key: "__chats__", label: "Chats", kind: "chats" } };
}

function enrich(session: SessionInfo): SessionRow {
  return { ...session, ...projectFor(session) };
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
  const sessions = (await SessionManager.listAll()).map(enrich).sort((a, b) => b.modified.getTime() - a.modified.getTime());
  return buildGroups(sessions, current);
}

function compactPath(path?: string): string {
  return path?.replace(homedir(), "~") ?? "";
}

export function groupLabel(group: SessionGroup): string {
  const active = group.hasCurrent ? "●" : " ";
  const icon = group.kind === "git" ? "" : group.kind === "folder" ? "📁" : "💬";
  const cwd = group.cwd ? ` — ${compactPath(group.cwd)}` : "";
  return `${active} ${icon} ${group.label} (${group.sessions.length}) · ${formatDate(new Date(group.latestMs))}${cwd}`;
}

export function sessionLabel(session: SessionRow, current?: string): string {
  const active = session.path === current ? "●" : " ";
  const branch = session.branch ? `  ${session.branch} ·` : "";
  return `${active} Chat · ${formatDate(session.modified)} ·${branch} ${sessionTitle(session)}`;
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
