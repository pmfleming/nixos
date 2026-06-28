import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { commandExists } from "./shell.ts";
import type { SessionGroup, SessionRow } from "./types.ts";

type LaunchResult = { ok: true } | { ok: false; error: string };
type Candidate = { command: string; args: string[] };

function terminalCandidates(workingDir: string, piArgs: string[]): Candidate[] {
  const pi = ["pi", ...piArgs];
  const candidates: Candidate[] = [
    { command: "ghostty", args: ["-e", ...pi] },
    { command: "kitty", args: ["--directory", workingDir, ...pi] },
    { command: "wezterm", args: ["start", "--cwd", workingDir, "--", ...pi] },
    { command: "alacritty", args: ["--working-directory", workingDir, "-e", ...pi] },
    { command: "gnome-terminal", args: ["--working-directory", workingDir, "--", ...pi] },
    { command: "konsole", args: ["--workdir", workingDir, "-e", ...pi] },
    { command: "xfce4-terminal", args: ["--working-directory", workingDir, "-e", ...pi] },
    { command: "x-terminal-emulator", args: ["-e", ...pi] },
    { command: "xterm", args: ["-e", ...pi] },
  ];

  const preferred = process.env.PI_RECENT_SESSIONS_TERMINAL || process.env.TERMINAL;
  if (!preferred) return candidates;

  const known = candidates.find((candidate) => candidate.command === preferred);
  return [known ?? { command: preferred, args: ["-e", ...pi] }, ...candidates];
}

function safeCwd(cwd?: string): string {
  return cwd && existsSync(cwd) ? cwd : homedir();
}

function launchPi(workingDir: string, piArgs: string[]): LaunchResult {
  const tried = new Set<string>();
  for (const candidate of terminalCandidates(workingDir, piArgs)) {
    if (tried.has(candidate.command)) continue;
    tried.add(candidate.command);
    if (!commandExists(candidate.command)) continue;

    try {
      const child = spawn(candidate.command, candidate.args, { cwd: workingDir, detached: true, env: process.env, stdio: "ignore" });
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
