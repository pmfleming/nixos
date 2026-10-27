import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { counts, plain, stale, type Observation, type Snapshot, type Worker } from "./state.ts";

// Keep numbers stable while a run is observed, even if tasks are reordered,
// removed or added. New runs get their own numbering; numbers are never reused.
export class WorkerSlots {
  private run?: string;
  private ids = new Map<string, number>();
  update(snapshot: Snapshot): void {
    if (this.run !== snapshot.run) { this.run = snapshot.run; this.ids.clear(); }
    for (const id of snapshot.tasks.map(task => task.id).sort()) {
      if (!this.ids.has(id)) this.ids.set(id, this.ids.size + 1);
    }
  }
  number(id: string): number { return this.ids.get(id) ?? 0; }
  worker(snapshot: Snapshot, number: number): Worker | undefined {
    this.update(snapshot);
    return snapshot.tasks.find(task => this.number(task.id) === number);
  }
}

export function workerState(task: Worker): string {
  if (task.failure || task.reportedStatus === "blocked") return "Attention";
  const labels: Record<string, string> = {
    running: "Running", stopping: "Stopping", queued: "Queued", "review-required": "Review",
    "failed-review-required": "Failed / Review", "stopped-review-required": "Stopped / Review",
    "launch-failed": "Launch failed", "cancelled-before-launch": "Cancelled",
  };
  const label = labels[task.state] ?? plain(task.state, 40);
  return task.reportedStatus === "partial" ? `${label} (partial)` : label;
}

export function hasActiveWorkers(value: Observation, chats: ReadonlyMap<string, string> = new Map()): value is Observation & { snapshot: Snapshot } {
  return !!value.snapshot && (counts(value.snapshot).running > 0
    || [...chats.values()].some(status => status === "Chat running" || status === "Chat opening"));
}

function packLabels(labels: string[], width: number): { lines: string[]; shown: number } {
  const lines: string[] = [];
  let current = "", shown = 0;
  for (const text of labels) {
    if (current && visibleWidth(`${current}   ${text}`) > width) {
      lines.push(current); current = "";
      if (lines.length === 3) break;
    }
    current += `${current ? "   " : ""}${text}`;
    shown++;
  }
  if (current) lines.push(current);
  return { lines, shown };
}

export function renderWorkerBox(value: Observation, slots: WorkerSlots, theme: Pick<Theme, "fg">, width: number,
  chats: ReadonlyMap<string, string> = new Map()): string[] {
  width = Math.max(0, width);
  if (!hasActiveWorkers(value, chats)) return [];
  const snapshot = value.snapshot;
  const inner = Math.max(0, width - 4);
  const border = (left: string, title: string, right: string) => {
    const text = truncateToWidth(title ? ` ${title} ` : "", Math.max(0, width - 2));
    return truncateToWidth(theme.fg("dim", `${left}${text}${"─".repeat(Math.max(0, width - visibleWidth(text) - 2))}${right}`), width);
  };
  const row = (text: string) => {
    const clipped = truncateToWidth(text, inner);
    return truncateToWidth(`${theme.fg("dim", "│")} ${clipped}${" ".repeat(Math.max(0, inner - visibleWidth(clipped)))} ${theme.fg("dim", "│")}`, width);
  };
  slots.update(snapshot);
  const tasks = [...snapshot.tasks].sort((a, b) => slots.number(a.id) - slots.number(b.id));
  const labels = tasks.map(task => {
    const label = chats.get(task.id) ?? workerState(task);
    const color = ["Running", "Chat running"].includes(label) ? "accent"
      : ["Queued", "Cancelled", "Chat idle"].includes(label) ? "muted" : "warning";
    return theme.fg(color, `${slots.number(task.id)} - ${label}`);
  });
  const { lines, shown } = packLabels(labels, inner);
  if (shown < tasks.length) lines.push(theme.fg("dim", `+${tasks.length - shown} more · Alt+W lists all`));
  if (!tasks.length) lines.push(theme.fg("muted", "No workers"));
  return [border("╭", "", "╮"),
    ...(stale(snapshot) ? [row(theme.fg("warning", "STALE · states are last reported"))] : []),
    ...lines.map(row), border("╰", "Alt+0 orchestrator", "╯")];
}
