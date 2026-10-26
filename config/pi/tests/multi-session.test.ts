import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { visibleWidth, type TUI } from "@earendil-works/pi-tui";
import { prepareAttachment, type Attachment } from "../worker-dashboard/attachment.ts";
import { WorkerChatWindow } from "../worker-dashboard/chat.ts";
import { RpcConnection, type Connection, type RecordValue } from "../worker-dashboard/rpc.ts";
import { ChatSession, MultiSessionRuntime, chatMessage } from "../worker-dashboard/runtime.ts";
import { decodeState } from "../worker-dashboard/state.ts";

const theme = { fg: (_color: unknown, text: string) => text };
function attachment(id = "a", number = 1): Attachment {
  return { key: `run/${id}`, id, number, sessionFile: `/fixture/${id}.jsonl`, release: async () => {},
    spec: { command: "fake", cwd: "/fixture", env: {}, args: ["--provider", "fixture", "--model", "model", "--thinking", "high"] } };
}
class FakeConnection implements Connection {
  listeners = new Set<(event: RecordValue) => void>();
  requests: { type: string; fields: RecordValue }[] = [];
  closed = 0;
  source: Attachment;
  behavior?: (type: string, fields: RecordValue) => Promise<RecordValue>;
  constructor(source: Attachment) { this.source = source; }
  emit(event: RecordValue): void { for (const listener of this.listeners) listener(event); }
  subscribe(listener: (event: RecordValue) => void): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  async request(type: string, fields: RecordValue = {}): Promise<RecordValue> {
    this.requests.push({ type, fields });
    if (this.behavior) return this.behavior(type, fields);
    if (type === "get_state") return { sessionFile: this.source.sessionFile, model: { id: "model", provider: "fixture" }, thinkingLevel: "high", isStreaming: false };
    if (type === "get_messages") return { messages: [{ role: "assistant", content: [{ type: "text", text: `History ${this.source.id}` }] }] };
    if (type === "prompt") { this.emit({ type: "agent_start" }); return { disposition: "started" }; }
    if (type === "clear_queue") return { steering: ["queued steer"], followUp: [] };
    if (type === "abort") this.emit({ type: "agent_settled", aborted: true });
    return {};
  }
  async close(): Promise<void> { this.closed++; }
}
const tick = () => new Promise(resolve => setTimeout(resolve, 10));

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "pi-chat-attachment-"));
  const run = join(root, "run-1"), task = join(run, "tasks", "worker"), sessions = join(root, "sessions"), cwd = join(task, "worktrees");
  await mkdir(cwd, { recursive: true }); await mkdir(sessions);
  const sessionFile = join(sessions, "worker.jsonl");
  const header = { type: "session", id: "worker-session", version: 3, timestamp: new Date().toISOString(), cwd };
  await writeFile(sessionFile, `${JSON.stringify(header)}\n`);
  await writeFile(join(run, "worker-instructions.md"), "Private fixture; no live effects.");
  const identity = { provider: "fixture", model: "model", reasoning: "high", session_id: "worker-session", session_file: sessionFile };
  const invocation = { pid: 2147483647, cwd, command: ["pi", "--provider", "fixture", "--model", "model", "--thinking", "high", "--mode", "json",
    "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-approve", "--tools", "read,bash,edit,write",
    "--session-id", "worker-session", "--append-system-prompt", join(run, "worker-instructions.md"), "@NEVER_REPLAY_THIS"] };
  await writeFile(join(task, "IDENTITY.json"), JSON.stringify(identity));
  await writeFile(join(task, "invocation.json"), JSON.stringify(invocation));
  const snapshot = decodeState({ run: "run-1", provider: "fixture", model: "model", thinking: "high", updated: 1,
    tasks: { worker: { state: "review-required", ended: 1, pid: 2147483647, session_id: "worker-session" } } }, run, "run-1");
  return { root, run, task, cwd, sessions, sessionFile, identity, invocation, snapshot, cleanup: () => rm(root, { recursive: true, force: true }) };
}

