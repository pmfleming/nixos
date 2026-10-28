import { plain, type Snapshot, type Worker } from "./state.ts";

// Stable numbering within a single run's report view. Sidebar/chat numbers are
// scoped to the owning session across all its runs (CatalogSlots).
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
