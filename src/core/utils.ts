/**
 * Small utilities shared across Loom: sleep, file locks, shell quoting,
 * and paths to per-branch runtime files.
 */

import {
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { PENDING_FORKS_DIR, SEND_LOCKS_DIR } from "./paths.js";

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function pendingForkPath(agentSessionId: string): string {
  return join(PENDING_FORKS_DIR, `${agentSessionId}.json`);
}

export function sendLockPath(tmuxName: string): string {
  return join(SEND_LOCKS_DIR, `${tmuxName}.lock`);
}

/**
 * Wrap a piece of text in single quotes suitable for bash exec, escaping
 * any embedded single quotes. Safe for nested quoting.
 */
export function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function pidIsAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // ESRCH = no such process; EPERM = process exists but belongs to
    // another user — for our "is this lock stale" check we treat EPERM
    // as alive to avoid stealing.
    const code = (err as NodeJS.ErrnoException).code;
    return code === "EPERM";
  }
}

/**
 * Acquire an advisory lock via exclusive file creation (`O_EXCL`) and
 * release it on completion. Writes our PID into the lock file so other
 * callers can detect and reclaim a stale lock left behind by a dead
 * process (e.g. a loom command that was Ctrl-C'd mid-run).
 */
export async function withFileLock<T>(
  lockPath: string,
  fn: () => Promise<T> | T,
  opts: { retryMs?: number; timeoutMs?: number } = {},
): Promise<T> {
  const retryMs = opts.retryMs ?? 50;
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const started = Date.now();
  mkdirSync(dirname(lockPath), { recursive: true });
  let fd: number | null = null;
  while (fd === null) {
    try {
      fd = openSync(lockPath, "wx");
      writeFileSync(lockPath, String(process.pid));
    } catch (err) {
      // Someone else owns the lock — check if they're still alive.
      let holderPid = 0;
      try {
        holderPid = parseInt(readFileSync(lockPath, "utf-8").trim(), 10);
      } catch {
        // ignore
      }
      if (holderPid && !pidIsAlive(holderPid)) {
        // Stale lock — steal it.
        try {
          unlinkSync(lockPath);
        } catch {
          // ignore, will retry
        }
        continue;
      }
      if (Date.now() - started > timeoutMs) {
        throw new Error(
          `withFileLock: timed out acquiring lock at ${lockPath} ` +
            `(held by pid=${holderPid})`,
        );
      }
      await sleep(retryMs);
    }
  }
  try {
    return await fn();
  } finally {
    try {
      closeSync(fd);
      unlinkSync(lockPath);
    } catch {
      // best-effort
    }
  }
}

/**
 * Generate a short hex id (default 8 chars) for branch ids.
 */
export function randomHex(bytes = 4): string {
  const arr = new Uint8Array(bytes);
  for (let i = 0; i < bytes; i++) {
    arr[i] = Math.floor(Math.random() * 256);
  }
  return Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function nowMs(): number {
  return Date.now();
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

export function ensurePendingForksDir(): void {
  ensureDir(PENDING_FORKS_DIR);
}