test("attachment preserves model, tools, isolated cwd and prompts without replay; exclusive lease", async () => {
  const f = await fixture();
  try {
    const source = await prepareAttachment(f.snapshot, "worker", 1, undefined, f.sessions);
    try {
      assert.equal(source.spec.cwd, f.cwd);
      assert.equal(source.spec.args[source.spec.args.indexOf("--mode") + 1], "rpc");
      assert.ok(source.spec.args.includes(f.sessionFile));
      assert.ok(source.spec.args.includes(join(f.run, "worker-instructions.md")));
      assert.ok(!source.spec.args.some(arg => arg.startsWith("@")));
      assert.equal(source.spec.env.PI_SESSION_FILE, undefined);
      assert.equal(source.spec.env.ORCHESTRATION_TASK_DIR, f.task);
      await assert.rejects(prepareAttachment(f.snapshot, "worker", 1, undefined, f.sessions), /already owned/);
      assert.match(await readFile(`${f.sessionFile}.worker-chat.lock`, "utf8"), /token/);
    } finally { await source.release(); }
    const second = await prepareAttachment(f.snapshot, "worker", 1, undefined, f.sessions);
    await second.release(); await second.release();
  } finally { await f.cleanup(); }
});

test("attachment rejects live/unknown legacy workers and malformed or escaping metadata", async () => {
  const f = await fixture();
  const prepare = () => prepareAttachment(f.snapshot, "worker", 1, undefined, f.sessions);
  try {
    f.snapshot.tasks[0]!.state = "running";
    await assert.rejects(prepare(), /JSON process cannot be attached/);
    f.snapshot.tasks[0]!.state = "review-required"; f.snapshot.tasks[0]!.pid = process.pid;
    await assert.rejects(prepare(), /still alive/);
    f.snapshot.tasks[0]!.pid = 2147483647;
    f.invocation.pid = process.pid;
    await writeFile(join(f.task, "invocation.json"), JSON.stringify(f.invocation));
    await assert.rejects(prepare(), /still alive/);
    f.invocation.pid = 2147483647;
    f.invocation.command.push("--extension", "/arbitrary.ts");
    await writeFile(join(f.task, "invocation.json"), JSON.stringify(f.invocation));
    await assert.rejects(prepare(), /Unsupported/);
    f.invocation.command.splice(-2);
    await writeFile(join(f.task, "invocation.json"), JSON.stringify(f.invocation));
    await writeFile(f.sessionFile, JSON.stringify({ type: "session", id: "wrong", cwd: f.cwd }) + "\n");
    await assert.rejects(prepare(), /header/);
    f.identity.session_file = join(f.root, "outside.jsonl");
    await writeFile(f.identity.session_file, "{}\n");
    await writeFile(join(f.task, "IDENTITY.json"), JSON.stringify(f.identity));
    await assert.rejects(prepare(), /outside/);
    await rm(join(f.task, "IDENTITY.json"));
    await symlink(f.identity.session_file, join(f.task, "IDENTITY.json"));
    await assert.rejects(prepare(), /escapes/);
  } finally { await f.cleanup(); }
});

test("runtime reuses independent live sessions; background events continue and routing stays per chat", async () => {
  const connections = new Map<string, FakeConnection>();
  const runtime = new MultiSessionRuntime(source => { const connection = new FakeConnection(source); connections.set(source.id, connection); return connection; });
  const a = attachment("a", 1), b = attachment("b", 2);
  try {
    const [first, duplicate] = await Promise.all([runtime.open(a.key, async () => a), runtime.open(a.key, async () => { throw new Error("duplicate spawn"); })]);
    assert.equal(first, duplicate);
    await first.send("first prompt");
    const second = await runtime.open(b.key, async () => b);
    await second.send("second prompt");
    assert.equal(first.status, "running"); assert.equal(second.status, "running");
    connections.get("a")!.emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "BACKGROUND_UPDATE" } });
    assert.equal(first.partial, "BACKGROUND_UPDATE");
    assert.equal(second.partial, "");
    connections.get("a")!.emit({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "FINAL_BACKGROUND" }] } });
    connections.get("a")!.emit({ type: "agent_end" });
    assert.equal(first.status, "running", "agent_end is not final idle");
    connections.get("a")!.emit({ type: "agent_settled", aborted: false });
    assert.equal(first.status, "idle");
    assert.match(first.messages.at(-1)!.text, /FINAL_BACKGROUND/);
    assert.equal(second.status, "running");
    assert.deepEqual(connections.get("b")!.requests.filter(request => request.type === "prompt").map(request => request.fields.message), ["second prompt"]);
    await assert.rejects(runtime.unload(b.key), /busy/);
    await second.abort();
    assert.match(second.draft, /queued steer/);
    await runtime.unload(b.key);
    assert.equal(connections.get("b")!.closed, 1);
  } finally { await runtime.stop(); await runtime.stop(); }
  assert.equal(connections.get("a")!.closed, 1);
});

