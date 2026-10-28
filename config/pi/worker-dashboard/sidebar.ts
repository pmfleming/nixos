import type { Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, type Component } from "@earendil-works/pi-tui";
import { workerShortcut } from "../lib/tui.ts";
import { CatalogMonitor, type Scope, type SessionGroup, type WorkerEntry } from "./catalog.ts";
import { plain, stale } from "./state.ts";
import { workerState } from "./widget.ts";

export type SidebarAction = { kind: "chat" | "report" | "unload"; worker: WorkerEntry } | { kind: "close-chats" };
type Row = { key: string; group?: SessionGroup; worker?: WorkerEntry; text?: string };

export class WorkersSidebar implements Component {
  private selected = 0;
  private offset = 0;
  private expanded = new Set<string>();
  private rows: Row[] = [];
  private unsubscribe: () => void;
  private disposed = false;
  private monitor: CatalogMonitor;
  private scope: Scope;
  private currentId: string;
  private theme: Pick<Theme, "fg">;
  private height: () => number;
  private redraw: () => void;
  private done: () => void;
  private action: (action: SidebarAction) => void;
  private chatStatus: (key: string) => string | undefined;
  constructor(monitor: CatalogMonitor, scope: Scope, currentId: string, theme: Pick<Theme, "fg">,
    height: () => number, redraw: () => void, done: () => void,
    action: (action: SidebarAction) => void, chatStatus: (key: string) => string | undefined = () => undefined) {
    this.monitor = monitor; this.scope = scope; this.currentId = currentId; this.theme = theme;
    this.height = height; this.redraw = redraw; this.done = done; this.action = action; this.chatStatus = chatStatus;
    this.expanded.add(currentId);
    this.unsubscribe = monitor.subscribe(() => { this.rebuild(); this.redraw(); });
  }
  private rebuild(): void {
    const previous = this.rows[this.selected];
    const rows: Row[] = [];
    const groups = this.monitor.value.groups.filter(group => this.scope === "all" || group.id === this.currentId);
    for (const group of groups) {
      if (this.scope === "all") rows.push({ key: `session:${group.id}`, group });
      if (this.scope === "all" && !this.expanded.has(group.id)) continue;
      for (const worker of [...group.workers].sort((a, b) => a.number - b.number))
        rows.push({ key: `worker:${worker.key}`, group, worker });
      for (const [index, text] of group.errors.entries()) rows.push({ key: `error:${group.id}:${index}`, group, text });
      if (!group.workers.length && !group.errors.length) rows.push({ key: `empty:${group.id}`, group, text: "No workers associated with this session" });
    }
    for (const [index, error] of this.monitor.value.errors.entries()) rows.push({ key: `error:${index}`, text: error });
    this.rows = rows;
    let index = rows.findIndex(row => row.key === previous?.key);
    if (index < 0 && previous?.group) index = rows.findIndex(row => row.key === `session:${previous.group!.id}`);
    this.selected = index >= 0 ? index : Math.max(0, Math.min(this.selected, rows.length - 1));
  }
  handleInput(data: string): void {
    if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || matchesKey(data, "alt+0") || matchesKey(data, "alt+w")) {
      this.done(); return;
    }
    const row = this.rows[this.selected];
    if (matchesKey(data, "x")) { this.action({ kind: "close-chats" }); return; }
    const number = workerShortcut(data);
    if (number !== undefined) {
      const group = row?.group ?? this.monitor.value.groups.find(group => group.id === this.currentId);
      const worker = group?.workers.find(worker => worker.number === number);
      if (worker) this.action({ kind: "chat", worker });
      return;
    }
    if (matchesKey(data, "enter")) {
      if (row?.worker) this.action({ kind: "chat", worker: row.worker });
      else if (row?.group && this.scope === "all") this.toggle(row.group.id);
    } else if (matchesKey(data, "r") && row?.worker) this.action({ kind: "report", worker: row.worker });
    else if (matchesKey(data, "u") && row?.worker) this.action({ kind: "unload", worker: row.worker });
    else if (matchesKey(data, "right") && row?.group && this.scope === "all") {
      this.expanded.add(row.group.id); this.rebuild();
    } else if (matchesKey(data, "left") && row?.group && this.scope === "all") {
      this.expanded.delete(row.group.id); this.rebuild();
    } else if (matchesKey(data, "up")) this.selected--;
    else if (matchesKey(data, "down")) this.selected++;
    else if (matchesKey(data, "pageUp")) this.selected -= this.page();
    else if (matchesKey(data, "pageDown")) this.selected += this.page();
    else if (matchesKey(data, "home")) this.selected = 0;
    else if (matchesKey(data, "end")) this.selected = this.rows.length - 1;
    this.selected = Math.max(0, Math.min(this.selected, this.rows.length - 1));
    this.redraw();
  }
  private toggle(id: string): void {
    if (this.expanded.has(id)) this.expanded.delete(id); else this.expanded.add(id);
    this.rebuild();
  }
  private page(): number { return Math.max(1, this.height() - 7); }
  render(width: number): string[] {
    const height = Math.max(1, this.height()), page = this.page(), inner = Math.max(0, width - 4);
    this.offset = Math.min(this.offset, Math.max(0, this.rows.length - page));
    if (this.selected < this.offset) this.offset = this.selected;
    if (this.selected >= this.offset + page) this.offset = this.selected - page + 1;
    const frame = (left: string, right: string) => this.theme.fg("border", left + "─".repeat(Math.max(0, width - 2)) + right);
    const line = (text: string) => `${this.theme.fg("border", "│")} ${truncateToWidth(text, inner, "…", true)} ${this.theme.fg("border", "│")}`;
    const title = this.scope === "session" ? "Workers · this session" : "All sessions & workers";
    const lines = [frame("┌", "┐"), line(this.theme.fg("accent", title)),
      line(this.theme.fg("dim", "↑↓ select · ←→ expand · Enter chat · Esc close")), frame("├", "┤")];
    const rows = this.rows.slice(this.offset, this.offset + page);
    for (const [index, row] of rows.entries()) {
      let text: string;
      if (row.worker) {
        const worker = row.worker;
        const state = this.chatStatus(worker.key) ?? workerState(worker.task);
        text = `${this.scope === "all" ? "  " : ""}${worker.number}. ${state} · ${plain(worker.task.title || worker.task.id, 120)} · ${worker.snapshot.run}`;
        if (stale(worker.snapshot)) text = `STALE · ${text}`;
      } else if (row.text) text = `${this.scope === "all" ? "  " : ""}${plain(row.text, 1024)}`;
      else if (row.group) {
        const group = row.group;
        text = `${this.expanded.has(group.id) ? "▾" : "▸"} ${group.current ? "● " : ""}${group.name} (${group.workers.length})${group.errors.length ? " !" : ""} · ${group.id.slice(0, 8)}`;
      } else text = "";
      const selected = this.offset + index === this.selected;
      lines.push(line((selected ? this.theme.fg("accent", "› ") : "  ") + this.theme.fg(selected ? "accent" : row.text ? "dim" : "text", text)));
    }
    if (!rows.length) lines.push(line("No workers associated with this session"));
    while (lines.length < height - 3) lines.push(line(""));
    lines.push(frame("├", "┤"), line(this.theme.fg("dim", "R reports · U unload · X close chats · Alt+0 back")), frame("└", "┘"));
    return lines.slice(0, height).map(text => truncateToWidth(text, Math.max(0, width), ""));
  }
  invalidate(): void {}
  dispose(): void { if (!this.disposed) { this.disposed = true; this.unsubscribe(); } }
}
