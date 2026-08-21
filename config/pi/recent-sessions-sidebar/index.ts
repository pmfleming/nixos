import { homedir } from "node:os";
import { SessionManager, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  PIN_ENTRY_TYPE,
  choiceMap,
  enforceRetention,
  invalidateSessionMetadata,
  loadGroups,
  pickGroup,
  recordCurrentBranch,
  sessionLabel,
  sessionTitle,
  type RetentionResult,
} from "./sessions.ts";
import { RecentSessionsSidebar, type SidebarChoice, type SidebarTheme } from "./sidebar.ts";
import { launchNewChat, launchSession } from "./terminal.ts";
import { BACK, CANCEL, CONTINUE, NEW_CHAT, PIN, RENAME, UNPIN, type RecentContext, type SessionGroup, type SessionRow } from "./types.ts";

const NEW_CHAT_CHOICE = `＋ ${NEW_CHAT}`;
const BACK_CHOICE = `← ${BACK}`;

async function rename(pi: ExtensionAPI, ctx: RecentContext, session: SessionRow): Promise<boolean> {
  const value = await ctx.ui.input("Rename chat", sessionTitle(session));
  if (value == null) return false;
  const name = value.trim();
  if (!name) return false;
  if (session.path === ctx.sessionManager.getSessionFile()) pi.setSessionName(name);
  else await SessionManager.open(session.path).appendSessionInfo(name);
  ctx.ui.notify(`Renamed chat: ${name}`, "info");
  return true;
}

function notifyLaunch(ctx: RecentContext, error: string | undefined, what: string): void {
  if (error) ctx.ui.notify(`Failed to open ${what}: ${error}`, "error");
  else ctx.ui.notify(`Opened ${what} in a new pi window`, "info");
}

function formatMib(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
}

function notifyRetention(ctx: RecentContext, result: RetentionResult | undefined): void {
  if (!result) return;
  if (result.archived > 0) {
    ctx.ui.notify(`Archived ${result.archived} old chats (${formatMib(result.archivedBytes)}); ${result.remaining} remain`, "info");
  }
  if (result.purged > 0) ctx.ui.notify(`Permanently removed ${result.purged} expired chats from retention trash`, "info");
  if (result.errors > 0) ctx.ui.notify(`Could not archive ${result.errors} chats`, "warning");
  if (result.limitedByProtection) ctx.ui.notify("Retention limits remain exceeded by current, recent, named, or pinned chats", "warning");
}

async function togglePin(pi: ExtensionAPI, ctx: RecentContext, session: SessionRow): Promise<void> {
  const pinned = !session.pinned;
  if (session.path === ctx.sessionManager.getSessionFile()) pi.appendEntry(PIN_ENTRY_TYPE, { pinned });
  else SessionManager.open(session.path).appendCustomEntry(PIN_ENTRY_TYPE, { pinned });
  invalidateSessionMetadata(session.path);
  ctx.ui.notify(`${pinned ? "Pinned" : "Unpinned"} chat: ${sessionTitle(session)}`, "info");
}

async function chooseSession(ctx: RecentContext, group: SessionGroup): Promise<SessionRow | typeof NEW_CHAT_CHOICE | typeof BACK_CHOICE | undefined> {
  const current = ctx.sessionManager.getSessionFile();
  const sessions = choiceMap(group.sessions, (session) => sessionLabel(session, current));
  const choice = await ctx.ui.select(`${group.label}: recent chats`, [NEW_CHAT_CHOICE, ...sessions.keys(), BACK_CHOICE, CANCEL]);
  if (!choice || choice === CANCEL) return undefined;
  if (choice === NEW_CHAT_CHOICE || choice === BACK_CHOICE) return choice;
  return sessions.get(choice);
}

async function actOnSession(pi: ExtensionAPI, ctx: RecentContext, group: SessionGroup, session: SessionRow): Promise<"back" | "done"> {
  const pinAction = session.pinned ? UNPIN : PIN;
  const action = await ctx.ui.select(sessionTitle(session), [CONTINUE, NEW_CHAT, RENAME, pinAction, BACK, CANCEL]);
  if (action === BACK) return "back";
  if (action === RENAME) {
    await rename(pi, ctx, session);
    return "back";
  }
  if (action === pinAction) {
    await togglePin(pi, ctx, session);
    return "back";
  }
  if (action === NEW_CHAT) {
    notifyLaunch(ctx, await launchNewChat(group, ctx.cwd || homedir()), "new chat");
    return "done";
  }
  if (action === CONTINUE) {
    notifyLaunch(ctx, await launchSession(session, ctx.cwd || homedir()), "chat");
    return "done";
  }
  return "done";
}