test("shutdown fences preparation and closes a child still bootstrapping", async () => {
  let release!: (value: Attachment) => void;
  let released = 0;
  const source = attachment(); source.release = async () => { released++; };
  const runtime = new MultiSessionRuntime(() => { throw new Error("must not spawn after shutdown"); });
  const opening = runtime.open(source.key, () => new Promise(resolve => { release = resolve; }));
  const rejection = assert.rejects(opening, /stopped/);
  const stopping = runtime.stop();
  release(source); await rejection; await stopping;
  assert.equal(released, 1);

  let rejectState!: (error: Error) => void;
  const connection = new FakeConnection(source);
  connection.behavior = () => new Promise((_resolve, reject) => { rejectState = reject; });
  connection.close = async () => { connection.closed++; rejectState(new Error("closed")); };
  const second = new MultiSessionRuntime(() => connection);
  const pending = second.open(source.key, async () => source);
  const rejected = assert.rejects(pending, /closed/);
  await tick(); await second.stop(); await rejected;
  assert.equal(connection.closed, 1);
});

test("uncertain prompt delivery is not replayed; fast settled runs stay idle", async () => {
  const source = attachment(), connection = new FakeConnection(source);
  const chat = new ChatSession(source, connection, () => {});
  await chat.initialize();
  connection.behavior = async () => { throw new Error("prompt acknowledgement timed out; delivery is uncertain"); };
  await assert.rejects(chat.send("DO_NOT_REPLAY"), /uncertain/);
  await assert.rejects(chat.send("DO_NOT_REPLAY"), /uncertain/);
  assert.equal(connection.requests.filter(request => request.type === "prompt").length, 1);
  connection.emit({ type: "agent_settled", aborted: false });
  connection.behavior = async () => { connection.emit({ type: "agent_start" }); connection.emit({ type: "agent_settled" }); return { disposition: "started" }; };
  await chat.send("fast");
  assert.equal(chat.status, "idle");
  await chat.close();
});

test("foreground window preserves separate drafts, detaches without abort and accepts live chat input", async () => {
  const connections = new Map<number, FakeConnection>();
  const runtime = new MultiSessionRuntime(source => { const connection = new FakeConnection(source); connections.set(source.number, connection); return connection; });
  const sources = [attachment("a", 1), attachment("b", 2)];
  const load = (number: number) => { const source = sources[number - 1]; if (!source) throw new Error("Unknown worker"); return runtime.open(source.key, async () => source); };
  let rows = 32, closed = 0;
  const tui = { requestRender: () => {}, terminal: { rows: 32, columns: 100 } } as unknown as TUI;
  const panel = new WorkerChatWindow(runtime, tui, theme, () => rows, load, () => { closed++; }, () => {}, 1);
  try {
    await tick();
    panel.focused = true;
    panel.handleInput("DRAFT_A");
    await panel.switch(2);
    panel.handleInput("DRAFT_B");
    await panel.switch(1);
    assert.match(panel.render(100).join("\n"), /DRAFT_A/);
    assert.equal(runtime.list().find(chat => chat.attachment.id === "b")!.draft, "DRAFT_B");
    panel.handleInput("\r"); await tick();
    assert.equal(connections.get(1)!.requests.at(-1)!.fields.message, "DRAFT_A");
    assert.equal(runtime.list()[0]!.status, "running");
    for (const width of [0, 1, 8, 24, 100]) {
      for (const line of panel.render(width)) assert.ok(visibleWidth(line) <= width);
    }
    rows = 6; assert.ok(panel.render(20).length <= 6);
    panel.handleInput("\x1b0"); assert.equal(closed, 1);
    panel.dispose();
    connections.get(1)!.emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "STILL_RUNNING" } });
    assert.equal(runtime.list()[0]!.partial, "STILL_RUNNING");
    assert.equal(connections.get(1)!.requests.filter(request => request.type === "abort").length, 0);
  } finally { panel.dispose(); await runtime.stop(); }
});

