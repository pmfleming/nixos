import type { Attachment } from "./attachment.ts";
import { RpcConnection, type Connection, type RecordValue } from "./rpc.ts";
import { plain } from "./state.ts";

export type ChatMessage = { role: string; text: string };
export type ChatStatus = "opening" | "idle" | "running" | "error" | "closed";
function object(value: unknown): RecordValue { return value && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : {}; }
function display(value: unknown, limit = 16 * 1024): string {
  return typeof value === "string" ? value.slice(0, limit).split("\n").map(line => plain(line, limit)).join("\n") : "";
}
export function chatMessage(value: unknown): ChatMessage | undefined {
  const message = object(value);
  if (message.role === "system") return;
  const role = plain(message.role, 40) || "message";
  let text = "";
  if (typeof message.content === "string") text = message.content;
  else if (Array.isArray(message.content)) text = message.content.map(raw => {
    const block = object(raw);
    if (block.type === "text") return String(block.text ?? "");
    if (block.type === "thinking") return "[thinking]";
    if (block.type === "image") return "[image]";
    if (block.type === "toolCall") return `[${plain(block.name, 80)}] ${(JSON.stringify(block.arguments) ?? "{}").slice(0, 1000)}`;
    return "";
  }).filter(Boolean).join("\n");
  else text = String(message.summary ?? message.output ?? "");
  if (typeof message.errorMessage === "string") text += `\n${message.errorMessage}`;
  return { role: role === "toolResult" ? `tool: ${plain(message.toolName, 80)}` : role, text: display(text) };
}

export class ChatSession {
  status: ChatStatus = "opening";
  messages: ChatMessage[] = [];
  partial = "";
  activity = "";
  error = "";
  draft = "";
  scroll = 0;
  submitting = false;
  aborting = false;
  uncertain = false;
  version = 0;
  private blocks = new Map<number, string>();
  private settlements = 0;
  private unsubscribe: () => void;
  private disposed?: Promise<void>;
  readonly attachment: Attachment;
  private connection: Connection;
  private changed: () => void;
  constructor(attachment: Attachment, connection: Connection, changed: () => void) {
    this.attachment = attachment; this.connection = connection; this.changed = changed;
    this.unsubscribe = connection.subscribe(event => this.event(event));
  }
  get key(): string { return this.attachment.key; }
  private update(): void { this.version++; this.changed(); }
  private append(message: ChatMessage): void {
    this.messages.push(message);
    // Display memory is bounded. The complete history stays in Pi's session file.
    while (this.messages.length > 100 || this.messages.reduce((sum, item) => sum + item.text.length, 0) > 256 * 1024) this.messages.shift();
  }
  async initialize(): Promise<void> {
    const state = await this.connection.request("get_state");
    if (this.disposed) throw new Error("Chat runtime stopped during initialization");
    if (state.sessionFile !== this.attachment.sessionFile) throw new Error("RPC opened the wrong worker session");
    const model = object(state.model);
    const args = this.attachment.spec.args;
    const flag = (name: string) => args[args.indexOf(name) + 1];
    if (model.provider !== flag("--provider") || model.id !== flag("--model") || state.thinkingLevel !== flag("--thinking"))
      throw new Error("RPC worker model/reasoning mismatch");
    const data = await this.connection.request("get_messages");
    if (this.disposed) throw new Error("Chat runtime stopped during history loading");
    this.messages = [];
    for (const raw of Array.isArray(data.messages) ? data.messages : []) {
      const message = chatMessage(raw);
      if (message) this.append(message);
    }
    this.status = state.isStreaming || state.isCompacting ? "running" : "idle";
    this.update();
  }
  private event(event: RecordValue): void {
    if (this.disposed) return;
    if (event.type === "agent_start" || event.type === "compaction_start") this.status = "running";
    else if (event.type === "agent_settled") {
      this.settlements++;
      this.status = "idle"; this.activity = event.aborted ? "Aborted" : "";
      this.uncertain = false;
    } else if (event.type === "message_start" && object(event.message).role === "assistant") {
      this.blocks.clear(); this.partial = "";
    } else if (event.type === "message_update") {
      const delta = object(event.assistantMessageEvent);
      const index = typeof delta.contentIndex === "number" ? delta.contentIndex : 0;
      if (!Number.isSafeInteger(index) || index < 0 || index >= 256) return;
      if (delta.type === "text_delta") this.blocks.set(index, ((this.blocks.get(index) ?? "") + String(delta.delta ?? "")).slice(-16 * 1024));
      else if (delta.type === "text_end") this.blocks.set(index, display(delta.content));
      else if (delta.type === "thinking_start") this.activity = "Thinking…";
      this.partial = display([...this.blocks.entries()].sort(([a], [b]) => a - b).map(([, text]) => text).join("\n"));
    } else if (event.type === "message_end") {
      const message = chatMessage(event.message);
      if (message) this.append(message);
      if (object(event.message).role === "assistant") { this.blocks.clear(); this.partial = ""; }
    } else if (event.type === "tool_execution_start") this.activity = `Tool: ${plain(event.toolName, 80)}`;
    else if (event.type === "tool_execution_end") this.activity = event.isError ? `Tool failed: ${plain(event.toolName, 80)}` : "";
    else if (event.type === "auto_retry_start") this.activity = `Retry ${event.attempt}: ${plain(event.errorMessage)}`;
    else if (event.type === "runtime_error") { this.error = display(event.message, 8192); this.status = "error"; }
    else if (event.type === "extension_ui_request") {
      // Worker extensions are disabled. Never silently approve an unexpected request.
      this.error = "Unexpected worker UI request; no permission was granted.";
    } else return;
    this.update();
  }
  async send(text: string, behavior: "steer" | "followUp" = "steer"): Promise<void> {
    if (!text.trim() || this.submitting || this.aborting || this.status === "opening") return;
    if (this.status === "error" || this.status === "closed") throw new Error("Worker connection is not usable; no prompt sent");
    if (this.uncertain) throw new Error("Previous delivery is uncertain. Wait for worker activity before sending more.");
    if (text.length > 256 * 1024) throw new Error("Worker prompt exceeds 256 KiB");
    const settlements = this.settlements;
    this.submitting = true; this.error = ""; this.update();
    try {
      const data = await this.connection.request("prompt", { message: text, streamingBehavior: behavior });
      if (data.disposition !== "started" && data.disposition !== "queued" && data.disposition !== "handled") {
        this.uncertain = true;
        throw new Error("Worker returned an unknown prompt disposition; do not resend automatically");
      }
      if (data.disposition === "started" && settlements === this.settlements) this.status = "running";
      this.draft = "";
      this.activity = data.disposition === "queued" ? `${behavior === "steer" ? "Steering" : "Follow-up"} queued` : this.activity;
    } catch (error) {
      this.error = display(error instanceof Error ? error.message : String(error), 8192);
      if (/uncertain|timed out|write failed|input failed|exited/i.test(this.error)) this.uncertain = true;
      throw error;
    } finally { this.submitting = false; this.update(); }
  }
  async abort(): Promise<void> {
    if (this.aborting) return;
    this.aborting = true; this.update();
    let queued: string[] = [];
    try {
      const queue = await this.connection.request("clear_queue");
      queued = [queue.steering, queue.followUp].flatMap(value => Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : []);
      await this.connection.request("abort");
    } catch (error) { this.error = display(String(error), 8192); }
    finally {
      if (queued.length) this.draft = [this.draft, ...queued].filter(Boolean).join("\n\n");
      this.aborting = false; this.update();
    }
  }
  close(): Promise<void> {
    if (this.disposed) return this.disposed;
    this.unsubscribe();
    this.status = "closed";
    this.disposed = (async () => { try { await this.connection.close(); } finally { await this.attachment.release(); } })();
    this.update();
    return this.disposed;
  }
}

