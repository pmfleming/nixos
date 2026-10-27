import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { enforceRetention, loadGroups, sessionTitle } from "../recent-sessions-sidebar/sessions.ts";
import { RecentSessionsSidebar, type SidebarChoice } from "../recent-sessions-sidebar/sidebar.ts";
import { launchSession } from "../recent-sessions-sidebar/terminal.ts";

// SessionManager and the retention policy capture HOME at module load. Run the
// integration in a separate process: never discover/archive the user's sessions.
if (!process.env.PI_RECENT_FIXTURE) {
  test("sidebar metadata, navigation and retention in an isolated HOME", async () => {
    const home = await mkdtemp(join(tmpdir(), "pi-recent-review-"));
    try {
      const result = spawnSync(process.execPath, [...process.execArgv, __filename], {
        encoding: "utf8", timeout: 30_000,
        env: { ...process.env, HOME: home, PI_RECENT_FIXTURE: home,
          PI_CODING_AGENT_DIR: join(home, ".pi/agent"), PI_CODING_AGENT_SESSION_DIR: "",
          PI_RECENT_SESSIONS_MAX_TOTAL: "5", PI_RECENT_SESSIONS_MAX_PER_PROJECT: "4",
          PI_RECENT_SESSIONS_MAX_MIB: "200", PI_RECENT_SESSIONS_PROTECT_DAYS: "7" },
      });
      assert.equal(result.status, 0, result.stdout + result.stderr);
    } finally { await rm(home, { recursive: true, force: true }); }
  });
} else {
  test("fixture: protect current/named/pinned/recent sessions; archive excess without losing metadata", async () => {
    const home = process.env.PI_RECENT_FIXTURE ?? "";
    assert.ok(home);
    async function session(group: string, id: string, recent = false): Promise<string> {
      const directory = join(home, ".pi/agent/sessions", group), cwd = join(home, group);
      await mkdir(directory, { recursive: true }); await mkdir(cwd, { recursive: true });
      const time = Date.now() - (recent ? 0 : 9 * 86400_000), timestamp = new Date(time).toISOString();
      const path = join(directory, `${id}.jsonl`);
      const entries = [
        { type: "session", version: 3, id, timestamp, cwd },
        { type: "message", id: "u", parentId: null, timestamp, message: { role: "user", content: id, timestamp: time } },
        { type: "custom", id: "b", parentId: "u", timestamp, customType: "recent-sessions-sidebar.branch", data: { branch: "saved-branch" } },
        { type: "custom", id: "bad", parentId: "b", timestamp, customType: "recent-sessions-sidebar.branch", data: null },
        { type: "custom", id: "p", parentId: "bad", timestamp, customType: "recent-sessions-sidebar.pin", data: { pinned: id === "pinned" } },
        ...(id === "named" ? [{ type: "session_info", id: "n", parentId: "p", timestamp, name: "Keep me" }] : []),
      ];
      await writeFile(path, entries.map(entry => JSON.stringify(entry)).join("\n") + "\n");
      await utimes(path, time / 1000, time / 1000);
      return path;
    }
    const current = await session("one", "current");
    for (const id of ["pinned", "named", "old1", "old2", "old3"]) await session("one", id);
    await session("one", "recent", true);
    for (const id of ["b1", "b2", "b3"]) await session("two", id);
    const groups = await loadGroups(current), sessions = groups.flatMap(group => group.sessions);
    assert.equal(sessions.length, 10); assert.ok(sessions.every(item => item.branch === "saved-branch"));
    assert.ok(sessions.find(item => item.id === "pinned")?.pinned);
    const named = sessions.find(item => item.id === "named");
    assert.ok(named); assert.equal(sessionTitle(named), "Keep me");
    const choices: SidebarChoice[] = [];
    let redraws = 0;
    const sidebar = new RecentSessionsSidebar(groups, current, {}, () => 16, choice => choices.push(choice), () => redraws++);
    sidebar.handleInput("r"); sidebar.handleInput("\x1b[D"); sidebar.handleInput("\x1b[C"); sidebar.handleInput("\r");
    assert.deepEqual(choices.map(choice => choice?.action), ["rename", "new"]); assert.ok(redraws >= 3);
    for (const width of [1, 24, 100]) assert.ok(sidebar.render(width).every(line => visibleWidth(line) <= width));
    const result = await enforceRetention(current, true), kept = (await loadGroups(current)).flatMap(group => group.sessions);
    assert.equal(result?.archived, 5); assert.equal(result?.errors, 0); assert.equal(result?.remaining, 5);
    assert.equal(result?.limitedByProtection, false);
    assert.equal(result?.remainingBytes, kept.reduce((sum, item) => sum + item.size, 0));
    assert.equal(result?.archivedBytes, sessions.reduce((sum, item) => sum + item.size, 0) - result.remainingBytes);
    assert.ok(["current", "pinned", "named", "recent"].every(id => kept.some(item => item.id === id)));
    assert.equal(await enforceRetention(current), undefined, "daily throttle survives refactor");
    for (const id of ["pinned", "named", "recent"]) await session("three", id, id === "recent");
    const protectedResult = await enforceRetention(current, true);
    assert.equal(protectedResult?.archived, 1); assert.equal(protectedResult?.remaining, 7);
    assert.equal(protectedResult?.limitedByProtection, true, "protected chats must never be sacrificed to satisfy limits");
    process.env.PATH = ""; // This fixture child cannot launch any real terminal.
    assert.equal(await launchSession(named, home), "uwsm-app is not available");
  });
}