type CustomRecentContext = ExtensionContext;

function hasCustomTui(ctx: CustomRecentContext): boolean {
  return ctx.mode === "tui";
}

async function openSidebar(pi: ExtensionAPI, ctx: CustomRecentContext): Promise<void> {
  const current = ctx.sessionManager.getSessionFile();
  const groups = await loadGroups(current);
  if (groups.length === 0) {
    ctx.ui.notify("No saved chats found", "warning");
    return;
  }

  const choice = await ctx.ui.custom<SidebarChoice>(
    (tui, theme, _keybindings, done) => {
      const sidebar = new RecentSessionsSidebar(
        groups,
        current,
        theme as SidebarTheme,
        () => Math.max(8, tui.terminal?.rows ?? process.stdout.rows ?? 24),
        done,
      );
      return {
        render: (width: number) => sidebar.render(width),
        invalidate: () => sidebar.invalidate(),
        handleInput: (data: string) => {
          sidebar.handleInput(data);
          tui.requestRender();
        },
      };
    },
    {
      overlay: true,
      overlayOptions: {
        anchor: "right-center",
        width: 76,
        maxHeight: "100%",
        margin: { right: 1, top: 0, bottom: 0 },
      },
      onHandle: (handle) => handle.focus(),
    },
  );

  if (!choice) return;
  if (choice.action === "rename") {
    if (await rename(pi, ctx, choice.session)) await openSidebar(pi, ctx);
    return;
  }
  if (choice.action === "pin") {
    await togglePin(pi, ctx, choice.session);
    await openSidebar(pi, ctx);
    return;
  }
  if (choice.action === "new") {
    notifyLaunch(ctx, await launchNewChat(choice.group, ctx.cwd || homedir()), "new chat");
    return;
  }
  notifyLaunch(ctx, await launchSession(choice.session, ctx.cwd || homedir()), "chat");
}

async function openRecentSessions(pi: ExtensionAPI, ctx: CustomRecentContext): Promise<void> {
  if (!ctx.hasUI) return;
  recordCurrentBranch(pi, ctx.cwd, ctx.sessionManager.getSessionFile());
  if (hasCustomTui(ctx)) {
    await openSidebar(pi, ctx);
    return;
  }

  while (true) {
    const group = await pickGroup(ctx);
    if (!group) return;

    while (true) {
      const picked = await chooseSession(ctx, group);
      if (!picked) return;
      if (picked === BACK_CHOICE) break;
      if (picked === NEW_CHAT_CHOICE) {
        notifyLaunch(ctx, await launchNewChat(group, ctx.cwd || homedir()), "new chat");
        return;
      }

      if ((await actOnSession(pi, ctx, group, picked)) === "done") return;
    }
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("recent-sessions", {
    description: "Open recent chats sidebar grouped by project",
    handler: async (_args, ctx) => openRecentSessions(pi, ctx),
  });
  pi.registerShortcut("ctrl+shift+r", { description: "Open recent chats sidebar", handler: async (ctx) => openRecentSessions(pi, ctx) });
  pi.registerCommand("recent-sessions-cleanup", {
    description: "Enforce recent-chat count, project, disk, and trash limits now",
    handler: async (_args, ctx) => notifyRetention(ctx, await enforceRetention(ctx.sessionManager.getSessionFile(), true)),
  });

  // Store branch metadata in the session itself. SessionManager.listAll() does
  // not expose historical Git state, so querying the repository while listing
  // would incorrectly label every old session with today's branch.
  pi.on("session_start", async (_event, ctx) => {
    const current = ctx.sessionManager.getSessionFile();
    recordCurrentBranch(pi, ctx.cwd, current);
    notifyRetention(ctx, await enforceRetention(current));
  });
  pi.on("before_agent_start", async (_event, ctx) => {
    recordCurrentBranch(pi, ctx.cwd, ctx.sessionManager.getSessionFile());
  });
}
