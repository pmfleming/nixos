import { homedir } from "node:os";
import { SessionManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { choiceMap, loadGroups, pickGroup, recordCurrentBranch, sessionLabel, sessionTitle } from "./sessions.ts";
import { RecentSessionsSidebar, type SidebarChoice, type SidebarTheme } from "./sidebar.ts";
import { launchNewChat, launchSession } from "./terminal.ts";
import { BACK, CANCEL, CONTINUE, NEW_CHAT, RENAME, SESSION_ACTIONS, type RecentContext, type SessionGroup, type SessionRow } from "./types.ts";

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

async function chooseSession(ctx: RecentContext, group: SessionGroup): Promise<SessionRow | typeof NEW_CHAT_CHOICE | typeof BACK_CHOICE | undefined> {
  const current = ctx.sessionManager.getSessionFile();
  const sessions = choiceMap(group.sessions, (session) => sessionLabel(session, current));
  const choice = await ctx.ui.select(`${group.label}: recent chats`, [NEW_CHAT_CHOICE, ...sessions.keys(), BACK_CHOICE, CANCEL]);
  if (!choice || choice === CANCEL) return undefined;
  if (choice === NEW_CHAT_CHOICE || choice === BACK_CHOICE) return choice;
  return sessions.get(choice);
}

async function actOnSession(pi: ExtensionAPI, ctx: RecentContext, group: SessionGroup, session: SessionRow): Promise<"back" | "done"> {
  const action = await ctx.ui.select(sessionTitle(session), SESSION_ACTIONS);
  if (action === BACK) return "back";
  if (action === RENAME) {
    await rename(pi, ctx, session);
    return "back";
  }
  if (action === NEW_CHAT) {
    notifyLaunch(ctx, launchNewChat(group, ctx.cwd || homedir()), "new chat");
    return "done";
  }
  if (action === CONTINUE) {
    notifyLaunch(ctx, launchSession(session, ctx.cwd || homedir()), "chat");
    return "done";
  }
  return "done";
}

type CustomUiHandle = { requestRender: () => void; terminal?: { rows?: number } };
type OverlayHandle = { focus?: () => void };
type CustomRecentContext = RecentContext & {
  mode?: string;
  ui: RecentContext["ui"] & {
    custom?: <T>(
      factory: (tui: CustomUiHandle, theme: unknown, keybindings: unknown, done: (value: T) => void) => unknown,
      options?: unknown,
    ) => Promise<T | undefined>;
  };
};

function hasCustomTui(ctx: CustomRecentContext): boolean {
  return ctx.mode === "tui" && typeof ctx.ui.custom === "function";
}

async function openSidebar(pi: ExtensionAPI, ctx: CustomRecentContext): Promise<void> {
  const current = ctx.sessionManager.getSessionFile();
  const groups = await loadGroups(current);
  if (groups.length === 0) {
    ctx.ui.notify("No saved chats found", "warning");
    return;
  }

  const choice = await ctx.ui.custom?.<SidebarChoice>(
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
      onHandle: (handle: OverlayHandle) => handle.focus?.(),
    },
  );

  if (!choice) return;
  if (choice.action === "rename") {
    if (await rename(pi, ctx, choice.session)) await openSidebar(pi, ctx);
    return;
  }
  if (choice.action === "new") {
    notifyLaunch(ctx, launchNewChat(choice.group, ctx.cwd || homedir()), "new chat");
    return;
  }
  notifyLaunch(ctx, launchSession(choice.session, ctx.cwd || homedir()), "chat");
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
        notifyLaunch(ctx, launchNewChat(group, ctx.cwd || homedir()), "new chat");
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

  // Store branch metadata in the session itself. SessionManager.listAll() does
  // not expose historical Git state, so querying the repository while listing
  // would incorrectly label every old session with today's branch.
  pi.on("session_start", async (_event, ctx) => {
    recordCurrentBranch(pi, ctx.cwd, ctx.sessionManager.getSessionFile());
  });
  pi.on("before_agent_start", async (_event, ctx) => {
    recordCurrentBranch(pi, ctx.cwd, ctx.sessionManager.getSessionFile());
  });
}
