import { execFileSync } from "node:child_process";

export function run(command: string, args: string[], cwd?: string): string | undefined {
  try {
    return execFileSync(command, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return undefined;
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

export function commandExists(command: string): boolean {
  return run("sh", ["-c", `command -v ${shellQuote(command)} >/dev/null 2>&1`]) !== undefined;
}
