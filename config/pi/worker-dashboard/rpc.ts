import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { StringDecoder } from "node:string_decoder";
import { errorCode, object, requireObject } from "../lib/data.ts";

export type RecordValue = Record<string, unknown>;
export type ProcessSpec = { command: string; args: string[]; cwd: string; env: NodeJS.ProcessEnv };
export interface Connection {
  request(type: string, fields?: RecordValue): Promise<RecordValue>;
  subscribe(listener: (event: RecordValue) => void): () => void;
  close(): Promise<void>;
}

// The stock RpcClient writes child stderr to the foreground terminal. Keep all
// worker output off the terminal and consume it continuously, even in background.
export class RpcConnection implements Connection {
  private child: ChildProcessWithoutNullStreams;
  private listeners = new Set<(event: RecordValue) => void>();
  private pending = new Map<string, { resolve: (value: RecordValue) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private nextId = 0;
  private failed?: Error;
  private closing?: Promise<void>;
  private exited: Promise<void>;
  private stderr = "";
  private buffer = "";
  private decoder = new StringDecoder("utf8");

  private timeout: number;
  constructor(spec: ProcessSpec, timeout = 30_000) {
    this.timeout = timeout;
    this.child = spawn(spec.command, spec.args, { cwd: spec.cwd, env: spec.env, stdio: ["pipe", "pipe", "pipe"], detached: true });
    this.exited = new Promise(resolve => {
      this.child.once("close", (code, signal) => {
        this.fail(new Error(`Worker process exited (${signal ?? code}). ${this.stderr}`));
        resolve();
      });
    });
    this.child.on("error", error => this.fail(new Error(`Cannot start worker: ${error.message}`)));
    this.child.stdin.on("error", error => this.fail(new Error(`Worker input failed: ${error.message}`)));
    this.child.stderr.on("data", (chunk: Buffer) => { this.stderr = (this.stderr + chunk.toString("utf8")).slice(-8192); });
    this.child.stdout.on("data", (chunk: Buffer) => {
      this.buffer += this.decoder.write(chunk);
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        if (Buffer.byteLength(line) > 32 * 1024 * 1024) { this.protocolFailure("Worker RPC record exceeds 32 MiB"); return; }
        try {
          this.receive(requireObject(JSON.parse(line)));
        } catch { this.protocolFailure("Invalid worker RPC JSON record"); return; }
      }
      if (Buffer.byteLength(this.buffer) > 32 * 1024 * 1024) this.protocolFailure("Worker RPC record exceeds 32 MiB");
    });
  }
  private receive(event: RecordValue): void {
    if (this.failed) return;
    if (event.type === "response" && typeof event.id === "string") {
      const pending = this.pending.get(event.id);
      if (!pending) return;
      this.pending.delete(event.id); clearTimeout(pending.timer);
      if (event.success !== true) pending.reject(new Error(typeof event.error === "string" ? event.error : "Worker command rejected"));
      else pending.resolve(object(event.data));
    } else for (const listener of this.listeners) listener(event);
  }
  private fail(error: Error): void {
    if (this.failed) return;
    this.failed = error;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    for (const listener of this.listeners) listener({ type: "runtime_error", message: error.message });
  }
  private protocolFailure(message: string): void {
    this.fail(new Error(message));
    void this.close();
  }
  subscribe(listener: (event: RecordValue) => void): () => void {
    this.listeners.add(listener);
    if (this.failed) listener({ type: "runtime_error", message: this.failed.message });
    return () => { this.listeners.delete(listener); };
  }
  request(type: string, fields: RecordValue = {}): Promise<RecordValue> {
    if (this.failed || this.closing) return Promise.reject(this.failed ?? new Error("Worker connection closed"));
    if (this.pending.size >= 32) return Promise.reject(new Error("Too many pending worker commands"));
    const id = `chat-${++this.nextId}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // Delivery of a prompt might already have happened. Never resend it.
        reject(new Error(`Worker ${type} acknowledgement timed out; delivery is uncertain. Do not blindly resend.`));
      }, this.timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ ...fields, type, id })}\n`, error => {
        if (error) this.fail(new Error(`Worker write failed: ${error.message}`));
      });
    });
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closing = (async () => {
      this.fail(new Error("Worker runtime stopped"));
      this.child.stdin.end();
      const signal = (name: NodeJS.Signals) => {
        if (!this.child.pid) return;
        try { process.kill(-this.child.pid, name); } catch (error) {
          if (errorCode(error) !== "ESRCH") this.child.kill(name);
        }
      };
      // EOF requests orderly Pi disposal. Signal only the process group we own.
      const term = setTimeout(() => signal("SIGTERM"), 1000);
      const kill = setTimeout(() => signal("SIGKILL"), 3000);
      await this.exited;
      clearTimeout(term); clearTimeout(kill);
      this.listeners.clear();
    })();
    return this.closing;
  }
}