test("display sanitizes terminal controls and bounds message text", () => {
  const message = chatMessage({ role: "assistant", content: [{ type: "text", text: "\x1b]52;evil\x07\u202e\n" + "a".repeat(20000) }, { type: "toolCall", name: "bash" }] })!;
  assert.ok(!/[\x00-\x1f\x7f-\x9f\u202e]/.test(message.text.replaceAll("\n", "")));
  assert.ok(message.text.length <= 16 * 1024);
});

test("RPC failures reject pending requests, preserve uncertain delivery and reap owned processes", async () => {
  const malformed = new RpcConnection({ command: process.execPath, args: ["-e", "console.log('not JSON'); process.stdin.resume()"], cwd: tmpdir(), env: process.env });
  await assert.rejects(malformed.request("get_state"), /Invalid worker RPC/);
  await malformed.close();
  const missing = new RpcConnection({ command: "/definitely-missing-pi-test", args: [], cwd: tmpdir(), env: process.env });
  await assert.rejects(missing.request("get_state"), /Cannot start|write failed|input failed/);
  await missing.close();
  const silent = new RpcConnection({ command: process.execPath, args: ["-e", "process.stdin.resume()"], cwd: tmpdir(), env: process.env }, 50);
  await assert.rejects(silent.request("prompt", { message: "not replayed" }), /delivery is uncertain/);
  await silent.close();
  const code = `process.on('SIGTERM',()=>{}); setInterval(()=>{},1000); process.stdin.on('data', chunk => {
    const req=JSON.parse(chunk); console.log(JSON.stringify({type:'response',id:req.id,success:true,data:{ready:true}}));
  }); process.stdin.on('end',()=>{});`;
  const stubborn = new RpcConnection({ command: process.execPath, args: ["-e", code], cwd: tmpdir(), env: process.env });
  assert.equal((await stubborn.request("ready")).ready, true);
  const started = Date.now();
  await stubborn.close();
  assert.ok(Date.now() - started < 5000, "TERM/KILL escalation must remain bounded");
});

test("RPC client correlates out-of-order responses and handles Unicode LF framing without terminal writes", async () => {
  const code = `
    let input = ''; process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { input += chunk; let at;
      while ((at = input.indexOf('\\n')) >= 0) {
        const req = JSON.parse(input.slice(0, at)); input = input.slice(at + 1);
        if (req.type === 'timeout') continue;
        const line = JSON.stringify({type:'response', id:req.id, command:req.type, success:true, data:{text:'界\\u2028next', marker:req.marker}}) + '\\n';
        setTimeout(() => { const bytes = Buffer.from(line); process.stdout.write(bytes.subarray(0, 20)); setTimeout(() => process.stdout.write(bytes.subarray(20)), 1); }, req.type === 'slow' ? 30 : 0);
      }
    });
    process.stdin.on('end', () => process.exit(0));
    process.stderr.write('private diagnostics');
  `;
  const rpc = new RpcConnection({ command: process.execPath, args: ["-e", code], cwd: tmpdir(), env: process.env }, 2000);
  try {
    const [slow, fast] = await Promise.all([rpc.request("slow", { marker: 1 }), rpc.request("fast", { marker: 2 })]);
    assert.equal(slow.marker, 1); assert.equal(fast.marker, 2);
    assert.equal(fast.text, "界\u2028next");
  } finally { await rpc.close(); await rpc.close(); }
});
