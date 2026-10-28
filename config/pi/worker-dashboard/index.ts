import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { getAgentDir, SessionManager, type ExtensionAPI, type ExtensionContext, type SessionInfo } from "@earendil-works/pi-coding-agent";
import { prepareAttachment } from "./attachment.ts";
import { CatalogMonitor, CatalogSlots, loadCatalog, type Scope, type SessionIdentity, type WorkerEntry } from "./catalog.ts";
import { WorkerChatWindow } from "./chat.ts";
import { WorkerDashboard } from "./dashboard.ts";
import { WorkerMonitor } from "./monitor.ts";
import { createRun, readOwner } from "./ownership.ts";
import { MultiSessionRuntime } from "./runtime.ts";
import { WorkersSidebar, type SidebarAction } from "./sidebar.ts";
import { observe, plain } from "./state.ts";
import { WorkerSlots } from "./widget.ts";

function identity(ctx: ExtensionContext): SessionIdentity {
  return { id: ctx.sessionManager.getSessionId(), name: ctx.sessionManager.getSessionName() || ctx.sessionManager.getSessionId(), cwd: ctx.cwd };
}

export default function workerDashboard(pi: ExtensionAPI) {
  const root = process.env.PI_WORKERS_ROOT || join(getAgentDir(), "workers");
  let context: ExtensionContext | undefined;
  let scope: Scope = "session";
  let monitor: CatalogMonitor | undefined;
  let slots = new CatalogSlots();
  let runtime: MultiSessionRuntime | undefined;
  type View = { close?: () => void; dispose?: () => void };
  let sidebar: (View & { scope: Scope }) | undefined;
  let reports: View | undefined;
  let chat: (View & { ownerId: string; number: number; view?: WorkerChatWindow }) | undefined;

  function close(kind: "sidebar" | "reports" | "chat"): void {
    const current = kind === "sidebar" ? sidebar : kind === "reports" ? reports : chat;
    if (kind === "sidebar") sidebar = undefined;
    else if (kind === "reports") reports = undefined;
    else chat = undefined;
    current?.dispose?.(); current?.close?.();
  }
  function stop(): void {
    close("sidebar"); close("reports"); close("chat");
    monitor?.stop(); monitor = undefined;
    context?.ui.setWidget("workers", undefined);
    context?.ui.setStatus("workers", undefined);
    context = undefined;
  }
  function follow(ctx: ExtensionContext, nextScope: Scope): CatalogMonitor {
    if (monitor && context === ctx && scope === nextScope) return monitor;
    monitor?.stop();
    context = ctx; scope = nextScope;
    let cachedSessions: SessionInfo[] = [], loadedAt = 0;
    const current = new CatalogMonitor(async () => {
      if (nextScope === "all" && Date.now() - loadedAt > 15_000) {
        cachedSessions = await SessionManager.listAll();
        loadedAt = Date.now();
      }
      return loadCatalog(root, identity(ctx), slots, cachedSessions, nextScope);
    });
    monitor = current; current.start();
    return current;
  }
  function ensureRuntime(): MultiSessionRuntime {
    if (!runtime) runtime = new MultiSessionRuntime();
    return runtime;
  }
  function worker(current: CatalogMonitor, ownerId: string, number: number): WorkerEntry | undefined {
    return current.value.groups.find(group => group.id === ownerId)?.workers.find(item => item.number === number);
  }
  async function openChat(ctx: ExtensionContext, ownerId: string, number: number): Promise<void> {
    if (ctx.mode !== "tui") return;
    if (chat?.ownerId === ownerId) { chat.number = number; await chat.view?.switch(number); return; }
    close("chat"); close("sidebar"); close("reports");
    const current = follow(ctx, ownerId === identity(ctx).id ? scope : "all");
    const sessions = ensureRuntime();
    const interaction: NonNullable<typeof chat> = { ownerId, number };
    chat = interaction;
    try {
      await current.refresh();
      if (chat !== interaction || monitor !== current || runtime !== sessions) return;
      if (!worker(current, ownerId, interaction.number)) {
        ctx.ui.notify(`Worker ${interaction.number} is not associated with this session. /workers lists its workers.`, "info"); return;
      }
      await ctx.ui.custom<void>((tui, theme, _keys, done) => {
        interaction.close = done;
        interaction.view = new WorkerChatWindow(sessions, tui, theme, () => Math.max(1, tui.terminal.rows), async target => {
          await current.refresh();
          if (monitor !== current || chat !== interaction) throw new Error("Worker view was replaced");
          const item = worker(current, ownerId, target);
          if (!item) throw new Error(`Worker ${target} is not associated with the selected session`);
          return sessions.open(item.key, async () => {
            const owner = await readOwner(root, item.snapshot.run);
            if (owner.sessionId !== ownerId) throw new Error("Worker ownership changed; refusing attachment");
            return prepareAttachment(item.snapshot, item.task.id, item.number, ctx.sessionManager.getSessionFile());
          });
        }, done, () => { close("chat"); void openSidebar(ctx, scope); }, interaction.number);
        interaction.dispose = () => interaction.view?.dispose();
        return interaction.view;
      }, { overlay: true, overlayOptions: { anchor: "center", width: "100%", maxHeight: "100%" } });
    } finally {
      interaction.dispose?.();
      if (chat === interaction) chat = undefined;
    }
  }
  async function openReport(ctx: ExtensionContext, item: WorkerEntry): Promise<void> {
    close("sidebar"); close("reports"); close("chat");
    const ownerId = item.ownerId;
    const reportMonitor = new WorkerMonitor(async () => {
      if ((await readOwner(root, item.snapshot.run)).sessionId !== ownerId) throw new Error("Worker ownership changed");
      return observe(root, item.snapshot.run);
    });
    const interaction: View = { dispose: () => reportMonitor.stop() };
    reports = interaction;
    try {
      await reportMonitor.refresh();
      if (reports !== interaction || context !== ctx) return;
      const snapshot = reportMonitor.value.snapshot;
      if (!snapshot) { ctx.ui.notify(reportMonitor.value.error || "Worker unavailable", "warning"); return; }
      const numbers = new WorkerSlots(); numbers.update(snapshot);
      await ctx.ui.custom<void>((tui, theme, _keys, done) => {
        interaction.close = done;
        const view = new WorkerDashboard(reportMonitor, theme, () => tui.requestRender(),
          () => Math.max(1, tui.terminal.rows), done, { slots: numbers, worker: numbers.number(item.task.id),
            chat: number => {
              const task = reportMonitor.value.snapshot && numbers.worker(reportMonitor.value.snapshot, number);
              const target = monitor?.value.groups.find(group => group.id === ownerId)?.workers
                .find(candidate => candidate.snapshot.run === item.snapshot.run && candidate.task.id === task?.id);
              if (target) { close("reports"); void openChat(ctx, ownerId, target.number); }
            } });
        interaction.dispose = () => { reportMonitor.stop(); view.dispose(); };
        reportMonitor.start();
        return view;
      }, { overlay: true, overlayOptions: { anchor: "right-center", width: 76, maxHeight: "100%" } });
    } finally { interaction.dispose?.(); if (reports === interaction) reports = undefined; }
  }
  async function act(ctx: ExtensionContext, action: SidebarAction): Promise<void> {
    try {
      if (action.kind === "chat") await openChat(ctx, action.worker.ownerId, action.worker.number);
      else if (action.kind === "report") await openReport(ctx, action.worker);
      else if (action.kind === "unload") await runtime?.unload(action.worker.key);
      else {
        const old = runtime;
        if (old?.busy && !await ctx.ui.confirm("Stop worker chats?", "This aborts this window's loaded workers. Alt+0 only backgrounds them.")) return;
        if (context !== ctx || runtime !== old) return;
        runtime = undefined;
        await old?.stop();
        if (context === ctx) await monitor?.refresh();
      }
    } catch (error) { if (context === ctx) ctx.ui.notify(plain(String(error), 1024), "warning"); }
  }
  async function openSidebar(ctx: ExtensionContext, nextScope: Scope): Promise<void> {
    if (ctx.mode !== "tui") { ctx.ui.notify("Worker sidebars require interactive Pi.", "info"); return; }
    if (sidebar?.scope === nextScope) { close("sidebar"); return; }
    close("sidebar"); close("chat"); close("reports");
    const current = follow(ctx, nextScope);
    const interaction: NonNullable<typeof sidebar> = { scope: nextScope };
    sidebar = interaction;
    try {
      await current.refresh();
      if (sidebar !== interaction || monitor !== current) return;
      await ctx.ui.custom<void>((tui, theme, _keys, done) => {
        interaction.close = done;
        const view = new WorkersSidebar(current, nextScope, identity(ctx).id, theme,
          () => Math.max(1, tui.terminal.rows), () => tui.requestRender(), done,
          action => { void act(ctx, action); }, key => {
            const loaded = runtime?.list().find(chat => chat.key === key);
            return loaded ? `Chat ${loaded.status}` : undefined;
          });
        // Subscribing must not create processes; merely opening a sidebar is read-only.
        const unsubscribe = runtime?.subscribe(() => tui.requestRender());
        interaction.dispose = () => { view.dispose(); unsubscribe?.(); };
        return view;
      }, { overlay: true, overlayOptions: { anchor: "right-center", width: 64, maxHeight: "100%" },
        onHandle: handle => handle.focus() });
    } finally { interaction.dispose?.(); if (sidebar === interaction) sidebar = undefined; }
  }

  pi.registerCommand("workers", { description: "Show the workers associated with this session in a sidebar",
    handler: async (_args, ctx) => openSidebar(ctx, "session") });
  pi.registerCommand("workers-all", { description: "Show all sessions with expandable worker submenus",
    handler: async (_args, ctx) => openSidebar(ctx, "all") });
  pi.registerShortcut("alt+w", { description: "Show this session's worker sidebar", handler: ctx => {
    if (ctx.mode === "tui") return openSidebar(ctx, "session");
  } });
  pi.registerShortcut("alt+0", { description: "Return to orchestrator without stopping workers", handler: () => { close("chat"); close("reports"); close("sidebar"); } });
  for (const number of [1, 2, 3, 4, 5, 6, 7, 8, 9] as const) pi.registerShortcut(`alt+${number}`, {
    description: `Open this session's worker ${number}`, handler: ctx => {
      if (ctx.mode === "tui") return openChat(ctx, identity(ctx).id, number);
    },
  });
  pi.registerTool({
    name: "register_worker_run", label: "Register worker run",
    description: "Create a new worker run associated with the current Pi session BEFORE launching its workers. Returns the run directory. Write supervisor control/state.json (or control/dashboard.json) and task files there. Existing runs cannot be adopted or reassigned. Required for workers to appear in /workers and /workers-all.",
    parameters: Type.Object({ run: Type.String({ description: "New unique run ID, e.g. 20261028T120000Z; letters, digits, dots, dashes and underscores only" }) }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const owner = identity(ctx);
      const directory = await createRun(root, params.run, { version: 1, sessionId: owner.id, name: owner.name, cwd: owner.cwd, created: Date.now() });
      return { content: [{ type: "text", text: `Worker run created: ${directory}\nOwning session: ${owner.id}` }], details: { directory, sessionId: owner.id } };
    },
  });
  pi.on("session_start", (_event, ctx) => {
    stop(); slots = new CatalogSlots(); scope = "session";
    if (ctx.mode !== "tui") return;
    follow(ctx, "session");
    ctx.ui.setWidget("workers", undefined); ctx.ui.setStatus("workers", undefined);
  });
  const guardReplacement = (_event: unknown, ctx: ExtensionContext) => {
    if (runtime?.busy) {
      ctx.ui.notify("Worker chats are active. Use X in /workers to stop them before replacing this session.", "warning");
      return { cancel: true };
    }
  };
  pi.on("session_before_switch", guardReplacement);
  pi.on("session_before_fork", guardReplacement);
  pi.on("session_shutdown", async () => {
    stop();
    const old = runtime; runtime = undefined;
    await old?.stop();
  });
}