export class MultiSessionRuntime {
  private sessions = new Map<string, Promise<ChatSession>>();
  private ready = new Map<string, ChatSession>();
  private listeners = new Set<() => void>();
  private disposed = false;
  private stopping?: Promise<void>;
  private connect: (attachment: Attachment) => Connection;
  constructor(connect: (attachment: Attachment) => Connection = attachment => new RpcConnection(attachment.spec)) { this.connect = connect; }
  subscribe(listener: () => void): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  private changed = () => { if (!this.disposed) for (const listener of this.listeners) listener(); };
  list(): ChatSession[] { return [...this.ready.values()]; }
  get size(): number { return this.sessions.size; }
  get busy(): boolean {
    return this.sessions.size > this.ready.size || this.list().some(chat => chat.status === "opening" || chat.status === "running" || chat.submitting || chat.aborting);
  }
  async open(key: string, prepare: () => Promise<Attachment>): Promise<ChatSession> {
    if (this.disposed) throw new Error("Multi-session runtime stopped");
    const previous = this.sessions.get(key);
    if (previous) return previous;
    if (this.sessions.size >= 9) throw new Error("Nine worker chats are already loaded. Unload an idle chat before opening another.");
    const opening = (async () => {
      const attachment = await prepare();
      if (this.disposed) { await attachment.release(); throw new Error("Runtime stopped while preparing worker"); }
      let chat: ChatSession;
      try { chat = new ChatSession(attachment, this.connect(attachment), this.changed); }
      catch (error) { await attachment.release(); throw error; }
      this.ready.set(key, chat);
      try {
        await chat.initialize();
        if (this.disposed) throw new Error("Runtime stopped while loading worker");
        this.ready.set(key, chat); this.changed();
        return chat;
      } catch (error) { await chat.close(); this.ready.delete(key); throw error; }
    })();
    this.sessions.set(key, opening);
    try { return await opening; }
    catch (error) { if (this.sessions.get(key) === opening) this.sessions.delete(key); throw error; }
  }
  async unload(key: string): Promise<void> {
    const chat = this.ready.get(key);
    if (!chat) return;
    if (chat.status === "running" || chat.submitting || chat.aborting) throw new Error("Worker is busy. Abort it explicitly before unloading.");
    await chat.close(); this.sessions.delete(key); this.ready.delete(key); this.changed();
  }
  stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    this.disposed = true;
    this.stopping = (async () => {
      // Close children still initializing so their pending requests reject now.
      await Promise.allSettled([...this.ready.values()].map(chat => chat.close()));
      // Pending prepare/startup is fenced, too. Waiting closes every owned child.
      const settled = await Promise.allSettled([...this.sessions.values()]);
      await Promise.allSettled(settled.flatMap(result => result.status === "fulfilled" ? [result.value.close()] : []));
      this.ready.clear(); this.sessions.clear(); this.listeners.clear();
    })();
    return this.stopping;
  }
}
