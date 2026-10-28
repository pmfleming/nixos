import { randomUUID } from "node:crypto";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ownIdentity } from "./discovery.ts";
import { plain, textContent, type InstanceRecord, type ProcessIdentity } from "./model.ts";
import { privateDirectory, pruneRecords, writeRecord } from "./storage.ts";

export class Publisher {
  readonly record: InstanceRecord;
  private timer?: ReturnType<typeof setInterval>;
  private writing?: Promise<void>;
  private closed = false;
  private warned = false;
  private active = new Map<string, string>();
  private streamText = "";
  private waiting = 0;
  private directory: string;
  private warn: (message: string) => void;
  constructor(directory: string, identity: ProcessIdentity, warn: (message: string) => void, now = Date.now()) {
    this.directory = directory;
    this.warn = warn;
    this.record = { ...identity, version: 1, token: randomUUID(), registeredAt: now, updatedAt: now, lastActivityAt: now,
      sessionId: "", sessionFile: "", name: "", cwd: "", mode: "", model: "", state: "idle",
      tools: [], turns: 0, toolCount: 0, prompt: "", progress: "", events: [] };
  }
  sync(ctx: ExtensionContext): void {
    this.record.sessionId = plain(ctx.sessionManager.getSessionId(), 200);
    this.record.sessionFile = plain(ctx.sessionManager.getSessionFile(), 2048);
    this.record.name = plain(ctx.sessionManager.getSessionName(), 160);
    this.record.cwd = plain(ctx.cwd, 2048);
    this.record.mode = ctx.mode;
    this.record.model = ctx.model ? plain(`${ctx.model.provider}/${ctx.model.id}`, 160) : "";
  }
  seed(ctx: ExtensionContext): void {
    this.sync(ctx);
    this.record.state = ctx.isIdle() ? "idle" : "working";
    for (const entry of ctx.sessionManager.getBranch().slice(-80)) {
      if (entry.type !== "message") continue;
      const message = entry.message;
      if (message.role === "user") this.record.prompt = textContent(message.content) || this.record.prompt;
      if (message.role === "assistant") this.record.progress = textContent(message.content) || this.record.progress;
    }
    this.event("Observer attached; earlier activity not tracked");
  }
  event(text: string): void {
    if (this.closed) return;
    const at = Date.now();
    this.record.lastActivityAt = at;
    this.record.events.push({ at, text: plain(text) });
    this.record.events = this.record.events.slice(-12);
  }
  working(): void {
    this.record.state = this.waiting ? "waiting" : "working";
  }
  startRun(prompt?: string): void {
    this.working();
    if (prompt) this.record.prompt = plain(prompt);
    this.event("Agent started");
  }
  turn(): void {
    this.record.turns++;
    this.streamText = "";
    this.event(`Model turn ${this.record.turns}`);
  }
  stream(delta?: string): void {
    this.record.lastActivityAt = Date.now();
    if (delta && this.streamText.length < 800) {
      this.streamText += delta.slice(0, 800 - this.streamText.length);
      this.record.progress = plain(this.streamText);
    }
  }
  toolStart(id: string, name: string): void {
    if (this.active.size < 128) this.active.set(id, plain(name, 80));
    this.record.tools = [...this.active.values()].slice(0, 32);
    this.record.toolCount++;
    this.event(`Tool started: ${name}`);
  }
  toolEnd(id: string, name: string, error: boolean): void {
    this.active.delete(id);
    this.record.tools = [...this.active.values()].slice(0, 32);
    this.event(`Tool ${error ? "failed" : "finished"}: ${name}`);
  }
  promptUI(open: boolean, idle: boolean): void {
    this.waiting = Math.max(0, this.waiting + (open ? 1 : -1));
    this.record.state = this.waiting ? "waiting" : idle ? "idle" : "working";
    this.event(open ? "Waiting for UI input" : "UI closed");
  }
  settled(aborted: boolean): void {
    this.active.clear(); this.record.tools = [];
    this.record.state = this.waiting ? "waiting" : "idle";
    this.event(aborted ? "Agent aborted; idle" : "Agent settled; idle");
  }
  async start(): Promise<void> {
    await privateDirectory(this.directory, true);
    await pruneRecords(this.directory);
    await this.flush();
    if (this.closed) return;
    this.timer = setInterval(() => { void this.flush(); }, 2000);
    this.timer.unref();
  }
  flush(): Promise<void> {
    if (this.closed) return Promise.resolve();
    if (this.writing) return this.writing;
    this.record.updatedAt = Date.now();
    const snapshot = structuredClone(this.record);
    this.writing = writeRecord(this.directory, snapshot).catch(error => this.error(error)).finally(() => { this.writing = undefined; });
    return this.writing;
  }
  private error(error: unknown): void {
    if (!this.warned) { this.warned = true; this.warn(`Instance telemetry unavailable: ${plain(String(error))}`); }
  }
  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    await this.writing;
    this.record.endedAt = Date.now();
    this.record.updatedAt = this.record.endedAt;
    await writeRecord(this.directory, this.record).catch(error => this.error(error));
  }
}
export async function createPublisher(directory: string, ctx: ExtensionContext): Promise<Publisher> {
  const publisher = new Publisher(directory, await ownIdentity(), message => {
    if (ctx.mode === "tui") ctx.ui.notify(message, "warning");
  });
  publisher.seed(ctx);
  await publisher.start();
  return publisher;
}
