import { plain, type Observation } from "./state.ts";

// One bounded read at a time. Session replacement/shutdown fences late reads.
export class WorkerMonitor {
  value: Observation = {};
  private listeners = new Set<(value: Observation) => void>();
  private timer?: ReturnType<typeof setInterval>;
  private pending?: Promise<void>;
  private generation = 0;

  private read: () => Promise<Observation>;
  constructor(read: () => Promise<Observation>) { this.read = read; }
  subscribe(listener: (value: Observation) => void): () => void {
    this.listeners.add(listener);
    listener(this.value);
    return () => { this.listeners.delete(listener); };
  }
  start(): void {
    this.stop();
    void this.refresh();
    this.timer = setInterval(() => { void this.refresh(); }, 2000);
    this.timer.unref();
  }
  stop(): void {
    this.generation++;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.pending = undefined;
  }
  refresh(): Promise<void> {
    if (this.pending) return this.pending;
    const generation = this.generation;
    const pending = this.read().catch(error => ({ error: plain(String(error)) })).then(value => {
      if (this.generation !== generation) return;
      this.value = value;
      for (const listener of this.listeners) listener(value);
    }).finally(() => { if (this.pending === pending) this.pending = undefined; });
    this.pending = pending;
    return pending;
  }
}
