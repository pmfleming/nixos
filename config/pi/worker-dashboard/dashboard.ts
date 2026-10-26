import type { Theme } from "@earendil-works/pi-coding-agent";
import { Key, SelectList, Text, matchesKey, truncateToWidth, type Component } from "@earendil-works/pi-tui";
import { WorkerMonitor } from "./monitor.ts";
import { age, detail, plain, stale, summary, type DetailFile, type Worker } from "./state.ts";
import { WorkerSlots } from "./widget.ts";

type Colors = Pick<Theme, "fg">;

export class WorkerDashboard implements Component {
  private monitor: WorkerMonitor;
  private theme: Colors;
  private redraw: () => void;
  private rows: () => number;
  private done: () => void;
  private unsubscribe: () => void;
  private list?: SelectList;
  private selected?: string;
  private selectedRun?: string;
  private visibleRows = 0;
  private inDetail = false;
  private file: DetailFile = "PROGRESS.md";
  private body = "";
  private offset = 0;
  private bodyHeight = 1;
  private maxOffset = 0;
  private detailGeneration = 0;
  private disposed = false;

  private slots: WorkerSlots;
  private openChat?: (number: number) => void;

  constructor(monitor: WorkerMonitor, theme: Colors, redraw: () => void, rows: () => number, done: () => void,
    options: { slots?: WorkerSlots; worker?: number; chat?: (number: number) => void } = {}) {
    this.monitor = monitor; this.theme = theme; this.redraw = redraw; this.rows = rows; this.done = done;
    this.slots = options.slots ?? new WorkerSlots();
    this.openChat = options.chat;
    this.unsubscribe = monitor.subscribe(() => {
      this.rebuild();
      if (this.inDetail) void this.loadDetail();
      this.redraw();
    });
    if (options.worker !== undefined) this.jump(options.worker);
  }
  jump(number: number): void {
    const snapshot = this.monitor.value.snapshot;
    if (!snapshot) return;
    const task = this.slots.worker(snapshot, number);
    if (!task) return;
    this.selected = task.id;
    this.list?.setSelectedIndex(snapshot.tasks.findIndex(candidate => candidate.id === task.id));
    this.openDetail("PROGRESS.md");
    this.redraw();
  }
  private task(): Worker | undefined {
    return this.monitor.value.snapshot?.tasks.find(task => task.id === this.selected);
  }
  private rebuild(): void {
    const snapshot = this.monitor.value.snapshot;
    if (this.selectedRun !== snapshot?.run) {
      this.selectedRun = snapshot?.run;
      this.selected = undefined;
      this.inDetail = false;
      this.detailGeneration++;
      this.body = "";
    }
    const tasks = snapshot?.tasks ?? [];
    if (snapshot) this.slots.update(snapshot);
    this.visibleRows = Math.max(1, Math.min(12, this.rows() - 7));
    const list = new SelectList(tasks.map(task => ({ value: task.id,
      label: `${this.slots.number(task.id)} · ${task.state} · ${task.id}`,
      description: `${task.phase ? `${task.phase} · ` : ""}${age(task.started, task.ended)} · ${task.modelVerified ? "model verified" : "unverified"} · ${task.tools} tools`,
    })), this.visibleRows, {
      selectedPrefix: text => this.theme.fg("accent", text), selectedText: text => this.theme.fg("accent", text),
      description: text => this.theme.fg("muted", text), scrollInfo: text => this.theme.fg("dim", text), noMatch: text => this.theme.fg("dim", text),
    }, { minPrimaryColumnWidth: 10, maxPrimaryColumnWidth: 58 });
    const index = Math.max(0, tasks.findIndex(task => task.id === this.selected));
    list.setSelectedIndex(index);
    const nextSelected = tasks[index]?.id;
    if (this.selected !== nextSelected) {
      this.body = "Loading…";
      this.detailGeneration++;
      this.offset = 0;
    }
    this.selected = nextSelected;
    list.onSelectionChange = item => { this.selected = item.value; };
    list.onSelect = item => { this.selected = item.value; this.openDetail("PROGRESS.md"); };
    list.onCancel = () => this.done();
    this.list = list;
  }
  private openDetail(file: DetailFile): void {
    if (!this.task()) return;
    this.inDetail = true; this.file = file; this.offset = 0; this.body = "Loading…";
    void this.loadDetail();
  }
  private async loadDetail(): Promise<void> {
    const snapshot = this.monitor.value.snapshot;
    const id = this.selected;
    const generation = ++this.detailGeneration;
    if (!snapshot || !id) return;
    let body: string;
    try { body = await detail(snapshot, id, this.file); }
    catch (error) { body = `Detail unavailable or not written yet: ${plain(String(error), 1024)}`; }
    if (this.disposed || generation !== this.detailGeneration || !this.inDetail) return;
    this.body = body || "(empty file)";
    this.redraw();
  }
  handleInput(data: string): void {
    if (matchesKey(data, "alt+0") || matchesKey(data, "alt+w") || matchesKey(data, Key.ctrl("c"))) { this.done(); return; }
    for (const number of [1, 2, 3, 4, 5, 6, 7, 8, 9] as const) {
      if (matchesKey(data, `alt+${number}`)) {
        if (this.openChat) this.openChat(number); else this.jump(number);
        return;
      }
    }
    if (matchesKey(data, Key.escape)) {
      if (this.inDetail) { this.inDetail = false; this.detailGeneration++; }
      else this.done();
    } else if (matchesKey(data, "r")) this.openDetail("REPORT.md");
    else if (matchesKey(data, "p")) this.openDetail("PROGRESS.md");
    else if (matchesKey(data, "l")) this.openDetail("stderr.log");
    else if (this.inDetail) {
      if (matchesKey(data, Key.up)) this.offset--;
      if (matchesKey(data, Key.down)) this.offset++;
      if (matchesKey(data, Key.pageUp)) this.offset -= this.bodyHeight;
      if (matchesKey(data, Key.pageDown)) this.offset += this.bodyHeight;
      if (matchesKey(data, Key.home)) this.offset = 0;
      if (matchesKey(data, Key.end)) this.offset = this.maxOffset;
      this.offset = Math.max(0, Math.min(this.offset, this.maxOffset));
    } else this.list?.handleInput(data);
    this.redraw();
  }
  render(width: number): string[] {
    width = Math.max(0, width);
    const height = Math.max(1, this.rows() - 2);
    const snapshot = this.monitor.value.snapshot;
    if (!snapshot) {
      return [this.theme.fg("accent", "Workers"), this.monitor.value.error || "No orchestration runs found.", "Esc closes · read-only"]
        .slice(0, height).map(line => truncateToWidth(line, width));
    }
    if (this.visibleRows !== Math.max(1, Math.min(12, this.rows() - 7))) this.rebuild();
    const task = this.task();
    const title = this.inDetail && task ? `Worker ${this.slots.number(task.id)} · ${task.id}` : "Workers";
    const lines = [this.theme.fg("accent", `${title} · ${snapshot.run}`),
      this.theme.fg(stale(snapshot) ? "warning" : "muted", summary(snapshot)),
      this.theme.fg("dim", `${snapshot.provider}/${snapshot.model} · ${snapshot.thinking} · ${snapshot.stopping ? "STOP REQUESTED" : "read-only; no auto-merge"}`)];
    if (this.inDetail && task) {
      const header = [task.title, `${task.phase ? `${task.phase} · ` : ""}${task.state}${task.reportedStatus ? ` (${task.reportedStatus})` : ""} · elapsed ${age(task.started, task.ended)}`,
        `Model: ${task.modelVerified ? "verified" : "not yet verified"}; ${task.turns} turns / ${task.tools} tools`,
        `Last activity ${age(task.lastEvent)} ago${task.lastTool ? ` · ${task.lastTool}` : ""} (quiet does not mean dead)`,
        ...(task.failure ? [`ATTENTION: ${task.failure}`] : []),
        `${snapshot.directory}/tasks/${task.id}/${this.file}`, "", this.body];
      const content = new Text(header.join("\n"), 0, 0).render(Math.max(1, width));
      this.bodyHeight = Math.max(1, height - lines.length - 1);
      this.maxOffset = Math.max(0, content.length - this.bodyHeight);
      this.offset = Math.min(this.offset, this.maxOffset);
      lines.push(...content.slice(this.offset, this.offset + this.bodyHeight));
      lines.push(this.theme.fg("dim", "Alt+0 orchestrator · Alt+1–9 chat · ↑↓/Pg scroll · p/r/l files · Esc back"));
    } else {
      lines.push(...(this.list?.render(Math.max(1, width)) ?? []));
      lines.push(this.theme.fg("dim", "Alt+0 orchestrator · Alt+1–9 chat · ↑↓ select · Enter progress · r/l files · Esc closes"));
      lines.push(this.theme.fg("dim", "Review required ≠ accepted, integrated or rollout-approved."));
    }
    return lines.slice(0, height).map(line => truncateToWidth(line, width));
  }
  invalidate(): void { this.list?.invalidate(); }
  dispose(): void { this.disposed = true; this.detailGeneration++; this.unsubscribe(); }
}
