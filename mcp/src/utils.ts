/**
 * Miscellaneous small helpers.
 */

import { closeSync, constants, mkdirSync, openSync, unlinkSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

export const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Simple file-based mutex. Creates `lockPath` with O_EXCL, retries with
 * backoff if another process holds it. Releases on fn completion (or
 * throw). Stale locks are not auto-cleaned — if a holder crashes, a
 * human may need to rm the lockfile.
 */
export async function withFileLock<T>(
  lockPath: string,
  fn: () => Promise<T> | T,
  opts: { retryMs?: number; timeoutMs?: number } = {},
): Promise<T> {
  const retryMs = opts.retryMs ?? 50;
  const timeoutMs = opts.timeoutMs ?? 30_000;
  const start = Date.now();

  mkdirSync(dirname(lockPath), { recursive: true });

  let fd: number | null = null;
  for (;;) {
    try {
      fd = openSync(
        lockPath,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
      );
      break;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      if (Date.now() - start > timeoutMs) {
        throw new Error(`file lock timeout: ${lockPath}`);
      }
      await sleep(retryMs);
    }
  }

  try {
    return await fn();
  } finally {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {}
      try {
        unlinkSync(lockPath);
      } catch {}
    }
  }
}

export function sendLockPath(tmuxName: string): string {
  return join(tmpdir(), `loom-send-${tmuxName}.lock`);
}

export const LOOM_HOME = join(homedir(), ".loom");
export const PENDING_FORKS_DIR = join(LOOM_HOME, "pending-forks");
export const LOOM_DEBUG_LOG = join(LOOM_HOME, "debug.log");

export function pendingForkPath(parentCcSessionId: string): string {
  return join(PENDING_FORKS_DIR, `${parentCcSessionId}.json`);
}
