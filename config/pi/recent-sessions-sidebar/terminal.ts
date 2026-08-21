import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { commandExists } from "./shell.ts";
import type { SessionGroup, SessionRow } from "./types.ts";

type LaunchResult = { ok: true } | { ok: false; error: string };
function terminalCandidates(): string[] {
  const preferred = process.env.PI_RECENT_SESSIONS_TERMINAL || process.env.TERMINAL;
  return [...new Set([preferred, "ghostty"].filter((command): command is string => Boolean(command)))];
}

function safeCwd(cwd?: string): string {
  return cwd && existsSync(cwd) ? cwd : homedir();
}

function spawnPi(command: string, workingDir: string, piArgs: string[]): Promise<LaunchResult> {
  return new Promise((resolve) => {
    try {
      const child = spawn("uwsm-app", ["--", command, "-e", "pi", ...piArgs], {
        cwd: workingDir,
        detached: true,
        env: process.env,
        stdio: "ignore",
      });
      child.once("error", (error) => resolve({ ok: false, error: error.message }));
      child.once("spawn", () => {
        child.unref();
        resolve({ ok: true });
      });
    } catch (error) {
      resolve({ ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  });
}

async function launchPi(workingDir: string, piArgs: string[]): Promise<LaunchResult> {
  if (!commandExists("uwsm-app")) return { ok: false, error: "uwsm-app is not available" };

  let lastError: string | undefined;
  for (const command of terminalCandidates()) {
    if (!commandExists(command)) continue;
    const result = await spawnPi(command, workingDir, piArgs);
    if (result.ok) return result;
    lastError = result.error;
  }

  return { ok: false, error: lastError ?? "No supported terminal found" };
}

export async function launchSession(session: SessionRow, fallbackCwd: string): Promise<string | undefined> {
  const result = await launchPi(safeCwd(session.cwd || fallbackCwd), ["--session", session.path]);
  return result.ok ? undefined : result.error;
}

export async function launchNewChat(group: SessionGroup, fallbackCwd: string): Promise<string | undefined> {
  const result = await launchPi(safeCwd(group.cwd || group.sessions[0]?.cwd || fallbackCwd), []);
  return result.ok ? undefined : result.error;
}
