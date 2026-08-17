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

function launchPi(workingDir: string, piArgs: string[]): LaunchResult {
  for (const command of terminalCandidates()) {
    if (!commandExists(command)) continue;

    try {
      const child = spawn("uwsm-app", ["--", command, "-e", "pi", ...piArgs], {
        cwd: workingDir,
        detached: true,
        env: process.env,
        stdio: "ignore",
      });
      child.unref();
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  return { ok: false, error: "No supported terminal found" };
}

export function launchSession(session: SessionRow, fallbackCwd: string): string | undefined {
  const result = launchPi(safeCwd(session.cwd || fallbackCwd), ["--session", session.path]);
  return result.ok ? undefined : result.error;
}

export function launchNewChat(group: SessionGroup, fallbackCwd: string): string | undefined {
  const result = launchPi(safeCwd(group.cwd || group.sessions[0]?.cwd || fallbackCwd), []);
  return result.ok ? undefined : result.error;
}
