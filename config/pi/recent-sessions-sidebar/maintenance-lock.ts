import { mkdirSync, rmSync, statSync } from "node:fs";

const DEFAULT_STALE_MS = 60 * 60 * 1000;

function errorCode(error: unknown): string | undefined {
  return error && typeof error === "object" && "code" in error ? String(error.code) : undefined;
}

/** Acquire an atomic directory lock, recovering locks left by crashed processes. */
export function acquireDirectoryLock(
  lockPath: string,
  now = Date.now(),
  staleMs = DEFAULT_STALE_MS,
): (() => void) | undefined {
  const create = (): boolean => {
    try {
      mkdirSync(lockPath);
      return true;
    } catch (error) {
      if (errorCode(error) !== "EEXIST") throw error;
      return false;
    }
  };

  if (!create()) {
    try {
      if (now - statSync(lockPath).mtimeMs < staleMs) return undefined;
      rmSync(lockPath, { recursive: true, force: true });
    } catch (error) {
      if (errorCode(error) !== "ENOENT") return undefined;
    }
    if (!create()) return undefined;
  }

  let released = false;
  return () => {
    if (released) return;
    released = true;
    rmSync(lockPath, { recursive: true, force: true });
  };
}
