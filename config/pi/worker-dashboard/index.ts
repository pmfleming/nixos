import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { WorkerDashboard } from "./dashboard.ts";
import { prepareAttachment } from "./attachment.ts";
import { WorkerChatWindow } from "./chat.ts";
import { MultiSessionRuntime } from "./runtime.ts";
import { WorkerMonitor } from "./monitor.ts";
import { listRuns, observe, plain, stale, type Snapshot } from "./state.ts";
import { hasActiveWorkers, renderWorkerBox, WorkerSlots } from "./widget.ts";

export default function workerDashboard(pi: ExtensionAPI) {
  const root = process.env.PI_WORKERS_ROOT || join(homedir(), "Projects", "shelllist-orchestration");
  let selected: string | undefined;
  let monitor: WorkerMonitor | undefined;
  let unsubscribe: (() => void) | undefined;
  let context: ExtensionContext | undefined;
  let showWidget = true;
  const slots = new WorkerSlots();
  type Panel = { close?: () => void; view?: WorkerDashboard; worker?: number };
  let panel: Panel | undefined;
  let runtime: MultiSessionRuntime | undefined;
  let unsubscribeRuntime: (() => void) | undefined;
  type ChatWindow = { close?: () => void; view?: WorkerChatWindow; number: number };
  let chatWindow: ChatWindow | undefined;

  function paint(ctx: ExtensionContext, current: WorkerMonitor): void {
    const { snapshot } = current.value;
    const chats = () => new Map(runtime?.list().filter(chat => chat.key.startsWith(`${current.value.snapshot?.run}/`))
      .map(chat => [chat.attachment.id, `Chat ${chat.status}`]));
    ctx.ui.setStatus("workers", undefined);
    if (!showWidget || !hasActiveWorkers(current.value, chats())) {
      ctx.ui.setWidget("workers", undefined);
      return;
    }
    if (snapshot) slots.update(snapshot);
    ctx.ui.setWidget("workers", (_tui, theme) => ({
      render: (width: number) => renderWorkerBox(current.value, slots, theme, width, chats()),
      invalidate: () => {},
    }), { placement: "belowEditor" });
  }
  function closePanel(): void {
    const current = panel;
    panel = undefined;
    current?.close?.();
  }
  function closeChat(): void {
    const current = chatWindow;
    chatWindow = undefined;
    current?.close?.();
  }
  function stop(): void {
    closeChat(); closePanel();
    unsubscribe?.(); unsubscribe = undefined;
    monitor?.stop(); monitor = undefined;
    context?.ui.setStatus("workers", undefined);
    context?.ui.setWidget("workers", undefined);
    context = undefined;
  }
  function start(ctx: ExtensionContext): void {
    stop();
    if (ctx.mode !== "tui") return;
    context = ctx;
    const current = new WorkerMonitor(() => observe(root, selected));
    monitor = current;
    let previous: Snapshot | undefined;
    unsubscribe = current.subscribe(value => {
      paint(ctx, current);
      const next = value.snapshot;
      if (next && previous?.run === next.run && !stale(next)) {
        const changed = next.tasks.filter(task => {
          const old = previous?.tasks.find(candidate => candidate.id === task.id);
          return old && (old.state !== task.state || old.reportedStatus !== task.reportedStatus)
            && (task.state.includes("review-required") || task.state === "launch-failed" || task.reportedStatus === "blocked");
        });
        if (changed.length) {
          const attention = changed.some(task => !!task.failure || task.state !== "review-required" || task.reportedStatus === "blocked");
          ctx.ui.notify(`${changed.map(task => task.id).join(", ")}: ${attention ? "needs attention" : "handoff ready for review"}. /workers`, attention ? "warning" : "info");
        }
      }
      previous = next;
    });
    current.start();
  }

  function ensureRuntime(): MultiSessionRuntime {
    if (!runtime) {
      runtime = new MultiSessionRuntime();
      unsubscribeRuntime = runtime.subscribe(() => { if (context && monitor) paint(context, monitor); });
    }
    return runtime;
  }

  async function openChat(ctx: ExtensionContext, number: number): Promise<void> {
    if (ctx.mode !== "tui") return;
    if (chatWindow) {
      chatWindow.number = number;
      void chatWindow.view?.switch(number);
      return;
    }
    if (!monitor) start(ctx);
    const current = monitor;
    if (!current) return;
    const sessions = ensureRuntime();
    const interaction: ChatWindow = { number };
    chatWindow = interaction;
    try {
      await current.refresh();
      if (monitor !== current || runtime !== sessions || chatWindow !== interaction) return;
      const snapshot = current.value.snapshot;
      if (!snapshot || !slots.worker(snapshot, interaction.number)) {
        ctx.ui.notify(`Worker ${interaction.number} is not available. Alt+W lists workers.`, "info");
        return;
      }
      closePanel();
      await ctx.ui.custom<void>((tui, theme, _keys, done) => {
        interaction.close = () => done();
        interaction.view = new WorkerChatWindow(sessions, tui, theme, () => Math.max(1, tui.terminal.rows), async worker => {
          const run = current.value.snapshot;
          const task = run && slots.worker(run, worker);
          if (!run || !task) throw new Error(`Worker ${worker} is not available`);
          return sessions.open(`${run.run}/${task.id}`, () => prepareAttachment(run, task.id, worker, ctx.sessionManager.getSessionFile()));
        }, interaction.close, () => { closeChat(); void openPanel(ctx); }, interaction.number);
        return interaction.view;
      }, { overlay: true, overlayOptions: { anchor: "center", width: "100%", maxHeight: "100%" } });
    } finally { if (chatWindow === interaction) chatWindow = undefined; }
  }

  async function openPanel(ctx: ExtensionContext, worker?: number): Promise<void> {
    if (ctx.mode !== "tui") return;
    if (panel) {
      if (worker !== undefined) { panel.worker = worker; panel.view?.jump(worker); }
      else closePanel();
      return;
    }
    if (!monitor) start(ctx);
    const current = monitor;
    if (!current) return;
    const interaction: Panel = { worker };
    panel = interaction;
    try {
      await current.refresh();
      // Do not install UI from a retired runtime or race another shortcut.
      if (monitor !== current || panel !== interaction) return;
      const target = interaction.worker;
      if (target !== undefined && (!current.value.snapshot || !slots.worker(current.value.snapshot, target))) {
        ctx.ui.notify(`Worker ${target} is not available. Alt+W lists workers.`, "info");
        return;
      }
      await ctx.ui.custom<void>((tui, theme, _keys, done) => {
        interaction.close = () => done();
        interaction.view = new WorkerDashboard(current, theme,
          () => tui.requestRender(), () => Math.max(1, tui.terminal.rows), interaction.close, { slots, worker: target,
            chat: number => { closePanel(); void openChat(ctx, number); } });
        return interaction.view;
      }, { overlay: true, overlayOptions: { anchor: "center", width: "94%", maxHeight: "96%" } });
    } finally { if (panel === interaction) panel = undefined; }
  }

  pi.registerShortcut("alt+w", { description: "Open workers / return to orchestrator", handler: ctx => openPanel(ctx) });
  pi.registerShortcut("alt+0", { description: "Return to orchestrator; keep worker chats running", handler: () => { closeChat(); closePanel(); } });
  for (const worker of [1, 2, 3, 4, 5, 6, 7, 8, 9] as const) {
    pi.registerShortcut(`alt+${worker}`, {
      description: `Foreground worker ${worker} chat; keep other sessions running`, handler: ctx => openChat(ctx, worker),
    });
  }

  pi.registerCommand("workers", {
    description: "Worker reports and multi-session chats; chat N, unload N, close-chats, show/hide, runs, latest or run ID",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui") {
        ctx.ui.notify("/workers requires the interactive TUI; use the orchestration status.py in scripts.", "info");
        return;
      }
      if (!monitor) start(ctx);
      const option = args.trim();
      const chatCommand = /^(chat|unload) ([1-9][0-9]?)$/.exec(option);
      if (chatCommand) {
        const number = Number(chatCommand[2]);
        if (chatCommand[1] === "chat") await openChat(ctx, number);
        else {
          const snapshot = monitor?.value.snapshot;
          const task = snapshot && slots.worker(snapshot, number);
          if (!snapshot || !task) { ctx.ui.notify(`Worker ${number} is unavailable`, "warning"); return; }
          try { await runtime?.unload(`${snapshot.run}/${task.id}`); }
          catch (error) { ctx.ui.notify(plain(String(error), 1024), "warning"); }
        }
        return;
      }
      if (option === "close-chats") {
        const busy = runtime?.busy;
        if (busy && !await ctx.ui.confirm("Stop worker chats?", "This aborts loaded worker activity. Alt+0 only backgrounds it.")) return;
        closeChat(); unsubscribeRuntime?.(); unsubscribeRuntime = undefined;
        const old = runtime; runtime = undefined;
        const activeContext = context;
        await old?.stop();
        if (context && context === activeContext && monitor) paint(context, monitor);
        return;
      }
      if (option && option !== "hide" && option !== "show" && runtime?.size) {
        ctx.ui.notify("Unload/close loaded worker chats before changing the followed run.", "warning"); return;
      }
      if (option === "hide" || option === "show") {
        showWidget = option === "show";
        if (monitor) paint(ctx, monitor);
        return;
      }
      if (option === "runs") {
        let runs: string[];
        try { runs = await listRuns(root); }
        catch (error) { ctx.ui.notify(plain(String(error)), "error"); return; }
        if (!runs.length) { ctx.ui.notify(`No runs under ${root}`, "info"); return; }
        const choice = await ctx.ui.select("Worker run (read-only)", ["latest", ...runs]);
        if (!choice) return;
        selected = choice === "latest" ? undefined : choice;
        start(ctx);
      } else if (option) {
        if (option !== "latest" && !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(option)) {
          ctx.ui.notify("Usage: /workers [chat N|unload N|close-chats|show|hide|runs|latest|RUN-ID]", "warning"); return;
        }
        if (option !== "latest") {
          const candidate = await observe(root, option);
          if (!candidate.snapshot) {
            ctx.ui.notify(`Unknown or unavailable worker run "${plain(option)}". Current selection unchanged. Use /workers latest or /workers runs.`, "warning");
            return;
          }
        }
        selected = option === "latest" ? undefined : option;
        start(ctx);
      }
      await openPanel(ctx);
    },
  });
  pi.on("session_start", (_event, ctx) => start(ctx));
  const guardSessionReplacement = (_event: unknown, ctx: ExtensionContext) => {
    if (runtime?.busy) {
      ctx.ui.notify("Worker chats are active. Use Alt+0 to background them, or /workers close-chats before replacing the calling session.", "warning");
      return { cancel: true };
    }
  };
  pi.on("session_before_switch", guardSessionReplacement);
  pi.on("session_before_fork", guardSessionReplacement);
  pi.on("session_shutdown", async () => {
    stop(); unsubscribeRuntime?.(); unsubscribeRuntime = undefined;
    const old = runtime; runtime = undefined;
    await old?.stop();
  });
}
