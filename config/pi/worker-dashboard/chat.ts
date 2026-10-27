import type { Theme } from "@earendil-works/pi-coding-agent";
import { Editor, Text, matchesKey, type Component, type Focusable, type TUI } from "@earendil-works/pi-tui";
import { fitLines, selectTheme, workerShortcut } from "../lib/tui.ts";
import { MultiSessionRuntime, type ChatSession } from "./runtime.ts";
import { plain } from "./state.ts";

type Colors = Pick<Theme, "fg">;

// A foreground chat surface, not a report viewer. The runtime owns the sessions;
// disposing this surface only detaches input/rendering, never aborts a worker.
export class WorkerChatWindow implements Component, Focusable {
  private editor: Editor;
  private current?: ChatSession;
  private unsubscribe: () => void;
  private generation = 0;
  private disposed = false;
  private loading = "";
  private notice = "";
  private cacheKey = "";
  private history: string[] = [];
  private bodyHeight = 1;
  get focused(): boolean { return this.editor.focused; }
  set focused(value: boolean) { this.editor.focused = value; }

  constructor(private runtime: MultiSessionRuntime, private tui: TUI, private theme: Colors,
    private rows: () => number, private load: (number: number) => Promise<ChatSession>,
    private done: () => void, private dashboard: () => void, initial: number) {
    this.editor = new Editor(tui, {
      borderColor: text => theme.fg("accent", text),
      selectList: selectTheme(theme),
    });
    this.editor.onChange = text => { if (this.current) this.current.draft = text; };
    this.editor.onSubmit = text => { this.editor.setText(text); void this.submit(text); };
    this.unsubscribe = runtime.subscribe(() => {
      if (this.current && !this.current.submitting && !this.current.aborting
        && this.editor.getExpandedText() !== this.current.draft) this.editor.setText(this.current.draft);
      this.redraw();
    });
    void this.switch(initial);
  }
  private redraw(): void { if (!this.disposed) this.tui.requestRender(); }
  private save(): void { if (this.current) this.current.draft = this.editor.getExpandedText(); }
  async switch(number: number): Promise<void> {
    this.save();
    const generation = ++this.generation;
    this.loading = `Loading worker ${number}…`; this.notice = ""; this.redraw();
    try {
      const chat = await this.load(number);
      if (this.disposed || generation !== this.generation) return;
      this.current = chat;
      this.editor.setText(chat.draft);
      this.cacheKey = "";
    } catch (error) {
      if (!this.disposed && generation === this.generation) this.notice = plain(String(error), 1024);
    } finally {
      if (!this.disposed && generation === this.generation) { this.loading = ""; this.redraw(); }
    }
  }
  private async submit(text: string, behavior: "steer" | "followUp" = "steer"): Promise<void> {
    const chat = this.current;
    if (!chat || this.loading || chat.submitting || chat.aborting || !text.trim()) return;
    if (text.trim() === "/back") { this.done(); return; }
    if (text.trim() === "/abort") { this.editor.setText(""); await this.abort(); return; }
    if (text.trim() === "/unload") {
      try { await this.runtime.unload(chat.key); this.done(); }
      catch (error) { this.notice = plain(String(error), 1024); this.redraw(); }
      return;
    }
    if (text.trim().startsWith("/")) {
      this.notice = "Worker chat commands: /back, /abort, /unload. Native Pi menus remain in the orchestrator.";
      this.redraw(); return;
    }
    chat.draft = text;
    this.notice = "";
    try { await chat.send(text, behavior); }
    catch (error) { this.notice = plain(String(error), 1024); }
    if (this.disposed || this.current !== chat) return;
    this.editor.setText(chat.draft); this.redraw();
  }
  private async abort(): Promise<void> {
    const chat = this.current;
    if (!chat || chat.status !== "running") return;
    await chat.abort();
    if (!this.disposed && this.current === chat) this.editor.setText(chat.draft);
    this.redraw();
  }
  handleInput(data: string): void {
    if (matchesKey(data, "alt+0") || matchesKey(data, "ctrl+d")) { this.save(); this.done(); return; }
    if (matchesKey(data, "alt+w")) { this.save(); this.dashboard(); return; }
    const number = workerShortcut(data);
    if (number !== undefined) { void this.switch(number); return; }
    if (matchesKey(data, "escape")) { void this.abort(); return; }
    if (matchesKey(data, "pageUp")) {
      if (this.current) this.current.scroll += this.bodyHeight;
    } else if (matchesKey(data, "pageDown")) {
      if (this.current) this.current.scroll = Math.max(0, this.current.scroll - this.bodyHeight);
    } else if (matchesKey(data, "alt+enter")) {
      void this.submit(this.editor.getExpandedText(), "followUp");
    } else if (matchesKey(data, "ctrl+c")) {
      if (!this.current?.aborting) this.editor.setText("");
    } else if (this.current && !this.loading && !this.current.submitting && !this.current.aborting) this.editor.handleInput(data);
    this.redraw();
  }
  render(width: number): string[] {
    const height = Math.max(1, this.rows());
    const chat = this.current;
    const label = chat ? `Worker ${chat.attachment.number} · ${chat.attachment.id} · ${chat.status}` : "Worker chat";
    const editor = this.editor.render(Math.max(1, width));
    const editorLines = editor.slice(-Math.max(1, Math.min(editor.length, height - 5)));
    const header = [this.theme.fg("accent", label), this.theme.fg("dim", "Orchestrator and other loaded chats continue in background")];
    const status = this.loading || this.notice || chat?.error || chat?.activity || "Enter sends · while busy: Enter steers, Alt+Enter queues follow-up";
    const tabs = this.runtime.list().map(item => `${item === chat ? "●" : "○"}${item.attachment.number} ${item.status}`).join(" · ");
    const footer = [this.theme.fg(this.notice || chat?.error ? "warning" : "muted", status),
      this.theme.fg("dim", tabs || "No worker chat loaded"),
      this.theme.fg("dim", "Alt+0 orchestrator · Alt+1–9 chat · Alt+W reports · PgUp/PgDn history · Esc abort worker")];
    this.bodyHeight = Math.max(0, height - header.length - footer.length - editorLines.length);
    const key = `${chat?.key}:${chat?.version}:${width}`;
    if (key !== this.cacheKey) {
      const content = chat ? [...chat.messages.map(message => `${message.role}:\n${message.text}`),
        ...(chat.partial ? [`assistant (streaming):\n${chat.partial}`] : [])].join("\n\n") : "";
      this.history = new Text(content || "No messages yet. Loading a chat does not send a prompt.", 0, 0).render(Math.max(1, width));
      this.cacheKey = key;
    }
    const maxScroll = Math.max(0, this.history.length - this.bodyHeight);
    if (chat) chat.scroll = Math.min(chat.scroll, maxScroll);
    const end = this.history.length - (chat?.scroll ?? 0);
    const body = this.history.slice(Math.max(0, end - this.bodyHeight), end);
    while (body.length < this.bodyHeight) body.unshift("");
    return fitLines([...header, ...body, ...editorLines, ...footer], width, height);
  }
  invalidate(): void { this.cacheKey = ""; this.editor.invalidate(); }
  dispose(): void {
    if (this.disposed) return;
    this.save(); this.disposed = true; this.generation++; this.unsubscribe();
  }
}
