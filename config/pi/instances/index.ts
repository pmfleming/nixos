import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { scan } from "./discovery.ts";
import { plain, textContent } from "./model.ts";
import { createPublisher, type Publisher } from "./publisher.ts";
import { registryPath } from "./storage.ts";
import { InstancesView } from "./view.ts";

export default function instances(pi: ExtensionAPI) {
  const directory = registryPath();
  let publisher: Publisher | undefined;
  let starting: Promise<void> | undefined;
  let generation = 0;
  type Screen = { view?: InstancesView; close?: () => void };
  let screen: Screen | undefined;
  let autoOpen: ReturnType<typeof setTimeout> | undefined;

  async function open(ctx: ExtensionContext): Promise<void> {
    if (ctx.mode !== "tui") return;
    if (screen) return;
    const current: Screen = {};
    screen = current;
    try {
      await ctx.ui.custom<void>((tui, theme, keys, done) => {
        current.close = done;
        current.view = new InstancesView(theme, keys, () => Math.max(1, tui.terminal.rows - 2),
          () => tui.requestRender(), done, () => scan(directory));
        current.view.start();
        return current.view;
      }, { overlay: true, overlayOptions: { anchor: "center", width: "100%", maxHeight: "100%" } });
    } finally {
      current.view?.dispose();
      if (screen === current) screen = undefined;
    }
  }
  pi.registerFlag("instances", { description: "Open the read-only local Pi instance overview at startup", type: "boolean", default: false });
  pi.registerCommand("instances", { description: "Read-only live overview of all local Pi instances and workers", handler: async (_args, ctx) => open(ctx) });

  pi.on("session_start", (_event, ctx) => {
    const epoch = ++generation;
    // No factory-time resources. Instrument TUI, JSON, print and RPC alike when loaded.
    starting = (async () => {
      try {
        const next = await createPublisher(directory, ctx);
        if (generation !== epoch) { await next.stop(); return; }
        publisher = next;
      } catch (error) {
        if (generation === epoch && ctx.mode === "tui") ctx.ui.notify(`Instance telemetry unavailable: ${plain(String(error))}`, "warning");
      }
      if (generation === epoch && pi.getFlag("instances") === true && ctx.mode === "tui") {
        autoOpen = setTimeout(() => {
          if (generation === epoch) void open(ctx).then(() => {
            if (generation === epoch) ctx.shutdown();
          }).catch(error => ctx.ui.notify(plain(String(error)), "error"));
        }, 250);
      }
    })();
    return starting;
  });
  pi.on("session_shutdown", async () => {
    generation++;
    clearTimeout(autoOpen);
    screen?.view?.dispose(); screen?.close?.(); screen = undefined;
    await starting;
    const previous = publisher; publisher = undefined;
    await previous?.stop();
  });
  pi.on("session_info_changed", (_event, ctx) => { publisher?.sync(ctx); });
  pi.on("model_select", (event, ctx) => {
    publisher?.sync(ctx);
    if (publisher) publisher.record.model = plain(`${event.model.provider}/${event.model.id}`, 160);
  });
  pi.on("before_agent_start", (event, ctx) => {
    publisher?.sync(ctx);
    // Bootstrap Pi predates messageType and only emits user prompts here.
    publisher?.startRun(!("messageType" in event) || event.messageType === "user" ? event.prompt : undefined);
  });
  pi.on("agent_start", () => { publisher?.working(); });
  pi.on("turn_start", () => { publisher?.turn(); });
  pi.on("message_update", event => {
    const update = event.assistantMessageEvent;
    // Liveness only for thinking events. Never copy thinking/signatures into telemetry.
    publisher?.stream(update.type === "text_delta" ? update.delta : undefined);
  });
  pi.on("message_end", event => {
    if (!publisher) return;
    if (event.message.role === "assistant") {
      const text = textContent(event.message.content);
      if (text) publisher.record.progress = text;
      if (event.message.stopReason === "error") publisher.event("Model reported an error");
    }
  });
  pi.on("tool_execution_start", event => { publisher?.toolStart(event.toolCallId, event.toolName); });
  pi.on("tool_execution_update", () => { publisher?.stream(); });
  pi.on("tool_execution_end", event => { publisher?.toolEnd(event.toolCallId, event.toolName, event.isError); });
  // agent_end is not final settlement: retries and queued work can follow it.
  pi.on("agent_settled", event => { publisher?.settled("aborted" in event && event.aborted === true); });
  // Older Pi accepts event registrations but never emits these newer UI events.
  // Keep this compatibility overload narrow; all other hooks use the SDK types.
  const promptEvents = pi as ExtensionAPI & {
    on(event: "ui_prompt_start" | "ui_prompt_end", handler: (event: unknown, ctx: ExtensionContext) => void): void;
  };
  promptEvents.on("ui_prompt_start", (_event, ctx) => { publisher?.promptUI(true, ctx.isIdle()); });
  promptEvents.on("ui_prompt_end", (_event, ctx) => { publisher?.promptUI(false, ctx.isIdle()); });
}
