import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { acquireDirectoryLock } from "../recent-sessions-sidebar/maintenance-lock.ts";

function temporaryLock(): { root: string; lock: string } {
  const root = mkdtempSync(join(tmpdir(), "pi-maintenance-lock-"));
  return { root, lock: join(root, "lock") };
}

test("only one maintenance owner can hold the lock", () => {
  const { root, lock } = temporaryLock();
  try {
    const release = acquireDirectoryLock(lock);
    assert.ok(release);
    assert.equal(acquireDirectoryLock(lock), undefined);
    release();

    const releaseAgain = acquireDirectoryLock(lock);
    assert.ok(releaseAgain);
    releaseAgain();
    releaseAgain();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a stale lock left by a crashed process is recovered", () => {
  const { root, lock } = temporaryLock();
  try {
    mkdirSync(lock);
    const now = Date.now();
    const staleTime = new Date(now - 2 * 60 * 60 * 1000);
    utimesSync(lock, staleTime, staleTime);

    const release = acquireDirectoryLock(lock, now);
    assert.ok(release);
    release();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
