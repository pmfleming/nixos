import type { KeybindingsManager, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { basename } from "node:path";
import { age, plain, type FleetSnapshot, type InstanceRow } from "./model.ts";

export class InstancesView {
  private snapshot: FleetSnapshot = { rows: [], warnings: [], at: 0 };
  private error = "";
  private selected?: string;
  private detail = false;
  private scroll = 0;
  private pageSize = 10;
  private showExited = false;
  private disposed = false;
  private timer?: ReturnType<typeof setInterval>;
  private pending?: Promise<void>;
  private theme: Theme;
  private keys: KeybindingsManager;
  private height: () => number;
  private renderAgain: () => void;
  private close: () => void;
  private load: () => Promise<FleetSnapshot>;
  constructor(theme: Theme, keys: KeybindingsManager, height: () => number,
    renderAgain: () => void, close: () => void, load: () => Promise<FleetSnapshot>) {
    this.theme = theme;
    this.keys = keys;
    this.height = height;
    this.renderAgain = renderAgain;
    this.close = close;
    this.load = load;
  }
  start(): void {
    void this.refresh();
    this.timer = setInterval(() => { void this.refresh(); }, 2000);
    this.timer.unref();
  }
  refresh(): Promise<void> {
    if (this.disposed) return Promise.resolve();
    if (this.pending) return this.pending;
    this.pending = this.load().then(snapshot => {
      if (this.disposed) return;
      this.snapshot = snapshot; this.error = "";
      const rows = this.rows();
      if (!rows.some(row => row.key === this.selected)) {
        this.selected = rows[0]?.key; this.scroll = 0;
      }
    }).catch(error => {
      if (!this.disposed) this.error = `Inventory unavailable; last snapshot only: ${plain(String(error))}`;
    }).finally(() => {
      this.pending = undefined;
      if (!this.disposed) this.renderAgain();
    });
    return this.pending;
  }
  private rows(): InstanceRow[] { return this.snapshot.rows.filter(row => this.showExited || row.status !== "exited"); }
  handleInput(data: string): void {
    const rows = this.rows();
    const index = Math.max(0, rows.findIndex(row => row.key === this.selected));
    if (this.keys.matches(data, "tui.select.cancel") || matchesKey(data, "q") || matchesKey(data, "ctrl+c")) {
      if (this.detail) { this.detail = false; this.scroll = 0; }
      else { this.dispose(); this.close(); return; }
    } else if (this.keys.matches(data, "tui.select.confirm")) {
      this.detail = !this.detail; this.scroll = 0;
    } else if (matchesKey(data, "a")) {
      this.showExited = !this.showExited;
      if (!this.rows().some(row => row.key === this.selected)) this.selected = this.rows()[0]?.key;
      this.scroll = 0;
    } else if (matchesKey(data, "r")) {
      void this.refresh();
    } else {
      const up = this.keys.matches(data, "tui.select.up");
      const down = this.keys.matches(data, "tui.select.down");
      const pageUp = matchesKey(data, "pageUp");
      const pageDown = matchesKey(data, "pageDown");
      const delta = up ? -1 : down ? 1 : pageUp ? -this.pageSize : pageDown ? this.pageSize : 0;
      if (!delta) return;
      if (this.detail) this.scroll = Math.max(0, this.scroll + delta);
      else this.selected = rows[Math.max(0, Math.min(rows.length - 1, index + delta))]?.key;
    }
    this.renderAgain();
  }
  private details(row: InstanceRow): string[] {
    return [
      `${row.name || basename(row.cwd)} · PID ${row.process.pid}${row.process.pid === process.pid ? " · this dashboard" : ""}`,
      `State: ${row.status.toUpperCase()} · source: ${row.source} · last activity ${age(row.lastActivityAt)} ago`,
      row.note,
      `Project: ${row.cwd}`,
      `Session${row.source === "log" ? " (log header)" : ""}: ${row.sessionId || "unknown"}`,
      ...(row.sessionFile ? [`Saved session: ${row.sessionFile}`] : []),
      `Model: ${row.model || "unknown"} · mode: ${row.mode || "unknown"}`,
      ...(row.registeredAt ? [`Observer attached: ${new Date(row.registeredAt).toLocaleString()} · heartbeat ${age(row.updatedAt)} ago`] : []),
      `OS parent: ${row.process.ppid}${row.parentPid ? " (Pi instance)" : ""} · process start ticks: ${row.process.startTicks}`,
      ...(row.parentHint ? [`Launch-session hint (inherited, not verified ownership): ${row.parentHint}`] : []),
      ...(row.logPath ? [`Activity log: ${row.logPath}`] : []),
      "", `Latest request: ${row.prompt || "not observed"}`,
      "", `Recent assistant text: ${row.progress || "not observed"}`,
      "", "Recent activity (no tool arguments, results, or thinking content):",
      ...(row.events.length ? row.events.map(event => `  ${age(event.at)} ago · ${event.text}`) : [`  ${row.activity}`]),
    ];
  }
  render(width: number): string[] {
    const height = Math.max(1, this.height());
    if (width < 1) return [];
    const rows = this.rows();
    const selected = rows.find(row => row.key === this.selected);
    const live = this.snapshot.rows.filter(row => row.status !== "exited");
    const reporting = live.filter(row => row.source === "telemetry" && row.status !== "stale").length;
    const count = (status: string) => live.filter(row => row.status === status).length;
    const lines = [
      this.theme.fg("accent", "Pi instances · read-only local overview"),
      `${live.length} live · ${count("working")} working · ${count("idle")} idle · ${count("waiting")} waiting · ${count("stale")} stale · ${live.length - reporting - count("stale")} unknown`,
      this.theme.fg("dim", `Refresh: ${this.snapshot.at ? `${age(this.snapshot.at)} ago` : "scanning…"} · ${this.showExited ? "including recent exits" : "live only"}`),
    ];
    if (this.error) lines.push(this.theme.fg("error", this.error));
    for (const warning of this.snapshot.warnings.slice(0, 2)) lines.push(this.theme.fg("warning", warning));
    const budget = Math.max(1, height - lines.length - 2);
    if (this.detail && selected) {
      const content = this.details(selected).flatMap(line => wrapTextWithAnsi(line, Math.max(1, width - 2)));
      this.pageSize = budget;
      this.scroll = Math.max(0, Math.min(this.scroll, content.length - budget));
      lines.push(...content.slice(this.scroll, this.scroll + budget));
    } else {
      const infoBudget = selected && budget >= 10 ? 5 : 0;
      this.pageSize = Math.max(1, budget - infoBudget);
      const index = Math.max(0, rows.findIndex(row => row.key === this.selected));
      const start = Math.floor(index / this.pageSize) * this.pageSize;
      for (const row of rows.slice(start, start + this.pageSize)) {
        const source = row.source === "log" ? "log-only" : row.status;
        const project = row.name && row.name !== "Uninstrumented Pi" ? row.name : basename(row.cwd) || row.cwd;
        const status = `${source.toUpperCase().padEnd(8)} ${String(row.process.pid).padStart(7)}`;
        const title = width >= 90 ? truncateToWidth(project, 30, "…", true) : truncateToWidth(project, 18, "…", true);
        const line = `${row.key === this.selected ? "›" : " "} ${status}  ${title}  ${age(row.lastActivityAt).padStart(3)}  ${row.activity}`;
        lines.push(row.key === this.selected ? this.theme.fg("accent", line) : line);
      }
      if (!rows.length) lines.push(this.error ? "Cannot determine live instances." : "No instances detected yet.");
      if (infoBudget && selected) lines.push("", this.theme.fg("dim", `${selected.cwd} · ${selected.source}`),
        `Request: ${selected.prompt || "not observed — Enter for details"}`,
        `Progress: ${selected.progress || selected.activity}`,
        this.theme.fg("dim", `${index + 1}/${rows.length} · ${selected.note}`));
    }
    const footer = this.theme.fg("dim", "↑↓/PgUp/PgDn navigate · Enter details · a recent exits · r refresh · Esc/q back/close");
    return [...lines.slice(0, Math.max(0, height - 1)), footer].map(line => truncateToWidth(line, width, "…"));
  }
  invalidate(): void {}
  dispose(): void { this.disposed = true; clearInterval(this.timer); }
}
